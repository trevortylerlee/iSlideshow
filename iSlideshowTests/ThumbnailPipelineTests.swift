import AppKit
import XCTest
@testable import iSlideshow

final class ThumbnailPipelineTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() async throws {
        await ThumbnailPipeline.shared.removeAll()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try await super.tearDown()
    }

    func testInvalidImageThumbnailReturnsNil() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("broken.jpg")
        try Data("not image data".utf8).write(to: url)

        let thumbnail = await ThumbnailPipeline.shared.thumbnail(for: url)

        XCTAssertNil(thumbnail)
    }

    func testSharedThumbnailRequestsReturnTheSameGeneratedImage() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("pixel.png")
        try Self.pixelPNGData.write(to: url)

        async let first = ThumbnailPipeline.shared.thumbnail(for: url)
        async let second = ThumbnailPipeline.shared.thumbnail(for: url)

        let firstThumbnail = await first
        let secondThumbnail = await second
        XCTAssertNotNil(firstThumbnail)
        XCTAssertNotNil(secondThumbnail)
    }

    func testDiskCacheInvalidatesWhenSourceChangesWithSameVisibleMetadata() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("source.png")
        try Self.pixelPNGData.write(to: sourceURL)

        let initialDate = Date(timeIntervalSinceReferenceDate: 1_000)
        try FileManager.default.setAttributes([.modificationDate: initialDate], ofItemAtPath: sourceURL.path)

        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        let cache = ThumbnailDiskCache(directory: cacheDirectory, maxDiskBytes: 1024 * 1024)
        let image = try makeTestImage()
        cache.store(image, for: sourceURL)
        XCTAssertNotNil(cache.image(for: sourceURL))

        try Data(repeating: 1, count: Self.pixelPNGData.count).write(to: sourceURL)
        try FileManager.default.setAttributes([.modificationDate: initialDate], ofItemAtPath: sourceURL.path)

        XCTAssertNil(cache.image(for: sourceURL))
    }

    func testDiskCacheTrimsOnStartupToByteThreshold() throws {
        let directory = try makeTemporaryDirectory()
        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        for index in 0..<3 {
            let fileURL = cacheDirectory.appendingPathComponent("thumb-\(index).png")
            try Data(repeating: UInt8(index), count: 40).write(to: fileURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceReferenceDate: Double(index))],
                ofItemAtPath: fileURL.path
            )
        }

        _ = ThumbnailDiskCache(directory: cacheDirectory, maxDiskBytes: 100)

        XCTAssertLessThanOrEqual(try cacheDirectoryByteCount(cacheDirectory), 90)
    }

    func testDiskCacheTrimsAfterStoreExceedsByteThreshold() throws {
        let directory = try makeTemporaryDirectory()
        let cacheDirectory = directory.appendingPathComponent("cache", isDirectory: true)
        let cache = ThumbnailDiskCache(directory: cacheDirectory, maxDiskBytes: 1)
        let sourceURL = directory.appendingPathComponent("source.png")
        try Self.pixelPNGData.write(to: sourceURL)

        let image = try makeTestImage()
        cache.store(image, for: sourceURL)

        XCTAssertLessThanOrEqual(try cacheDirectoryByteCount(cacheDirectory), 1)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iSlideshowThumbnailTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func cacheDirectoryByteCount(_ directory: URL) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalBytes = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            totalBytes += values.fileSize ?? 0
        }
        return totalBytes
    }

    private func makeTestImage() throws -> NSImage {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 4,
            bitsPerPixel: 32
        ))
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.addRepresentation(bitmap)
        return image
    }

    private static let pixelPNGData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )!
}
