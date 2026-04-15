import SwiftUI
import UniformTypeIdentifiers

struct MediaDropDelegate: DropDelegate {
    let onDrop: ([URL]) -> Void
    var onEntered: (() -> Void)?
    var onExited: (() -> Void)?

    static let acceptedContentTypes: [UTType] = [.fileURL, .image, .movie, .video]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedContentTypes)
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        onEntered?()
    }

    func dropExited(info: DropInfo) {
        onExited?()
    }

    func performDrop(info: DropInfo) -> Bool {
        onExited?()

        let providers = info.itemProviders(for: Self.acceptedContentTypes)
        guard !providers.isEmpty else { return false }

        let callback = onDrop
        Task.detached {
            let indexedResults = await withTaskGroup(of: DroppedMedia.self) { group in
                for (index, provider) in providers.enumerated() {
                    group.addTask {
                        guard let url = await Self.loadMediaURL(from: provider) else {
                            return DroppedMedia(index: index, urls: [])
                        }
                        let result = MediaImporter.collect(from: [url])
                        return DroppedMedia(index: index, urls: result.urls)
                    }
                }

                var results: [DroppedMedia] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            let urls = indexedResults
                .sorted { $0.index < $1.index }
                .flatMap(\.urls)

            if !urls.isEmpty {
                await MainActor.run {
                    callback(urls)
                }
            }
        }
        return true
    }

    nonisolated private static func loadMediaURL(from provider: NSItemProvider) async -> URL? {
        if let url = await loadFileURL(from: provider) {
            return url
        }

        guard let type = provider.registeredContentTypes.first(where: { type in
            type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .video)
        }) else {
            return nil
        }

        if let inPlaceURL = await loadInPlaceFileURL(from: provider, contentType: type) {
            return inPlaceURL
        }

        return await loadCopiedRepresentation(from: provider, contentType: type)
    }

    nonisolated private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func loadInPlaceFileURL(from provider: NSItemProvider, contentType: UTType) async -> URL? {
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: contentType.identifier) { url, isInPlace, _ in
                continuation.resume(returning: isInPlace ? url : nil)
            }
        }
    }

    nonisolated private static func loadCopiedRepresentation(from provider: NSItemProvider, contentType: UTType) async -> URL? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadFileRepresentation(forTypeIdentifier: contentType.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                let copiedURL = try? MediaImportCache.copyImportedFile(
                    from: url,
                    suggestedName: suggestedName,
                    contentType: contentType
                )
                continuation.resume(returning: copiedURL)
            }
        }
    }
}

private extension NSItemProvider {
    var registeredContentTypes: [UTType] {
        registeredTypeIdentifiers.compactMap(UTType.init)
    }
}

private struct DroppedMedia: Sendable {
    let index: Int
    let urls: [URL]
}

struct MediaImportResult: Sendable {
    let urls: [URL]
    let emptyFolderCount: Int
    let skippedFileCount: Int
}

enum MediaImporter {
    nonisolated static func collectCancellable(
        from urls: [URL],
        priority: TaskPriority = .userInitiated
    ) async -> MediaImportResult {
        let task = Task.detached(priority: priority) {
            collect(from: urls)
        }

        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func collect(from urls: [URL]) -> MediaImportResult {
        var mediaURLs: [URL] = []
        var emptyFolderCount = 0
        var skippedFileCount = 0

        for url in urls {
            if Task.isCancelled { break }

            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let scan = url.recursiveMediaScan()
                mediaURLs.append(contentsOf: scan.urls)
                skippedFileCount += scan.skippedFileCount
                if scan.urls.isEmpty {
                    emptyFolderCount += 1
                }
            } else if url.isSupportedMedia {
                mediaURLs.append(url)
            } else {
                skippedFileCount += 1
            }
        }

        return MediaImportResult(
            urls: mediaURLs,
            emptyFolderCount: emptyFolderCount,
            skippedFileCount: skippedFileCount
        )
    }
}
