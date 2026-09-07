import Foundation

/// Resolves Spotify artwork without contacting Spotify's Web API or making a
/// new network request. Spotify keeps the artwork it has already displayed in
/// its Chromium cache; this adapter extracts only the image body belonging to
/// the exact artwork URL returned by the local Apple Events dictionary.
public protocol SpotifyArtworkResolver: Sendable {
    func artwork(for url: URL) async -> MediaArtwork?
}

/// The production artwork boundary. A cache lookup runs off the main actor and
/// is requested only after a Spotify metadata event, so an idle notch creates
/// no timer, network task, or repeated filesystem scan.
public struct SpotifyLocalArtworkResolver: SpotifyArtworkResolver, Sendable {
    private let cacheDirectory: URL

    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/com.spotify.client/Browser/Cache/Cache_Data")
    }

    public func artwork(for url: URL) async -> MediaArtwork? {
        let cacheDirectory = cacheDirectory
        return await Task.detached(priority: .utility) {
            SpotifyArtworkCache.artwork(for: url, cacheDirectory: cacheDirectory)
        }.value
    }
}

enum SpotifyArtworkCache {
    private static let maxCacheEntryByteCount = 2 * MediaArtwork.maxByteCount
    private static let jpegSignature = Data([0xff, 0xd8, 0xff])
    private static let jpegEndSignature = Data([0xff, 0xd9])
    private static let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    private static let pngEndSignature = Data([0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82])
    private static let riffSignature = Data([0x52, 0x49, 0x46, 0x46])
    private static let webpSignature = Data([0x57, 0x45, 0x42, 0x50])

    static func artwork(for url: URL, cacheDirectory: URL) -> MediaArtwork? {
        let keys = cacheKeys(for: url)
        guard !keys.isEmpty else {
            return nil
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize > keys.map(\.count).min()!,
                  fileSize <= maxCacheEntryByteCount,
                  let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
                  data.count <= maxCacheEntryByteCount,
                  let artwork = extractArtwork(from: data, matchingAny: keys)
            else {
                continue
            }
            return artwork
        }

        return nil
    }

    static func extractArtwork(from data: Data, matching key: Data) -> MediaArtwork? {
        guard let keyRange = data.range(of: key) else { return nil }
        return extractArtwork(from: data, after: keyRange.upperBound)
    }

    private static func extractArtwork(from data: Data, matchingAny keys: [Data]) -> MediaArtwork? {
        for key in keys {
            guard let keyRange = data.range(of: key) else { continue }
            // The size-independent key is only the final artwork hash. Avoid
            // treating an unrelated occurrence in response metadata as the
            // cache key by requiring the Spotify image URL prefix nearby.
            if key.count < 40 {
                let contextStart = max(0, keyRange.lowerBound - 48)
                let context = String(data: data[contextStart..<keyRange.lowerBound], encoding: .utf8)
                guard context?.contains("https://i.scdn.co/image/ab67616d") == true else {
                    continue
                }
            }
            if let artwork = extractArtwork(from: data, after: keyRange.upperBound) {
                return artwork
            }
        }
        return nil
    }

    private static func extractArtwork(from data: Data, after bodyStart: Data.Index) -> MediaArtwork? {
        guard bodyStart < data.count else { return nil }

        if let start = data.range(of: jpegSignature, in: bodyStart..<data.count)?.lowerBound,
           let end = data.range(of: jpegEndSignature, in: start..<data.count)?.upperBound {
            return MediaArtwork(
                data: Data(data[start..<end]),
                mimeType: "image/jpeg"
            )
        }

        if let start = data.range(of: pngSignature, in: bodyStart..<data.count)?.lowerBound,
           let end = data.range(of: pngEndSignature, in: start..<data.count)?.upperBound {
            return MediaArtwork(
                data: Data(data[start..<end]),
                mimeType: "image/png"
            )
        }

        guard let start = data.range(of: riffSignature, in: bodyStart..<data.count)?.lowerBound,
              start + 12 <= data.count,
              Data(data[(start + 8)..<(start + 12)]) == webpSignature,
              start + 8 <= data.count
        else {
            return nil
        }

        let sizeOffset = start + 4
        guard sizeOffset + 4 <= data.count else { return nil }
        let payloadSize = UInt32(data[sizeOffset])
            | (UInt32(data[sizeOffset + 1]) << 8)
            | (UInt32(data[sizeOffset + 2]) << 16)
            | (UInt32(data[sizeOffset + 3]) << 24)
        let end = min(data.count, start + 8 + Int(payloadSize))
        guard end > start else { return nil }
        return MediaArtwork(
            data: Data(data[start..<end]),
            mimeType: "image/webp"
        )
    }

    private static func cacheKeys(for url: URL) -> [Data] {
        var keys: [Data] = []
        if let exactKey = url.absoluteString.data(using: .utf8), !exactKey.isEmpty {
            keys.append(exactKey)
        }

        let imagePathPrefix = "/image/"
        guard let prefixRange = url.path.range(of: imagePathPrefix) else {
            return keys
        }
        let imageIdentifier = String(url.path[prefixRange.upperBound...])
        guard imageIdentifier.count >= 24 else { return keys }
        let artworkHash = String(imageIdentifier.suffix(24))
        guard let hashKey = artworkHash.data(using: .utf8), !hashKey.isEmpty else {
            return keys
        }
        keys.append(hashKey)
        return keys
    }
}
