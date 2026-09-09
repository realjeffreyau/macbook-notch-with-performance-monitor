import AppKit
import Darwin
import Foundation
import ImageIO

/// Recognizes the image files written by the built-in macOS screenshot tool.
/// The destination is read from macOS's `com.apple.screencapture` preferences;
/// the Desktop is the fallback when that preference is absent or unavailable.
enum ScreenshotFileDetector {
    private static let screenshotDefaultsDomain = "com.apple.screencapture"
    private static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tif", "tiff"
    ]

    static func configuredDirectoryURL() -> URL {
        let fallback = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        guard let configuredLocation = UserDefaults(
            suiteName: screenshotDefaultsDomain
        )?.string(forKey: "location"),
              !configuredLocation.isEmpty
        else { return fallback }

        let expandedPath = (configuredLocation as NSString).expandingTildeInPath
        let configuredURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: configuredURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return fallback
        }
        return configuredURL
    }

    static func isScreenshotURL(_ url: URL) -> Bool {
        guard url.isFileURL,
              supportedExtensions.contains(url.pathExtension.lowercased())
        else { return false }

        let stem = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return stem.hasPrefix("screenshot ") || stem.hasPrefix("screen shot ")
    }

    static func latestScreenshot(
        in directoryURL: URL = configuredDirectoryURL()
    ) -> URL? {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [(url: URL, date: Date)] = []
        for url in urls where isScreenshotURL(url) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile != false
            else { continue }
            candidates.append(
                (
                    url: url,
                    date: values.creationDate ?? values.contentModificationDate ?? .distantPast
                )
            )
        }
        return candidates.max { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date < rhs.date }
            return lhs.url.path < rhs.url.path
        }?.url
    }
}

/// A bounded thumbnail decoder used only for visible screenshot rows. It
/// avoids retaining or decoding a full-resolution screenshot for the shelf.
enum ScreenshotThumbnailLoader {
    static let maximumPixelSize = 128

    static func image(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                  ] as CFDictionary
              )
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// Event-driven watcher for macOS's configured screenshot directory. It never
/// polls; macOS wakes the source when the directory changes, and the shelf
/// performs one bounded directory scan.
@MainActor
final class ScreenshotFileWatcher {
    private let directoryURL: URL
    private var source: DispatchSourceFileSystemObject?

    var onChange: (@MainActor () -> Void)?

    init(
        directoryURL: URL = ScreenshotFileDetector.configuredDirectoryURL()
    ) {
        self.directoryURL = directoryURL
    }

    func start() {
        guard source == nil else { return }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.onChange?()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        onChange = nil
    }

    deinit {
        source?.cancel()
    }
}
