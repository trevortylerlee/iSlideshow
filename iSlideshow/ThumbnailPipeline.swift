import AppKit
import AVFoundation
import ImageIO
import QuickLookThumbnailing

actor ThumbnailPipeline {
    static let shared = ThumbnailPipeline()

    private let cache = NSCache<NSURL, NSImage>()
    private var inFlightTasks: [URL: InFlightThumbnailLoad] = [:]
    private var diskCache: ThumbnailDiskCache?
    private var cacheGeneration = UUID()

    private init() {
        cache.countLimit = 96
        cache.totalCostLimit = 24 * 1024 * 1024
        diskCache = ThumbnailDiskCache()
    }

    func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        if let existingLoad = inFlightTasks[url] {
            return await existingLoad.task.value
        }

        let id = UUID()
        let generation = cacheGeneration
        let diskCache = diskCache
        let task = Task.detached(priority: .utility) {
            await Self.generateThumbnail(for: url, diskCache: diskCache)
        }
        inFlightTasks[url] = InFlightThumbnailLoad(id: id, task: task)

        let image = await task.value
        guard inFlightTasks[url]?.id == id, cacheGeneration == generation else {
            return image
        }
        if let image {
            cache.setObject(image, forKey: url as NSURL, cost: image.cacheCost)
        }
        inFlightTasks.removeValue(forKey: url)
        return image
    }

    func removeAll() {
        cacheGeneration = UUID()
        for load in inFlightTasks.values {
            load.task.cancel()
        }
        inFlightTasks.removeAll()
        cache.removeAllObjects()
    }

    func prefetch(urls: [URL]) async {
        guard !urls.isEmpty else { return }

        var urlsToLoad: [URL] = []
        var seen = Set<URL>()
        for url in urls where !url.isSupportedVideo && seen.insert(url).inserted {
            if cache.object(forKey: url as NSURL) != nil || inFlightTasks[url] != nil {
                continue
            }
            urlsToLoad.append(url)
        }

        guard !urlsToLoad.isEmpty else { return }

        var iterator = urlsToLoad.makeIterator()
        let workerCount = min(2, urlsToLoad.count)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                guard let url = iterator.next() else { break }
                group.addTask {
                    _ = await ThumbnailPipeline.shared.thumbnail(for: url)
                }
            }

            while await group.next() != nil {
                guard !Task.isCancelled, let url = iterator.next() else { continue }
                group.addTask {
                    _ = await ThumbnailPipeline.shared.thumbnail(for: url)
                }
            }
        }
    }

    nonisolated private static func generateThumbnail(
        for url: URL,
        diskCache: ThumbnailDiskCache?
    ) async -> NSImage? {
        if let cachedImage = diskCache?.image(for: url) {
            return cachedImage
        }

        guard !Task.isCancelled else { return nil }
        let generatedImage: NSImage?
        if url.isSupportedVideo {
            generatedImage = await ThumbnailWorkLimiter.shared.run {
                await generateVideoThumbnail(for: url)
            }
        } else {
            generatedImage = await ThumbnailWorkLimiter.shared.run {
                generateImageThumbnail(for: url)
            }
        }

        if let generatedImage {
            diskCache?.store(generatedImage, for: url)
        }
        return generatedImage
    }

    nonisolated private static func generateImageThumbnail(for url: URL) -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    nonisolated private static func generateVideoThumbnail(for url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        do {
            let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return await quickLookFallback(for: url)
        }
    }

    nonisolated private static func quickLookFallback(for url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 240, height: 240),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        let continuationBox = QuickLookThumbnailContinuation()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuationBox.setContinuation(continuation)
                if Task.isCancelled {
                    continuationBox.resume(nil)
                    return
                }

                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                    continuationBox.resume(Task.isCancelled ? nil : thumbnail?.nsImage)
                }
            }
        } onCancel: {
            continuationBox.resume(nil)
            QLThumbnailGenerator.shared.cancel(request)
        }
    }
}

private final class QuickLookThumbnailContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var didResume = false

    func setContinuation(_ continuation: CheckedContinuation<NSImage?, Never>) {
        lock.lock()
        if didResume {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ image: NSImage?) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: image)
    }
}

private struct InFlightThumbnailLoad {
    let id: UUID
    let task: Task<NSImage?, Never>
}

private actor ThumbnailWorkLimiter {
    static let shared = ThumbnailWorkLimiter()

    private var activeWorkCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: @Sendable @escaping () async -> NSImage?) async -> NSImage? {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        if activeWorkCount == 0 {
            activeWorkCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if !waiters.isEmpty {
            let continuation = waiters.removeFirst()
            continuation.resume()
        } else {
            activeWorkCount -= 1
        }
    }
}
