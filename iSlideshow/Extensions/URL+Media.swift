import Foundation
import UniformTypeIdentifiers

extension URL {
    /// Broad Apple-native media types accepted by the import picker.
    static let supportedMediaTypes: [UTType] = [.image, .movie, .video]

    private static let playbackSupportedVideoExtensions: Set<String> = [
        "mov",
        "mp4",
        "m4v",
        "mpg",
        "mpeg"
    ]

    /// The URL's content type, resolved from file metadata when available.
    var resolvedContentType: UTType? {
        (try? resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: pathExtension)
    }

    /// Whether this URL points to a video format accepted for slideshow playback.
    var isSupportedVideo: Bool {
        guard let type = resolvedContentType else { return false }
        guard type.conforms(to: .movie) || type.conforms(to: .video) else { return false }
        return Self.playbackSupportedVideoExtensions.contains(pathExtension.localizedLowercase)
    }

    /// Whether this URL points to any recognized video file, including unsupported playback formats.
    var isRecognizedVideo: Bool {
        guard let type = resolvedContentType else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// Whether this URL points to a recognized media file (image or video).
    var isSupportedMedia: Bool {
        guard let type = resolvedContentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
    }

    /// Recursively scan a directory for recognized media (images + videos), sorted by filename.
    func recursiveMediaURLs() -> [URL] {
        recursiveMediaScan().urls
    }

    /// Recursively scan a directory for recognized media and count unrecognized regular files.
    func recursiveMediaScan() -> MediaDirectoryScan {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: self,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return MediaDirectoryScan(urls: [], skippedFileCount: 0)
        }

        var mediaURLs: [URL] = []
        var skippedFileCount = 0

        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { break }
            let isRegularFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isRegularFile else { continue }

            if fileURL.isSupportedMedia {
                mediaURLs.append(fileURL)
            } else {
                skippedFileCount += 1
            }
        }

        let rootPath = standardizedFileURL.path
        let sortedURLs = mediaURLs.sorted {
            relativeSortPath(for: $0, rootPath: rootPath)
                .localizedStandardCompare(relativeSortPath(for: $1, rootPath: rootPath)) == .orderedAscending
        }
        return MediaDirectoryScan(urls: sortedURLs, skippedFileCount: skippedFileCount)
    }

    private func relativeSortPath(for url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        return String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct MediaDirectoryScan: Sendable {
    let urls: [URL]
    let skippedFileCount: Int
}
