import AppKit
import Foundation
import QuickLookUI

enum FileShelfLimits {
    static let maximumItemCount = 8
    static let maximumMetadataByteCount = 256 * 1_024
    static let maximumBookmarkByteCount = 16 * 1_024
    static let maximumDisplayNameByteCount = 4 * 1_024
    static let maximumURLByteCount = 8 * 1_024
}

/// The only information Dynamic Notch keeps for a shelf entry. The file's
/// bytes are never read: the URL and, when available, a security-scoped
/// bookmark are enough to reopen or hand the item back to Finder.
struct FileShelfItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let addedAt: Date
    let bookmarkData: Data?

    init(
        id: UUID = UUID(),
        url: URL,
        displayName: String? = nil,
        addedAt: Date = Date(),
        bookmarkData: Data? = nil
    ) {
        self.id = id
        self.url = url.standardizedFileURL
        if let displayName, !displayName.isEmpty {
            self.displayName = displayName
        } else {
            self.displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        }
        self.addedAt = addedAt
        self.bookmarkData = FileShelfService.boundedBookmark(bookmarkData)
    }

    var record: FileShelfRecord {
        FileShelfRecord(
            id: id,
            url: url,
            displayName: displayName,
            addedAt: addedAt,
            bookmarkData: bookmarkData
        )
    }

    var isScreenshot: Bool {
        ScreenshotFileDetector.isScreenshotURL(url)
    }
}

/// Codable metadata persisted by the local shelf store. This intentionally
/// contains no file data, thumbnail, or preview cache.
struct FileShelfRecord: Codable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let addedAt: Date
    let bookmarkData: Data?
}

enum FileShelfDropState: Equatable, Sendable {
    case inactive
    case hovering
}

/// Small persistence boundary so service tests never need the user's
/// Application Support directory. The production implementation is an actor
/// and writes one atomic metadata file; it never opens a shelf item's URL.
protocol FileShelfStoring: Sendable {
    func load() async throws -> [FileShelfRecord]
    func save(_ records: [FileShelfRecord]) async throws
}

enum FileShelfStoreError: Error, Equatable, Sendable {
    case metadataTooLarge
    case tooManyRecords
    case recordFieldTooLarge
}

actor LocalFileShelfStore: FileShelfStoring {
    private let fileURL: URL

    init(fileURL: URL = LocalFileShelfStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func load() async throws -> [FileShelfRecord] {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        // This is our tiny JSON metadata file, not one of the user's shelf
        // files. A shelf item is never passed to Data(contentsOf:).
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: FileShelfLimits.maximumMetadataByteCount + 1) ?? Data()
        guard data.count <= FileShelfLimits.maximumMetadataByteCount else {
            throw FileShelfStoreError.metadataTooLarge
        }
        try Task.checkCancellation()
        let records = try JSONDecoder().decode([FileShelfRecord].self, from: data)
        try Self.validate(records)
        return records
    }

    func save(_ records: [FileShelfRecord]) async throws {
        try Task.checkCancellation()
        try Self.validate(records)
        let data = try JSONEncoder().encode(records)
        guard data.count <= FileShelfLimits.maximumMetadataByteCount else {
            throw FileShelfStoreError.metadataTooLarge
        }
        try Task.checkCancellation()
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
    }

    private static func validate(_ records: [FileShelfRecord]) throws {
        guard records.count <= FileShelfLimits.maximumItemCount else {
            throw FileShelfStoreError.tooManyRecords
        }
        for record in records {
            guard record.displayName.utf8.count <= FileShelfLimits.maximumDisplayNameByteCount,
                  record.url.absoluteString.utf8.count <= FileShelfLimits.maximumURLByteCount,
                  record.bookmarkData?.count ?? 0 <= FileShelfLimits.maximumBookmarkByteCount
            else {
                throw FileShelfStoreError.recordFieldTooLarge
            }
        }
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("DynamicNotch", isDirectory: true)
            .appendingPathComponent("file-shelf.json", isDirectory: false)
    }
}

protocol FileShelfBookmarkProviding: Sendable {
    func makeBookmark(for url: URL) -> Data?
    func resolve(_ record: FileShelfRecord) -> (url: URL, bookmarkData: Data?)?
}

struct SecurityScopedFileShelfBookmarks: FileShelfBookmarkProviding {
    func makeBookmark(for url: URL) -> Data? {
        let scopedOptions: URL.BookmarkCreationOptions = [
            .withSecurityScope,
            .securityScopeAllowOnlyReadAccess
        ]
        if let data = try? url.bookmarkData(
            options: scopedOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ), let boundedData = boundedBookmark(data) {
            return boundedData
        }

        // A non-sandboxed development build may not accept the scoped option.
        // A regular bookmark still gives the local-only shelf a stable URL.
        guard let data = try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        return boundedBookmark(data)
    }

    func resolve(_ record: FileShelfRecord) -> (url: URL, bookmarkData: Data?)? {
        guard let bookmarkData = record.bookmarkData else {
            return Self.validLocalURL(record.url)
                .map { (url: $0, bookmarkData: nil) }
        }

        var isStale = false
        let options: URL.BookmarkResolutionOptions = [
            .withSecurityScope,
            .withoutUI,
            .withoutMounting
        ]
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ), let localURL = Self.validLocalURL(url) else {
            return Self.validLocalURL(record.url)
                .map { (url: $0, bookmarkData: makeBookmark(for: $0)) }
        }

        let refreshedBookmark = isStale ? makeBookmark(for: localURL) : bookmarkData
        return (url: localURL, bookmarkData: refreshedBookmark)
    }

    private func boundedBookmark(_ data: Data?) -> Data? {
        guard let data, data.count <= FileShelfLimits.maximumBookmarkByteCount else {
            return nil
        }
        return data
    }

    private static func validLocalURL(_ url: URL) -> URL? {
        guard url.isFileURL,
              url.scheme?.lowercased() == "file",
              url.host == nil
                || url.host?.isEmpty == true
                || url.host?.lowercased() == "localhost"
        else { return nil }
        return url.standardizedFileURL
    }
}

/// Main-actor coordinator for local file references. Loading is one bounded
/// startup task; screenshot discovery is an event-driven Desktop watch and
/// writes happen only after an explicit user action or a new screenshot event.
@MainActor
final class FileShelfService {
    static let maximumItemCount = FileShelfLimits.maximumItemCount

    private let store: any FileShelfStoring
    private let bookmarks: any FileShelfBookmarkProviding
    private let screenshotMonitoringEnabled: Bool
    private var loadTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var screenshotWatcher: ScreenshotFileWatcher?
    private var didStart = false
    private var didMutateBeforeLoad = false

    private(set) var items: [FileShelfItem] = []
    private(set) var dropState: FileShelfDropState = .inactive
    var onItemsChanged: (@MainActor ([FileShelfItem]) -> Void)?
    var onDropStateChanged: (@MainActor (FileShelfDropState) -> Void)?
    var onScreenshotDetected: (@MainActor () -> Void)?

    init(
        store: any FileShelfStoring = LocalFileShelfStore(),
        bookmarks: any FileShelfBookmarkProviding = SecurityScopedFileShelfBookmarks(),
        maximumItemCount: Int = FileShelfService.maximumItemCount,
        screenshotMonitoringEnabled: Bool = true
    ) {
        self.store = store
        self.bookmarks = bookmarks
        self.screenshotMonitoringEnabled = screenshotMonitoringEnabled
        self.maximumItemCount = min(
            max(1, maximumItemCount),
            FileShelfService.maximumItemCount
        )
    }

    private(set) var maximumItemCount: Int

    func setMaximumItemCount(_ maximumItemCount: Int) {
        let boundedValue = min(
            max(1, maximumItemCount),
            FileShelfService.maximumItemCount
        )
        guard self.maximumItemCount != boundedValue else { return }

        self.maximumItemCount = boundedValue
        guard items.count > boundedValue else { return }
        items = Array(items.prefix(boundedValue))
        publishItems()
        schedulePersistence()
    }

    func start() {
        guard !didStart else { return }
        didStart = true

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let records = try await self.store.load()
                guard !Task.isCancelled else { return }
                if !self.didMutateBeforeLoad {
                    self.replaceItems(with: records)
                }
            } catch {
                // Missing or corrupt metadata should not affect notch startup.
            }
            self.loadTask = nil
            self.startScreenshotMonitoring()
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        // Settings can disable and re-enable the shelf while the app remains
        // alive. Allow the next enable transition to retry a load that was
        // cancelled before it completed.
        didStart = false
        screenshotWatcher?.stop()
        screenshotWatcher = nil
        // Do not cancel an explicit save already queued by a user action. The
        // actor store is finite and may finish while NSApplication tears down.
        setDropState(.inactive)
    }

    func setDropState(_ state: FileShelfDropState) {
        guard dropState != state else { return }
        dropState = state
        onDropStateChanged?(state)
    }

    @discardableResult
    func importLocalFileURLs(_ urls: [URL], at date: Date = Date()) -> [FileShelfItem] {
        let acceptedURLs = Self.uniqueLocalFileURLs(urls)
        guard !acceptedURLs.isEmpty else { return [] }

        didMutateBeforeLoad = true
        var updatedItems = items
        var imported: [FileShelfItem] = []

        // Each accepted URL is a new recent action, so the last item in the
        // pasteboard sequence appears first. Duplicate paths update the
        // existing stable row identity rather than creating another row.
        for url in acceptedURLs {
            let key = Self.identity(for: url)
            let existingIndex = updatedItems.firstIndex {
                Self.identity(for: $0.url) == key
            }
            let item: FileShelfItem
            if let existingIndex {
                let existing = updatedItems.remove(at: existingIndex)
                item = FileShelfItem(
                    id: existing.id,
                    url: url,
                    addedAt: date,
                    bookmarkData: Self.boundedBookmark(bookmarks.makeBookmark(for: url))
                )
            } else {
                item = FileShelfItem(
                    url: url,
                    addedAt: date,
                    bookmarkData: Self.boundedBookmark(bookmarks.makeBookmark(for: url))
                )
            }
            updatedItems.insert(item, at: 0)
            imported.insert(item, at: 0)
        }

        items = Array(updatedItems.prefix(maximumItemCount))
        publishItems()
        schedulePersistence()
        return imported
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }
        didMutateBeforeLoad = true
        items.remove(at: index)
        publishItems()
        schedulePersistence()
        return true
    }

    func clear() {
        guard !items.isEmpty else { return }
        didMutateBeforeLoad = true
        items.removeAll(keepingCapacity: true)
        publishItems()
        schedulePersistence()
    }

    func resolvedURL(for item: FileShelfItem) -> URL? {
        guard let current = items.first(where: { $0.id == item.id }) else {
            return nil
        }
        return bookmarks.resolve(current.record)?.url
    }

    func revealInFinder(_ item: FileShelfItem) {
        withSecurityScopedURL(for: item) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func quickLook(_ item: FileShelfItem) {
        guard let url = resolvedURL(for: item) else { return }
        quickLookController.present(url: url)
    }

    @discardableResult
    func copyToPasteboard(_ item: FileShelfItem) -> Bool {
        var didCopy = false
        withSecurityScopedURL(for: item) { url in
            guard ScreenshotFileDetector.isScreenshotURL(url),
                  let image = NSImage(contentsOf: url)
            else { return }

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            didCopy = pasteboard.writeObjects([image])
        }
        return didCopy
    }

    private lazy var quickLookController = FileShelfQuickLookController()

    private func startScreenshotMonitoring() {
        guard screenshotMonitoringEnabled,
              didStart,
              screenshotWatcher == nil
        else { return }

        let watcher = ScreenshotFileWatcher()
        watcher.onChange = { @MainActor [weak self] in
            self?.importLatestScreenshotIfNeeded()
        }
        screenshotWatcher = watcher
        watcher.start()
        importLatestScreenshotIfNeeded()
    }

    private func importLatestScreenshotIfNeeded() {
        guard didStart,
              let url = ScreenshotFileDetector.latestScreenshot(),
              !items.contains(where: { Self.identity(for: $0.url) == Self.identity(for: url) })
        else { return }

        let imported = importLocalFileURLs([url])
        if !imported.isEmpty {
            onScreenshotDetected?()
        }
    }

    private func withSecurityScopedURL(
        for item: FileShelfItem,
        operation: (URL) -> Void
    ) {
        guard let current = items.first(where: { $0.id == item.id }),
              let url = bookmarks.resolve(current.record)?.url
        else { return }

        let accessed = current.bookmarkData != nil
            && url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        operation(url)
    }

    private func replaceItems(with records: [FileShelfRecord]) {
        let loaded = records.compactMap { record -> FileShelfItem? in
            guard let resolved = bookmarks.resolve(record) else { return nil }
            return FileShelfItem(
                id: record.id,
                url: resolved.url,
                displayName: record.displayName,
                addedAt: record.addedAt,
                bookmarkData: Self.boundedBookmark(resolved.bookmarkData)
            )
        }
        var seen = Set<String>()
        items = Array(loaded.filter { seen.insert(Self.identity(for: $0.url)).inserted }
            .prefix(maximumItemCount))
        publishItems()
    }

    private func publishItems() {
        onItemsChanged?(items)
    }

    private func schedulePersistence() {
        let snapshot = items.map(\.record)
        let store = self.store
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor in
            do {
                try await store.save(snapshot)
            } catch {
                // A read-only or unavailable Application Support directory is
                // non-fatal; the current in-memory shelf remains usable.
            }
        }
    }

    nonisolated static func uniqueLocalFileURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            guard isLocalFileURL(url) else { return nil }
            let standardized = url.standardizedFileURL
            let key = identity(for: standardized)
            guard seen.insert(key).inserted else { return nil }
            return standardized
        }
    }

    nonisolated static func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL
            && url.scheme?.lowercased() == "file"
            && (
                url.host == nil
                    || url.host?.isEmpty == true
                    || url.host?.lowercased() == "localhost"
            )
    }

    nonisolated static func identity(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func boundedBookmark(_ data: Data?) -> Data? {
        guard let data, data.count <= FileShelfLimits.maximumBookmarkByteCount else {
            return nil
        }
        return data
    }
}

@MainActor
private final class FileShelfQuickLookController: NSObject,
    @preconcurrency QLPreviewPanelDataSource,
    QLPreviewPanelDelegate {
    private var previewItem: FileShelfPreviewItem?
    private var accessedURL: URL?

    func present(url: URL) {
        dismissAccess()
        guard let panel = QLPreviewPanel.shared() else { return }
        previewItem = FileShelfPreviewItem(url: url)
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        guard panel.isVisible else {
            dismissAccess(clearPanel: true)
            return
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        previewItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        previewItem ?? FileShelfPreviewItem(url: URL(fileURLWithPath: "/"))
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel) {
        dismissAccess()
    }

    private func dismissAccess(clearPanel: Bool = false) {
        if clearPanel, let panel = QLPreviewPanel.shared() {
            panel.dataSource = nil
            panel.delegate = nil
        }
        if let accessedURL {
            accessedURL.stopAccessingSecurityScopedResource()
        }
        accessedURL = nil
        previewItem = nil
    }

    deinit {
        if let accessedURL {
            accessedURL.stopAccessingSecurityScopedResource()
        }
    }
}

private final class FileShelfPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?

    init(url: URL) {
        previewItemURL = url
    }
}
