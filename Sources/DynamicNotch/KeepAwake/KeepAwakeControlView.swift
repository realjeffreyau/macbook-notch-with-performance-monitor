import SwiftUI

/// Actions the notch can request. The controller owns the session; views
/// only call these and read `AppState.keepAwakeStatus`.
struct KeepAwakeControlActions {
    var start: @MainActor (KeepAwakeDuration) -> Void = { _ in }
    var chooseEndTime: @MainActor () -> Void = {}
    var stop: @MainActor () -> Void = {}
}

/// The Keep Awake page of the expanded notch. It edits the same preferences
/// as Settings and uses the same copy as the menu bar, so every surface shows
/// one state. The countdown exists only while this page is on screen and
/// refreshes every 30 seconds.
struct KeepAwakePageView: View {
    let status: KeepAwakeStatus
    @Bindable var preferences: NotchPreferences
    let actions: KeepAwakeControlActions

    private let presentation = KeepAwakePresentation()
    private let chipColumns = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusRow
            durationGrid
            VStack(spacing: 6) {
                KeepAwakeOptionRow(
                    title: "Keep display awake",
                    systemImage: "display",
                    detail: nil,
                    isOn: $preferences.keepAwakeKeepsDisplayAwake
                )
                KeepAwakeOptionRow(
                    title: "Stay awake with lid closed",
                    systemImage: "laptopcomputer",
                    detail: closedLidDetail,
                    isOn: $preferences.keepAwakeClosedLidEnabled
                )
                .help("A closed MacBook uses more battery and can get warm. Configure battery use in Settings.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keep Awake")
    }

    // MARK: Status

    private var statusRow: some View {
        HStack(spacing: 9) {
            Image(systemName: status.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(status.isActive ? 0.92 : 0.68))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.statusTitle(for: status, now: Date()))
                    .foregroundStyle(.white)
                subtitle
                    .foregroundStyle(.white.opacity(0.56))
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .lineLimit(1)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            Button {
                if status.isActive {
                    actions.stop()
                } else {
                    actions.start(preferences.keepAwakeDurationPreset.duration)
                }
            } label: {
                Text(status.isActive ? "Stop" : "Start")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 12)
                    .frame(height: 22)
                    .background(Color.white.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(status.isActive ? "Stop Keep Awake" : "Start Keep Awake")
            .accessibilityHint(
                status.isActive ? "" : "Keeps your Mac awake, \(preferences.keepAwakeDurationPreset.title.lowercased())"
            )
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let session = status.session {
            if let endsAt = session.endsAt {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(presentation.remainingText(until: endsAt, now: context.date))
                        .monospacedDigit()
                }
            } else {
                Text("Until you stop it")
            }
        } else {
            Text(
                presentation.stopReasonLine(status.lastStopReason)
                    ?? startHint
            )
        }
    }

    private var startHint: String {
        let preset = preferences.keepAwakeDurationPreset
        return preset == .indefinitely
            ? "Start runs until you stop it"
            : "Start runs for \(preset.title.lowercased())"
    }

    // MARK: Durations

    private var durationGrid: some View {
        let chips = KeepAwakeDurationPreset.allCases.map(KeepAwakeChip.preset) + [.untilTime]
        let rows = stride(from: 0, to: chips.count, by: chipColumns).map {
            Array(chips[$0..<min($0 + chipColumns, chips.count)])
        }
        return VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    ForEach(rows[index]) { chip in
                        chipButton(chip)
                    }
                }
            }
        }
    }

    private func chipButton(_ chip: KeepAwakeChip) -> some View {
        let isSelected = chip.matches(status.session?.duration)
        return Button {
            switch chip {
            case .preset(let preset): actions.start(preset.duration)
            case .untilTime: actions.chooseEndTime()
            }
        } label: {
            Text(chip.shortTitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.62))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(Color.white.opacity(isSelected ? 0.14 : 0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.accessibilityTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Closed lid

    /// Explains the real closed-lid state; never claims success that macOS
    /// has not accepted.
    private var closedLidDetail: String? {
        guard preferences.keepAwakeClosedLidEnabled else { return "More battery and heat" }
        if let session = status.session {
            switch session.closedLid {
            case .on: return "Stays awake"
            case .waitingForPower: return "Needs power adapter"
            case .unavailable: return "Unavailable"
            case .off: return nil
            }
        }
        return preferences.keepAwakeClosedLidAllowsBattery ? "Adapter or battery" : "Power adapter only"
    }
}

private enum KeepAwakeChip: Identifiable {
    case preset(KeepAwakeDurationPreset)
    case untilTime

    var id: String {
        switch self {
        case .preset(let preset): preset.rawValue
        case .untilTime: "until"
        }
    }

    var shortTitle: String {
        switch self {
        case .preset(let preset): preset.shortTitle
        case .untilTime: "Until…"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .preset(let preset): "Keep awake \(preset.title.lowercased())"
        case .untilTime: "Keep awake until a time"
        }
    }

    func matches(_ duration: KeepAwakeDuration?) -> Bool {
        switch (self, duration) {
        case (.preset(let preset), let duration?): preset.duration == duration
        case (.untilTime, .until?): true
        default: false
        }
    }
}

/// On/Off capsule styled like the page picker's selected state.
private struct KeepAwakeOptionRow: View {
    let title: String
    let systemImage: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(title)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
            }

            Button {
                isOn.toggle()
            } label: {
                Text(isOn ? "On" : "Off")
                    .foregroundStyle(.white.opacity(isOn ? 0.92 : 0.48))
                    .frame(width: 40, height: 20)
                    .background(Color.white.opacity(isOn ? 0.14 : 0.06), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityHint(detail ?? "")
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
    }
}
