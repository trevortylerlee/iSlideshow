import SwiftUI
import ImageIO

@MainActor
final class SlideshowEngine: ObservableObject {
    @Published var mediaItems: [MediaItem] = []
    @Published var currentIndex: Int = 0
    @Published var isPlaying: Bool = false
    @Published var duration: Double = defaultDuration
    @Published var isLooping: Bool = true
    @Published var slideStartDate: Date?
    @Published var slideEndDate: Date?

    private var timerTask: Task<Void, Never>?
    private var pausedFraction: Double = 0.0
    private var imageTasks: [ImageCacheKey: InFlightImageLoad] = [:]
    private let sleep: (UInt64) async -> Void
    private var displayMaxPixelSize: Int = SlideshowEngine.defaultDisplayMaxPixelSize

    /// Display-sized preloaded images keyed by URL and decode target.
    private var preloadedImages: [ImageCacheKey: NSImage] = [:]

    init(sleep: @escaping (UInt64) async -> Void = { nanoseconds in
        try? await Task.sleep(nanoseconds: nanoseconds)
    }) {
        self.sleep = sleep
    }

    var currentMediaURL: URL? {
        currentMediaItem?.url
    }

    var currentMediaItem: MediaItem? {
        guard !mediaItems.isEmpty, mediaItems.indices.contains(currentIndex) else { return nil }
        return mediaItems[currentIndex]
    }

    var totalCount: Int { mediaItems.count }
    var currentMediaIsVideo: Bool { currentMediaItem?.isVideo == true }

    func cachedImage(for url: URL, maxPixelSize: Int) -> NSImage? {
        preloadedImages[ImageCacheKey(url: url, maxPixelSize: maxPixelSize)]
    }

    func loadDisplayImage(for url: URL, maxPixelSize: Int) async -> NSImage? {
        await image(for: url, maxPixelSize: maxPixelSize, priority: .userInitiated)
    }

    func updateDisplayMaxPixelSize(_ maxPixelSize: Int) {
        guard maxPixelSize > 0, maxPixelSize != displayMaxPixelSize else { return }
        displayMaxPixelSize = maxPixelSize
        for load in imageTasks.values { load.task.cancel() }
        imageTasks.removeAll()
        preloadedImages.removeAll()
        if !mediaItems.isEmpty {
            preloadAround(index: currentIndex)
        }
    }

    func configure(mediaURLs: [URL], duration: Double, isLooping: Bool, shuffle: Bool) {
        configure(
            mediaItems: mediaURLs.map { MediaItem(url: $0) },
            duration: duration,
            isLooping: isLooping,
            shuffle: shuffle
        )
    }

    func configure(mediaItems: [MediaItem], duration: Double, isLooping: Bool, shuffle: Bool) {
        stopTimer()
        for load in imageTasks.values { load.task.cancel() }
        imageTasks.removeAll()
        preloadedImages.removeAll()
        self.mediaItems = shuffle ? mediaItems.shuffled() : mediaItems
        self.duration = Self.sanitizedDuration(duration)
        self.isLooping = isLooping
        self.currentIndex = 0
        pausedFraction = 0
        guard !self.mediaItems.isEmpty else { return }
        preloadAround(index: 0)
    }

    func play() {
        guard !mediaItems.isEmpty, !isPlaying else { return }
        // If on the last slide with no looping, restart from the beginning
        if currentIndex >= mediaItems.count - 1 && !isLooping && pausedFraction >= 1.0 {
            currentIndex = 0
            pausedFraction = 0
            preloadAround(index: 0)
        }
        isPlaying = true
        if !currentMediaIsVideo {
            startTimer(fromFraction: pausedFraction)
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        if let start = slideStartDate, let end = slideEndDate {
            let total = end.timeIntervalSince(start)
            let elapsed = Date().timeIntervalSince(start)
            pausedFraction = total > 0 ? min(elapsed / total, 1.0) : 0
        }
        stopTimer()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func next() {
        guard !mediaItems.isEmpty else { return }
        if currentIndex < mediaItems.count - 1 {
            currentIndex += 1
        } else if isLooping {
            currentIndex = 0
        } else {
            pause()
            pausedFraction = 1.0
            return
        }
        pausedFraction = 0
        preloadAround(index: currentIndex)
        restartTimerIfPlaying()
    }

    func previous() {
        guard !mediaItems.isEmpty else { return }
        if currentIndex > 0 {
            currentIndex -= 1
        } else if isLooping {
            currentIndex = mediaItems.count - 1
        }
        pausedFraction = 0
        preloadAround(index: currentIndex)
        restartTimerIfPlaying()
    }

    func stop() {
        isPlaying = false
        pausedFraction = 0
        stopTimer()
        for load in imageTasks.values { load.task.cancel() }
        imageTasks.removeAll()
        preloadedImages.removeAll()
    }

    // MARK: - Timer

    private func startTimer(fromFraction fraction: Double = 0) {
        let clamped = min(max(fraction, 0), 1)
        stopTimer()
        let remaining = max(0, duration * (1.0 - clamped))
        let now = Date()
        slideStartDate = now.addingTimeInterval(-duration * clamped)
        slideEndDate = now.addingTimeInterval(remaining)
        timerTask = Task { [weak self] in
            if remaining > 0 {
                await self?.sleep(UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.next()
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        slideStartDate = nil
        slideEndDate = nil
    }

    private func restartTimerIfPlaying() {
        pausedFraction = 0
        if isPlaying && !currentMediaIsVideo {
            startTimer()
        } else if isPlaying {
            stopTimer()
        }
    }

    // MARK: - Preloading

    private func preloadAround(index: Int) {
        guard !mediaItems.isEmpty else { return }
        let indices = [index - 1, index, index + 1]
        let validIndices = indices.compactMap { i -> Int? in
            if i >= 0 && i < mediaItems.count { return i }
            if isLooping {
                let wrapped = ((i % mediaItems.count) + mediaItems.count) % mediaItems.count
                return wrapped
            }
            return nil
        }
        let itemsToKeep = validIndices.map { mediaItems[$0] }
        let urlsToKeep = Set(itemsToKeep.map(\.url))

        // Cancel and remove tasks for images no longer near current
        let taskKeysToRemove = imageTasks.keys.filter { !urlsToKeep.contains($0.url) }
        for key in taskKeysToRemove {
            guard let load = imageTasks[key] else { continue }
            load.task.cancel()
            imageTasks.removeValue(forKey: key)
        }

        // Remove cached images not near current
        let cachedKeysToRemove = preloadedImages.keys.filter {
            !urlsToKeep.contains($0.url) || $0.maxPixelSize != displayMaxPixelSize
        }
        for key in cachedKeysToRemove {
            preloadedImages.removeValue(forKey: key)
        }

        // Load missing (skip videos — they don't use NSImage)
        for url in itemsToKeep.filter(\.isImage).map(\.url) {
            let targetMaxPixelSize = displayMaxPixelSize
            let key = ImageCacheKey(url: url, maxPixelSize: targetMaxPixelSize)
            guard preloadedImages[key] == nil, imageTasks[key] == nil else { continue }
            Task {
                _ = await image(for: url, maxPixelSize: targetMaxPixelSize, priority: .utility)
            }
        }
    }

    private func image(for url: URL, maxPixelSize: Int, priority: TaskPriority) async -> NSImage? {
        let key = ImageCacheKey(url: url, maxPixelSize: maxPixelSize)
        if let cached = preloadedImages[key] { return cached }
        if let existingLoad = imageTasks[key] { return await existingLoad.task.value }

        let id = UUID()
        let task = Task.detached(priority: priority) {
            Self.makeDisplayImage(for: url, maxPixelSize: maxPixelSize)
        }
        imageTasks[key] = InFlightImageLoad(id: id, task: task)

        let image = await task.value
        guard imageTasks[key]?.id == id else {
            return image
        }
        if let image {
            preloadedImages[key] = image
        }
        imageTasks.removeValue(forKey: key)
        return image
    }

    nonisolated private static func makeDisplayImage(for url: URL, maxPixelSize: Int) -> NSImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    static let defaultDuration: Double = 5.0
    static let minimumDuration: Double = 0.1
    static let maximumDuration: Double = 3_600

    static func sanitizedDuration(_ duration: Double) -> Double {
        guard duration.isFinite else { return defaultDuration }
        return min(max(duration, minimumDuration), maximumDuration)
    }

    private static let defaultDisplayMaxPixelSize = 4096

    private struct ImageCacheKey: Hashable {
        let url: URL
        let maxPixelSize: Int
    }

    private struct InFlightImageLoad {
        let id: UUID
        let task: Task<NSImage?, Never>
    }
}
