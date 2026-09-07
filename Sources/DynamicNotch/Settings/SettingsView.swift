import AppKit
import SwiftUI

struct NotchSettingsView: View {
    @Bindable private var preferences: NotchPreferences

    init(preferences: NotchPreferences) {
        _preferences = Bindable(wrappedValue: preferences)
    }

    var body: some View {
        Form {
            Section("Notch") {
                Toggle("Enable Dynamic Notch", isOn: $preferences.isNotchEnabled)

                Picker("Animation", selection: $preferences.motionPreference) {
                    ForEach(NotchMotionPreference.allCases) { preference in
                        Text(preference.title).tag(preference)
                    }
                }

                Toggle(
                    "Collapsed media indicators",
                    isOn: $preferences.showCollapsedMediaIndicators
                )
                Toggle("Show artwork", isOn: $preferences.showArtwork)
                Toggle("Show output device", isOn: $preferences.showOutputDevice)
                Toggle("Show privacy indicators", isOn: $preferences.showPrivacyIndicators)
            }

            Section("Expanded pages") {
                Toggle("System statistics page", isOn: $preferences.systemStatsEnabled)
                Toggle("File Shelf", isOn: $preferences.fileShelfEnabled)
                Stepper(
                    "Recent files: \(preferences.fileShelfMaximumItems)",
                    value: $preferences.fileShelfMaximumItems,
                    in: 1...FileShelfLimits.maximumItemCount
                )
                .disabled(!preferences.fileShelfEnabled)
            }

            Section("Diagnostics") {
                Toggle(
                    "Show resource diagnostics",
                    isOn: $preferences.showResourceDiagnostics
                )
                Text("The diagnostic note is local and event-driven; it does not add polling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Deferred") {
                Text("Launch at login is intentionally not included in this phase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 390)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dynamic Notch settings")
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let preferences: NotchPreferences

    init(preferences: NotchPreferences) {
        self.preferences = preferences

        let contentView = NotchSettingsView(preferences: preferences)
        let hostingView = NSHostingView(rootView: contentView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dynamic Notch Settings"
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.isRestorable = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support NSCoder initialization")
    }

    func showSettings() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
