import XCTest
@testable import iSlideshow

final class URLMediaTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testSupportedMediaAndPlaybackVideoChecksAreCaseInsensitive() {
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/photo.JPEG").isSupportedMedia)
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/render.WEBP").isSupportedMedia)
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/clip.M4V").isSupportedMedia)
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/clip.M4V").isSupportedVideo)
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/clip.MKV").isSupportedMedia)
        XCTAssertFalse(URL(fileURLWithPath: "/tmp/clip.MKV").isSupportedVideo)
        XCTAssertFalse(URL(fileURLWithPath: "/tmp/clip.WEBM").isSupportedVideo)
        XCTAssertFalse(URL(fileURLWithPath: "/tmp/clip.AVI").isSupportedVideo)
        XCTAssertTrue(URL(fileURLWithPath: "/tmp/raw.CR2").isSupportedMedia)

        XCTAssertFalse(URL(fileURLWithPath: "/tmp/notes.txt").isSupportedMedia)
        XCTAssertFalse(URL(fileURLWithPath: "/tmp/photo.jpeg").isSupportedVideo)
    }

    func testRecursiveMediaURLsFiltersUnsupportedHiddenAndPackageDescendantFiles() throws {
        let root = try makeTemporaryDirectory()
        try createFile("cover.JPG", in: root)
        try createFile("notes.txt", in: root)
        try createFile(".hidden.png", in: root)

        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try createFile("clip.MOV", in: nested)

        let package = root.appendingPathComponent("Archive.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try createFile("inside.jpg", in: package)

        let mediaNames = root.recursiveMediaURLs().map(\.lastPathComponent)

        XCTAssertEqual(Set(mediaNames), Set(["clip.MOV", "cover.JPG"]))
    }

    func testRecursiveMediaURLsUsesLocalizedStandardFilenameOrder() throws {
        let root = try makeTemporaryDirectory()
        try createFile("slide 10.jpg", in: root)
        try createFile("slide 2.jpg", in: root)
        try createFile("slide 1.jpg", in: root)

        let mediaNames = root.recursiveMediaURLs().map(\.lastPathComponent)

        XCTAssertEqual(mediaNames, ["slide 1.jpg", "slide 2.jpg", "slide 10.jpg"])
    }

    func testRecursiveMediaURLsSortsByRelativePathWhenNamesRepeat() throws {
        let root = try makeTemporaryDirectory()
        let first = root.appendingPathComponent("A", isDirectory: true)
        let second = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try createFile("slide 2.jpg", in: second)
        try createFile("slide 1.jpg", in: first)
        try createFile("slide 1.jpg", in: second)

        let relativePaths = root.recursiveMediaURLs().map {
            $0.path.replacingOccurrences(of: root.path + "/", with: "")
        }

        XCTAssertEqual(relativePaths, ["A/slide 1.jpg", "B/slide 1.jpg", "B/slide 2.jpg"])
    }

    func testRecursiveMediaScanHandlesLargeNestedDirectories() throws {
        let root = try makeTemporaryDirectory()

        for folderIndex in 0..<12 {
            let nested = root
                .appendingPathComponent("Folder \(folderIndex)", isDirectory: true)
                .appendingPathComponent("Nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            for fileIndex in 0..<20 {
                try createFile("clip \(fileIndex).mp4", in: nested)
                try createFile("notes \(fileIndex).txt", in: nested)
            }
        }

        let result = root.recursiveMediaScan()

        XCTAssertEqual(result.urls.count, 240)
        XCTAssertEqual(result.skippedFileCount, 240)
        XCTAssertEqual(result.urls.first?.lastPathComponent, "clip 0.mp4")
        XCTAssertEqual(result.urls.last?.lastPathComponent, "clip 19.mp4")
    }

    func testMediaImporterCollectsMediaAndCountsEmptyFolders() throws {
        let mediaRoot = try makeTemporaryDirectory()
        try createFile("photo.jpg", in: mediaRoot)
        try createFile("notes.txt", in: mediaRoot)

        let emptyRoot = try makeTemporaryDirectory()

        let result = MediaImporter.collect(from: [
            mediaRoot,
            emptyRoot,
            URL(fileURLWithPath: "/tmp/unsupported.txt")
        ])

        XCTAssertEqual(result.urls.map(\.lastPathComponent), ["photo.jpg"])
        XCTAssertEqual(result.emptyFolderCount, 1)
        XCTAssertEqual(result.skippedFileCount, 2)
    }

    func testTransientImportCacheUsesCachesDirectory() {
        let cacheURL = MediaImportCache.directoryURL

        XCTAssertTrue(cacheURL.path.contains("/Caches/"))
        XCTAssertEqual(cacheURL.lastPathComponent, "ImportedMedia")
    }

    func testTransientImportCachePathIsScopedUnderAppFolder() throws {
        let baseURL = try makeTemporaryDirectory()
        let cacheURL = MediaImportCache.directoryURL(baseURL: baseURL)

        XCTAssertEqual(
            cacheURL.path,
            baseURL
                .appendingPathComponent("iSlideshow", isDirectory: true)
                .appendingPathComponent("ImportedMedia", isDirectory: true)
                .path
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iSlideshowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func createFile(_ name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)
    }
}
