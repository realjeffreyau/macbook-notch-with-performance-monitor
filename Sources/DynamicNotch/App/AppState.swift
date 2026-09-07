import Foundation
import Observation
import DynamicNotchMedia

@MainActor
@Observable
final class AppState {
    let preferences: NotchPreferences

    private(set) var presentationState: NotchPresentationState = .collapsed
    private(set) var geometry: NotchGeometry?
    private(set) var reduceMotion = false
    private(set) var mediaSession: MediaSession?
    private(set) var captureActivity = CaptureActivity.inactive
    private(set) var expandedPage: NotchExpandedPage = .media
    private(set) var systemStats: SystemStatsSnapshot?
    private(set) var fileShelfItems: [FileShelfItem] = []
    private(set) var fileShelfDropState: FileShelfDropState = .inactive

    init(preferences: NotchPreferences = NotchPreferences()) {
        self.preferences = preferences
    }

    var availableExpandedPages: [NotchExpandedPage] {
        NotchExpandedPage.available(
            systemStatsEnabled: preferences.systemStatsEnabled,
            fileShelfEnabled: preferences.fileShelfEnabled
        )
    }

    func updateGeometry(_ geometry: NotchGeometry?) {
        self.geometry = geometry
        if geometry == nil {
            presentationState = .collapsed
            fileShelfDropState = .inactive
        }
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    func updateMediaSession(_ session: MediaSession?) {
        mediaSession = session
    }

    func updateCaptureActivity(_ activity: CaptureActivity) {
        captureActivity = activity
    }

    func updateSystemStats(_ snapshot: SystemStatsSnapshot?) {
        systemStats = snapshot
    }

    func updateFileShelfItems(_ items: [FileShelfItem]) {
        fileShelfItems = items
    }

    func updateFileShelfDropState(_ state: FileShelfDropState) {
        fileShelfDropState = state
    }

    func togglePresentation() {
        presentationState = presentationState == .collapsed ? .expanded : .collapsed
    }

    func setPresentation(_ presentationState: NotchPresentationState) {
        self.presentationState = presentationState
    }

    func setExpandedPage(_ page: NotchExpandedPage) {
        guard availableExpandedPages.contains(page) else { return }
        expandedPage = page
    }

    @discardableResult
    func normalizeExpandedPage() -> Bool {
        guard availableExpandedPages.contains(expandedPage) else {
            expandedPage = .media
            return true
        }
        return false
    }

    func collapse() {
        presentationState = .collapsed
        expandedPage = .media
        fileShelfDropState = .inactive
    }
}
