import Foundation
import Testing
@testable import DynamicNotch

@Test("screenshot detector recognizes standard macOS screenshot names")
func screenshotDetectorRecognizesStandardNames() {
    #expect(ScreenshotFileDetector.isScreenshotURL(
        URL(fileURLWithPath: "/tmp/Screenshot 2026-09-08 at 11.42.03 PM.png")
    ))
    #expect(ScreenshotFileDetector.isScreenshotURL(
        URL(fileURLWithPath: "/tmp/Screen Shot 2026-09-08 at 11.42.03 PM.jpg")
    ))
    #expect(ScreenshotFileDetector.isScreenshotURL(
        URL(fileURLWithPath: "/tmp/screenshot 2026-09-08.heic")
    ))
    #expect(!ScreenshotFileDetector.isScreenshotURL(
        URL(fileURLWithPath: "/tmp/meeting-notes.png")
    ))
    #expect(!ScreenshotFileDetector.isScreenshotURL(
        URL(fileURLWithPath: "/tmp/Screenshot 2026-09-08.txt")
    ))
}

@Test("latest screenshot scan ignores non-screenshot files")
func latestScreenshotScanIgnoresNonScreenshotFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dynamic-notch-screenshot-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let screenshot = directory.appendingPathComponent("Screenshot 2026-09-08 at 11.42.03 PM.png")
    let note = directory.appendingPathComponent("meeting-notes.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: screenshot)
    try Data([0x01]).write(to: note)

    #expect(
        ScreenshotFileDetector.latestScreenshot(in: directory)?
            .resolvingSymlinksInPath()
            == screenshot.resolvingSymlinksInPath()
    )
}

@Test("screenshot watcher relays filesystem events without an executor trap")
@MainActor
func screenshotWatcherRelaysFilesystemEvents() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dynamic-notch-screenshot-watcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let watcher = ScreenshotFileWatcher(directoryURL: directory)
    var callbackCount = 0
    watcher.onChange = {
        callbackCount += 1
    }
    watcher.start()

    let probe = directory.appendingPathComponent("watcher-probe.txt")
    try Data([0x01]).write(to: probe)

    for _ in 0..<40 where callbackCount == 0 {
        try await Task.sleep(for: .milliseconds(25))
    }

    watcher.stop()
    #expect(callbackCount > 0)
}

@Test("file shelf accepts local URLs only and de-duplicates a drop")
@MainActor
func fileShelfAcceptsLocalURLsOnlyAndDeduplicates() {
    let service = FileShelfService(
        store: InMemoryFileShelfStore(),
        bookmarks: TestFileShelfBookmarks(),
        maximumItemCount: 8
    )
    let local = URL(fileURLWithPath: "/tmp/local-note.txt")
    let localWithDot = URL(fileURLWithPath: "/tmp/./local-note.txt")
    let remoteFile = URL(string: "file://server/share/note.txt")!
    let webURL = URL(string: "https://example.com/note.txt")!

    let imported = service.importLocalFileURLs([
        local,
        localWithDot,
        remoteFile,
        webURL
    ], at: Date(timeIntervalSinceReferenceDate: 100))

    #expect(imported.count == 1)
    #expect(service.items.count == 1)
    #expect(service.items[0].url == local.standardizedFileURL)
    #expect(service.items[0].bookmarkData == TestFileShelfBookmarks.marker)
}

@Test("file shelf keeps newest entries first and enforces its bound")
@MainActor
func fileShelfKeepsNewestEntriesFirstAndEnforcesBound() {
    let service = FileShelfService(
        store: InMemoryFileShelfStore(),
        bookmarks: TestFileShelfBookmarks(),
        maximumItemCount: 3
    )
    let first = URL(fileURLWithPath: "/tmp/first.txt")
    let second = URL(fileURLWithPath: "/tmp/second.txt")
    let third = URL(fileURLWithPath: "/tmp/third.txt")
    let fourth = URL(fileURLWithPath: "/tmp/fourth.txt")

    _ = service.importLocalFileURLs(
        [first, second, third, fourth],
        at: Date(timeIntervalSinceReferenceDate: 200)
    )

    #expect(service.items.map(\.url.lastPathComponent) == ["fourth.txt", "third.txt", "second.txt"])
}

@Test("re-importing a file moves the existing row to the front")
@MainActor
func reimportingFileMovesExistingRowToFront() {
    let service = FileShelfService(
        store: InMemoryFileShelfStore(),
        bookmarks: TestFileShelfBookmarks(),
        maximumItemCount: 3
    )
    let first = URL(fileURLWithPath: "/tmp/first.txt")
    let second = URL(fileURLWithPath: "/tmp/second.txt")

    _ = service.importLocalFileURLs([first, second])
    let originalID = service.items.last?.id
    _ = service.importLocalFileURLs([first])

    #expect(service.items.map(\.url.lastPathComponent) == ["first.txt", "second.txt"])
    #expect(service.items.first?.id == originalID)
}

@Test("remove and clear change only shelf metadata, not files")
@MainActor
func removeAndClearChangeOnlyShelfMetadata() {
    let service = FileShelfService(
        store: InMemoryFileShelfStore(),
        bookmarks: TestFileShelfBookmarks()
    )
    let urls = [
        URL(fileURLWithPath: "/tmp/one.txt"),
        URL(fileURLWithPath: "/tmp/two.txt")
    ]
    _ = service.importLocalFileURLs(urls)
    let firstID = service.items[0].id

    #expect(service.remove(id: firstID))
    #expect(!service.remove(id: firstID))
    #expect(service.items.count == 1)

    service.clear()
    #expect(service.items.isEmpty)
    service.clear()
    #expect(service.items.isEmpty)
}

@Test("file shelf drop state is an explicit finite transition")
@MainActor
func fileShelfDropStateIsExplicitFiniteTransition() {
    let service = FileShelfService(
        store: InMemoryFileShelfStore(),
        bookmarks: TestFileShelfBookmarks()
    )

    #expect(service.dropState == .inactive)
    service.setDropState(.hovering)
    #expect(service.dropState == .hovering)
    service.setDropState(.inactive)
    #expect(service.dropState == .inactive)
}

@Test("app state carries Files as a normal expanded page and resets it on collapse")
@MainActor
func appStateCarriesFilesPageAndResetsItOnCollapse() {
    let state = AppState()

    state.setExpandedPage(.files)
    state.updateFileShelfDropState(.hovering)

    #expect(state.expandedPage == .files)
    #expect(state.fileShelfDropState == .hovering)

    state.collapse()

    #expect(state.expandedPage == .media)
    #expect(state.fileShelfDropState == .inactive)
}

@Test("any collapsed presentation returns to the Media page")
@MainActor
func anyCollapsedPresentationReturnsToMediaPage() {
    let state = AppState()

    state.setExpandedPage(.system)
    state.setPresentation(.expanded)
    state.setPresentation(.collapsed)

    #expect(state.presentationState == .collapsed)
    #expect(state.expandedPage == .media)
}

@Test("file shelf metadata store bounds oversized reads and writes")
func fileShelfMetadataStoreBoundsOversizedReadsAndWrites() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("dynamic-notch-file-shelf-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("file-shelf.json", isDirectory: false)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let oversizedData = Data(
        repeating: 0x7F,
        count: FileShelfLimits.maximumMetadataByteCount + 1
    )
    try oversizedData.write(to: fileURL)

    let store = LocalFileShelfStore(fileURL: fileURL)
    do {
        _ = try await store.load()
        Issue.record("An oversized metadata file should be rejected before decoding")
    } catch let error as FileShelfStoreError {
        #expect(error == .metadataTooLarge)
    }

    let oversizedBookmark = FileShelfRecord(
        id: UUID(),
        url: URL(fileURLWithPath: "/tmp/large-bookmark.txt"),
        displayName: "large-bookmark.txt",
        addedAt: Date(),
        bookmarkData: Data(repeating: 0x01, count: FileShelfLimits.maximumBookmarkByteCount + 1)
    )
    do {
        try await store.save([oversizedBookmark])
        Issue.record("An oversized bookmark should be rejected before writing")
    } catch let error as FileShelfStoreError {
        #expect(error == .recordFieldTooLarge)
    }
}

@Test("file shelf can retry a cancelled startup load after re-enable")
@MainActor
func fileShelfCanRetryCancelledStartupLoadAfterReenable() async {
    let record = FileShelfRecord(
        id: UUID(),
        url: URL(fileURLWithPath: "/tmp/reloaded.txt"),
        displayName: "reloaded.txt",
        addedAt: Date(),
        bookmarkData: nil
    )
    let store = RestartableFileShelfStore(records: [record])
    let service = FileShelfService(
        store: store,
        bookmarks: TestFileShelfBookmarks(),
        screenshotMonitoringEnabled: false
    )

    service.start()
    service.stop()
    service.start()

    for _ in 0..<20 where service.items.isEmpty {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }

    #expect(service.items.map(\.displayName) == ["reloaded.txt"])
    #expect(await store.loadCount >= 1)
    service.stop()
    try? await Task.sleep(for: .milliseconds(20))
}

private struct TestFileShelfBookmarks: FileShelfBookmarkProviding {
    static let marker = Data([0xF1, 0x1E])

    func makeBookmark(for url: URL) -> Data? { Self.marker }

    func resolve(_ record: FileShelfRecord) -> (url: URL, bookmarkData: Data?)? {
        guard FileShelfService.isLocalFileURL(record.url) else { return nil }
        return (record.url, record.bookmarkData)
    }
}

private actor InMemoryFileShelfStore: FileShelfStoring {
    private var records: [FileShelfRecord] = []

    func load() async throws -> [FileShelfRecord] {
        records
    }

    func save(_ records: [FileShelfRecord]) async throws {
        self.records = records
    }
}

private actor RestartableFileShelfStore: FileShelfStoring {
    let records: [FileShelfRecord]
    private(set) var loadCount = 0

    init(records: [FileShelfRecord]) {
        self.records = records
    }

    func load() async throws -> [FileShelfRecord] {
        loadCount += 1
        try await Task.sleep(for: .milliseconds(5))
        return records
    }

    func save(_ records: [FileShelfRecord]) async throws {}
}
