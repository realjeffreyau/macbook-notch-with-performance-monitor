import AppKit

@main
struct DynamicNotchApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate

        // NSApplication.delegate is weak; keep the delegate alive for the full
        // run-loop lifetime without introducing another global service.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
