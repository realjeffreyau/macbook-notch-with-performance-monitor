import SwiftUI

struct ExpandedPagePicker: View {
    let selection: NotchExpandedPage
    let pages: [NotchExpandedPage]
    let onSettings: () -> Void
    let onSelect: (NotchExpandedPage) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(pages, id: \.self) { page in
                Button {
                    onSelect(page)
                } label: {
                    Image(systemName: systemImage(for: page))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(page == selection ? .white.opacity(0.92) : .white.opacity(0.48))
                        .frame(width: 28, height: 22)
                        .background(
                            Color.white.opacity(page == selection ? 0.14 : 0.06),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: page))
                .accessibilityAddTraits(page == selection ? .isSelected : [])
            }

            Spacer(minLength: 4)

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(width: 28, height: 22)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Dynamic Notch settings")
        }
    }

    private func systemImage(for page: NotchExpandedPage) -> String {
        switch page {
        case .media: "music.note"
        case .system: "gauge.with.dots.needle.33percent"
        case .files: "folder"
        }
    }

    private func accessibilityLabel(for page: NotchExpandedPage) -> String {
        switch page {
        case .media: "Media"
        case .system: "System statistics"
        case .files: "Files"
        }
    }
}

struct SystemStatsPageView: View {
    let snapshot: SystemStatsSnapshot?

    var body: some View {
        VStack(spacing: 9) {
            SystemStatsRow(
                label: "CPU",
                value: percentage(snapshot?.cpuUsage),
                progress: snapshot?.cpuUsage,
                systemImage: "cpu"
            )
            SystemStatsRow(
                label: "Memory",
                value: memoryValue,
                progress: snapshot?.memoryUsage,
                systemImage: "memorychip"
            )
            SystemStatsRow(
                label: "Battery",
                value: batteryValue,
                progress: snapshot?.battery?.chargeFraction,
                systemImage: batterySystemImage
            )
            SystemStatsRow(
                label: "Energy usage",
                value: energyValue,
                progress: snapshot?.energyUsageEstimate,
                systemImage: "bolt"
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("System statistics")
    }

    private var memoryValue: String {
        guard let snapshot,
              let used = snapshot.usedMemoryBytes,
              let total = snapshot.totalMemoryBytes
        else { return "Unavailable" }
        return "\(formatBytes(used)) / \(formatBytes(total))"
    }

    private var batteryValue: String {
        guard let battery = snapshot?.battery else { return "Unavailable" }
        let charge = percentage(battery.chargeFraction)
        switch battery.state {
        case .charging:
            return "\(charge) · Charging"
        case .discharging:
            return "\(charge) · On battery"
        case .full:
            return "\(charge) · Full"
        case .unknown:
            return charge
        }
    }

    private var batterySystemImage: String {
        guard let battery = snapshot?.battery else { return "battery.0" }
        switch battery.state {
        case .charging: return "battery.75percent.bolt"
        case .discharging, .unknown: return "battery.50percent"
        case .full: return "battery.100percent"
        }
    }

    private var energyValue: String {
        guard let estimate = snapshot?.energyUsageEstimate else {
            return "Unavailable"
        }
        return percentage(estimate)
    }

    private func percentage(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return "\(Int((value * 100).rounded()))%"
    }

    private func formatBytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .memory)
    }
}

private struct SystemStatsRow: View {
    let label: String
    let value: String
    let progress: Double?
    let systemImage: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                    Spacer(minLength: 8)
                    Text(value)
                        .foregroundStyle(.white.opacity(0.68))
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.16))
                        if let progress {
                            Capsule()
                                .fill(Color.white.opacity(0.88))
                                .frame(width: max(4, proxy.size.width * min(max(progress, 0), 1)))
                        }
                    }
                }
                .frame(height: 4)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
