import Foundation

enum NotchPresentationState: Equatable, Sendable {
    case collapsed
    case expanded
    /// A drag session temporarily widens the panel without changing the
    /// user's selected expanded page. The controller restores the prior state
    /// when the session exits or is cancelled.
    case dropTarget
}

enum NotchExpandedPage: CaseIterable, Hashable, Sendable {
    case media
    case system
    case files

    static func available(
        systemStatsEnabled: Bool,
        fileShelfEnabled: Bool
    ) -> [NotchExpandedPage] {
        var pages: [NotchExpandedPage] = [.media]
        if systemStatsEnabled {
            pages.append(.system)
        }
        if fileShelfEnabled {
            pages.append(.files)
        }
        return pages
    }
}
