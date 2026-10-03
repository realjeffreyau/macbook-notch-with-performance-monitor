import AVFoundation
import AppKit
import Observation
import SwiftUI

private enum MirrorCameraStatus: Equatable {
    case idle
    case requestingPermission
    case starting
    case live
    case denied
    case unavailable
}

/// Owns camera permission and UI status for the lifetime of the Mirror page.
/// The actual AVCaptureSession is configured and stopped on its own serial
/// queue, so camera startup never blocks the notch's main thread.
@MainActor
@Observable
private final class MirrorCameraModel {
    @ObservationIgnored private let captureSession: MirrorCaptureSession
    @ObservationIgnored private let statusRelay: MirrorCaptureStatusRelay
    @ObservationIgnored private var generation: UInt64 = 0

    private(set) var status: MirrorCameraStatus = .idle

    var previewSession: AVCaptureSession {
        captureSession.previewSession
    }

    init() {
        let captureSession = MirrorCaptureSession()
        let statusRelay = MirrorCaptureStatusRelay()
        self.captureSession = captureSession
        self.statusRelay = statusRelay
        statusRelay.update = { [weak self] generation, didStart in
            guard let self, self.generation == generation else { return }
            status = didStart ? .live : .unavailable
        }
    }

    func start() {
        guard status == .idle else { return }
        generation &+= 1
        let requestGeneration = generation

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture(generation: requestGeneration)
        case .notDetermined:
            status = .requestingPermission
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, generation == requestGeneration else { return }
                if granted {
                    startCapture(generation: requestGeneration)
                } else {
                    status = .denied
                }
            }
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .unavailable
        }
    }

    func stop() {
        generation &+= 1
        status = .idle
        captureSession.stop()
    }

    func openCameraPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func startCapture(generation: UInt64) {
        status = .starting
        captureSession.start(generation: generation, relay: statusRelay)
    }
}

/// Main-actor results from the camera queue are delivered through this relay.
/// A generation check discards stale starts when the user changes tabs quickly.
@MainActor
private final class MirrorCaptureStatusRelay {
    var update: (@MainActor (UInt64, Bool) -> Void)?

    nonisolated func publish(generation: UInt64, didStart: Bool) {
        Task { @MainActor [weak self] in
            self?.update?(generation, didStart)
        }
    }
}

/// AVCaptureSession mutations stay serialized off the UI thread. The preview
/// layer observes the same session for display, with no video-output delegate
/// or frame-by-frame SwiftUI updates.
private final class MirrorCaptureSession: @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(
        label: "com.dynamicnotch.mirror-camera",
        qos: .userInitiated
    )

    var previewSession: AVCaptureSession { session }

    func start(generation: UInt64, relay: MirrorCaptureStatusRelay) {
        queue.async { [self] in
            relay.publish(generation: generation, didStart: configureAndStart())
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }

            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            for output in session.outputs {
                session.removeOutput(output)
            }
            session.commitConfiguration()
        }
    }

    private func configureAndStart() -> Bool {
        let frontCamera = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .front
        ).devices.first
        guard let camera = frontCamera ?? AVCaptureDevice.default(for: .video) else {
            return false
        }

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.vga640x480)
            ? .vga640x480
            : .low
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                return false
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            return false
        }
        session.commitConfiguration()

        capFrameRate(camera, at: 24)
        session.startRunning()
        return session.isRunning
    }

    private func capFrameRate(_ camera: AVCaptureDevice, at requestedRate: Double) {
        guard camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= requestedRate && $0.maxFrameRate >= requestedRate
        }) else { return }

        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            let duration = CMTime(value: 1, timescale: CMTimeScale(requestedRate))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
        } catch {
            // Keep the device's safe default rate if it cannot be configured.
        }
    }
}

@MainActor
struct MirrorCameraPage: View {
    @State private var camera = MirrorCameraModel()
    @State private var showsMirrorBadge = false

    var body: some View {
        GeometryReader { proxy in
            let previewHeight = max(1, min(proxy.size.height, 148))
            let previewWidth = max(1, min(proxy.size.width, previewHeight * 16 / 9))

            ZStack {
                Color.black.opacity(0.42)

                if camera.status == .live {
                    MirrorCameraPreview(
                        session: camera.previewSession,
                        isLive: true
                    )

                    if showsMirrorBadge {
                        VStack {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(.green)
                                    .frame(width: 5, height: 5)
                                Text("MIRROR")
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .tracking(0.4)
                            }
                            .foregroundStyle(.white.opacity(0.94))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.52), in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                } else {
                    cameraStatusContent
                        .padding(12)
                }
            }
            .frame(width: previewWidth, height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mirror camera")
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .task(id: camera.status) {
            guard camera.status == .live else {
                withAnimation(.easeOut(duration: 0.12)) {
                    showsMirrorBadge = false
                }
                return
            }

            withAnimation(.easeOut(duration: 0.12)) {
                showsMirrorBadge = true
            }

            do {
                try await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    showsMirrorBadge = false
                }

                try await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    showsMirrorBadge = true
                }

                try await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    showsMirrorBadge = false
                }

                try await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    showsMirrorBadge = true
                }

                try await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    showsMirrorBadge = false
                }

                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
        }
    }

    @ViewBuilder
    private var cameraStatusContent: some View {
        switch camera.status {
        case .idle, .requestingPermission, .starting:
            VStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.82))
                Text(camera.status == .requestingPermission
                    ? "Waiting for camera access…"
                    : "Starting mirror…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Starting mirror camera")
        case .denied:
            VStack(spacing: 6) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Text("Camera access is off")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                Button("Open Camera Settings") {
                    camera.openCameraPrivacySettings()
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.link)
                .accessibilityLabel("Open Camera privacy settings")
            }
        case .unavailable:
            VStack(spacing: 6) {
                Image(systemName: "video.slash")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Text("Camera unavailable")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                Text("Try again after freeing the camera.")
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.60))
            }
            .accessibilityElement(children: .combine)
        case .live:
            EmptyView()
        }
    }
}

private struct MirrorCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let isLive: Bool

    func makeNSView(context: Context) -> MirrorCameraPreviewView {
        MirrorCameraPreviewView(session: session)
    }

    func updateNSView(_ nsView: MirrorCameraPreviewView, context: Context) {
        nsView.updateSession(session)
        if isLive {
            nsView.enableMirrorIfAvailable()
        }
    }
}

private final class MirrorCameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        enableMirrorIfAvailable()
    }

    func updateSession(_ session: AVCaptureSession) {
        guard previewLayer.session !== session else {
            enableMirrorIfAvailable()
            return
        }
        previewLayer.session = session
        enableMirrorIfAvailable()
    }

    func enableMirrorIfAvailable() {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported
        else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}
