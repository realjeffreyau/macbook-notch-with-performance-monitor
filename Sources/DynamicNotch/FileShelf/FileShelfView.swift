import AppKit
import SwiftUI

struct FileShelfDropTargetView: View {
    var body: some View {
        VStack(spacing: 9) {
            Spacer(minLength: 12)

            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .accessibilityHidden(true)

            Text("Drop files here")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Text("Only local file references are kept")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("File drop target. Only local file references are kept.")
    }
}

struct FileShelfPageView: View {
    let items: [FileShelfItem]
    let onReveal: (FileShelfItem) -> Void
    let onQuickLook: (FileShelfItem) -> Void
    let onCopy: (FileShelfItem) -> Bool
    let onRemove: (UUID) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(items.isEmpty ? "No files saved" : "Recent local files")
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                }

                Spacer(minLength: 8)

                Button(action: onClear) {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(items.isEmpty ? .white.opacity(0.24) : .white.opacity(0.72))
                        .frame(width: 26, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
                .accessibilityLabel("Clear saved files")
            }

            if items.isEmpty {
                FileShelfEmptyState()
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 5) {
                        ForEach(items) { item in
                            FileShelfRow(
                                item: item,
                                onReveal: { onReveal(item) },
                                onQuickLook: { onQuickLook(item) },
                                onCopy: { onCopy(item) },
                                onRemove: { onRemove(item.id) }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent local files")
    }
}

private struct FileShelfEmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 4)
            Image(systemName: "folder")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .accessibilityHidden(true)
            Text("Screenshots from Cmd-Shift-4 and dropped files appear here")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .multilineTextAlignment(.center)
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileShelfRow: View {
    private enum ScreenshotCopyState: Equatable {
        case idle
        case copying
        case copied
    }

    let item: FileShelfItem
    let onReveal: () -> Void
    let onQuickLook: () -> Void
    let onCopy: () -> Bool
    let onRemove: () -> Void
    @State private var icon: NSImage?
    @State private var thumbnail: NSImage?
    @State private var copyState: ScreenshotCopyState = .idle

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                } else {
                    Image(systemName: "doc")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.54))
                }
            }
            .frame(width: item.isScreenshot ? 32 : 22, height: item.isScreenshot ? 32 : 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isScreenshot {
                screenshotCopyAction()
            }
            fileAction(systemName: "eye", label: "Quick Look", action: onQuickLook)
            fileAction(systemName: "arrow.up.forward.app", label: "Reveal in Finder", action: onReveal)
            fileAction(systemName: "xmark", label: "Remove", action: onRemove)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onDrag {
            // NSItemProvider publishes the URL object only. The service never
            // creates a data representation from the file's contents.
            NSItemProvider(object: item.url as NSURL)
        }
        .task(id: item.url) {
            // Workspace icon lookup is one bounded, lifecycle-scoped read and
            // stays out of `body`, which may be recomputed frequently.
            icon = NSWorkspace.shared.icon(forFile: item.url.path)
            thumbnail = item.isScreenshot
                ? ScreenshotThumbnailLoader.image(for: item.url)
                : nil
        }
        .task(id: copyState) {
            guard copyState == .copied else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            copyState = .idle
        }
        // Keep the row's name while exposing Quick Look, Finder, and Remove
        // as separate native accessibility actions.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.displayName)
        .accessibilityHint(
            item.isScreenshot
                ? "Copy the screenshot, drag to another app, or use Quick Look and Reveal in Finder actions"
                : "Drag to another app, or use Quick Look and Reveal in Finder actions"
        )
    }

    private func fileAction(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.68))
                .frame(width: 23, height: 23)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func screenshotCopyAction() -> some View {
        Button(action: copyScreenshot) {
            Group {
                switch copyState {
                case .idle:
                    Image(systemName: "doc.on.doc")
                case .copying:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.72))
                        .scaleEffect(0.55)
                case .copied:
                    Image(systemName: "checkmark")
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: 23, height: 23)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(copyState == .copying)
        .accessibilityLabel(copyAccessibilityLabel)
    }

    private var copyAccessibilityLabel: String {
        switch copyState {
        case .idle: "Copy screenshot"
        case .copying: "Copying screenshot"
        case .copied: "Screenshot copied"
        }
    }

    private func copyScreenshot() {
        guard copyState == .idle else { return }
        copyState = .copying
        Task { @MainActor in
            // Give SwiftUI one turn to render the native progress indicator
            // before decoding the screenshot and writing the pasteboard item.
            await Task.yield()
            guard copyState == .copying else { return }
            copyState = onCopy() ? .copied : .idle
        }
    }
}
