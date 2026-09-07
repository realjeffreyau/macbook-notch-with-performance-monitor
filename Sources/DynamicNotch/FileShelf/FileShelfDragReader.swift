import AppKit

/// Pasteboard reads are constrained to URL objects and file URLs. In
/// particular, this never asks NSItemProvider or NSPasteboard for a data
/// representation of the dragged item.
@MainActor
enum FileShelfDragReader {
    static func localFileURLs(in info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        return FileShelfService.uniqueLocalFileURLs(objects.compactMap { $0 as URL })
    }
}
