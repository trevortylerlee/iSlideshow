import XCTest
@testable import iSlideshow

@MainActor
final class PlaylistTests: XCTestCase {
    func testAddURLsSkipsDuplicatesAndPreservesOrder() {
        let playlist = Playlist()
        let first = mediaURL("slide 1.jpg")
        let second = mediaURL("slide 2.jpg")

        let addedCount = playlist.addURLs([first, second, first])

        XCTAssertEqual(addedCount, 2)
        XCTAssertEqual(playlist.items.map(\.url), [first, second])
    }

    func testAddItemsSkipsDuplicatesAcrossBatches() {
        let playlist = Playlist()
        let first = mediaURL("slide 1.jpg")
        let second = mediaURL("slide 2.jpg")

        XCTAssertEqual(playlist.addItems([MediaItem(url: first)]), 1)
        XCTAssertEqual(playlist.addItems([MediaItem(url: first), MediaItem(url: second)]), 1)

        XCTAssertEqual(playlist.items.map(\.url), [first, second])
    }

    func testFileSizeTotalsTrackAddedUniqueItems() {
        let playlist = Playlist()
        let first = MediaItem(url: mediaURL("one.mov"), fileSize: 10)
        let duplicateFirst = MediaItem(url: first.url, fileSize: 99)
        let second = MediaItem(url: mediaURL("two.mov"), fileSize: 20)

        XCTAssertEqual(playlist.addItems([first, duplicateFirst, second]), 2)

        XCTAssertEqual(playlist.totalFileSizeBytes, 30)
    }

    func testFileSizeTotalsTrackSelectedItems() {
        let playlist = Playlist()
        let first = MediaItem(url: mediaURL("one.mov"), fileSize: 10)
        let second = MediaItem(url: mediaURL("two.mov"), fileSize: 20)
        playlist.addItems([first, second])

        playlist.selection = [second.id]

        XCTAssertEqual(playlist.selectedFileSizeBytes, 20)
    }

    func testFileSizeTotalsUpdateWhenRemovingSelectedItems() {
        let playlist = Playlist()
        let first = MediaItem(url: mediaURL("one.mov"), fileSize: 10)
        let second = MediaItem(url: mediaURL("two.mov"), fileSize: 20)
        playlist.addItems([first, second])
        playlist.selection = [first.id]

        playlist.removeSelected()

        XCTAssertEqual(playlist.totalFileSizeBytes, 20)
        XCTAssertEqual(playlist.selectedFileSizeBytes, 0)
    }

    func testUpdatingMediaURLKeepsItemAndSelection() {
        let playlist = Playlist()
        let first = MediaItem(url: mediaURL("one.jpg"), fileSize: 10)
        let second = MediaItem(url: mediaURL("two.jpg"), fileSize: 20)
        let movedURL = mediaURL("Moved/one.jpg")
        playlist.addItems([first, second])
        playlist.selection = [first.id]

        playlist.updateMediaURL(for: first.id, to: movedURL)

        XCTAssertEqual(playlist.items.map(\.id), [first.id, second.id])
        XCTAssertEqual(playlist.items.map(\.url), [movedURL, second.url])
        XCTAssertEqual(playlist.selection, [first.id])
        XCTAssertEqual(playlist.totalFileSizeBytes, 30)
        XCTAssertEqual(playlist.selectedFileSizeBytes, 10)
    }

    func testFileSizeTotalsResetWhenClearingItems() {
        let playlist = Playlist()
        playlist.addItems([
            MediaItem(url: mediaURL("one.mov"), fileSize: 10),
            MediaItem(url: mediaURL("two.mov"), fileSize: 20)
        ])
        playlist.selectAll()

        playlist.clear()

        XCTAssertEqual(playlist.totalFileSizeBytes, 0)
        XCTAssertEqual(playlist.selectedFileSizeBytes, 0)
    }

    func testFileSizeTotalsDoNotChangeWhenSortingOrMovingItems() {
        let playlist = Playlist()
        let first = MediaItem(url: mediaURL("one.mov"), fileSize: 10)
        let second = MediaItem(url: mediaURL("two.mov"), fileSize: 20)
        let third = MediaItem(url: mediaURL("three.mov"), fileSize: 30)
        playlist.addItems([first, second, third])
        playlist.selection = [first.id, third.id]

        playlist.applySort(.nameAscending)
        playlist.moveItems(containing: first.id, to: second.id)

        XCTAssertEqual(playlist.totalFileSizeBytes, 60)
        XCTAssertEqual(playlist.selectedFileSizeBytes, 40)
    }

    func testNameSortUsesLocalizedStandardOrder() {
        let playlist = Playlist()
        playlist.addURLs([
            mediaURL("slide 10.jpg"),
            mediaURL("slide 2.jpg"),
            mediaURL("slide 1.jpg")
        ])

        playlist.applySort(.nameAscending)

        XCTAssertEqual(
            playlist.items.map(\.displayName),
            ["slide 1.jpg", "slide 2.jpg", "slide 10.jpg"]
        )
    }

    func testMediaItemMarksUnsupportedVideoAsNotPlayable() {
        XCTAssertTrue(MediaItem(url: mediaURL("photo.jpg")).isPlayable)
        XCTAssertTrue(MediaItem(url: mediaURL("clip.mp4")).isPlayable)
        XCTAssertFalse(MediaItem(url: mediaURL("clip.mkv")).isPlayable)
        XCTAssertFalse(MediaItem(url: mediaURL("notes.txt")).isPlayable)
    }

    func testSortPreferenceAppliesToFutureImportsAfterClear() {
        let playlist = Playlist()

        playlist.applySort(.nameAscending)
        playlist.clear()
        playlist.addURLs([
            mediaURL("slide 10.jpg"),
            mediaURL("slide 2.jpg"),
            mediaURL("slide 1.jpg")
        ])

        XCTAssertEqual(playlist.sortMode, .nameAscending)
        XCTAssertEqual(
            playlist.items.map(\.displayName),
            ["slide 1.jpg", "slide 2.jpg", "slide 10.jpg"]
        )
    }

    func testMovingSelectedItemsSwitchesToManualOrder() {
        let playlist = Playlist()
        playlist.addURLs([
            mediaURL("one.jpg"),
            mediaURL("two.jpg"),
            mediaURL("three.jpg"),
            mediaURL("four.jpg")
        ])
        playlist.applySort(.nameAscending)

        let one = id(named: "one.jpg", in: playlist)
        let three = id(named: "three.jpg", in: playlist)
        let target = id(named: "two.jpg", in: playlist)
        playlist.selection = [one, three]

        playlist.moveItems(containing: one, to: target)

        XCTAssertEqual(playlist.items.map(\.displayName), ["four.jpg", "one.jpg", "three.jpg", "two.jpg"])
        XCTAssertEqual(playlist.sortMode, .manual)
    }

    func testMovingSingleItemToInsertionIndexAdjustsForRemoval() {
        let playlist = Playlist()
        playlist.addURLs([
            mediaURL("one.jpg"),
            mediaURL("two.jpg"),
            mediaURL("three.jpg"),
            mediaURL("four.jpg")
        ])
        let two = id(named: "two.jpg", in: playlist)

        playlist.moveItems(containing: two, toInsertionIndex: 4)

        XCTAssertEqual(playlist.items.map(\.displayName), ["one.jpg", "three.jpg", "four.jpg", "two.jpg"])
        XCTAssertEqual(playlist.sortMode, .manual)
    }

    func testMovingSelectedItemsToInsertionIndexPreservesRelativeOrder() {
        let playlist = Playlist()
        playlist.addURLs([
            mediaURL("one.jpg"),
            mediaURL("two.jpg"),
            mediaURL("three.jpg"),
            mediaURL("four.jpg")
        ])
        let one = id(named: "one.jpg", in: playlist)
        let three = id(named: "three.jpg", in: playlist)
        playlist.selection = [one, three]

        playlist.moveItems(containing: one, toInsertionIndex: 4)

        XCTAssertEqual(playlist.items.map(\.displayName), ["two.jpg", "four.jpg", "one.jpg", "three.jpg"])
        XCTAssertEqual(playlist.sortMode, .manual)
    }

    func testMoveExportUsesNativeMoveWhenAvailable() throws {
        let fileManager = MockMediaFileManager()
        let sourceURL = mediaURL("source.jpg")
        let destinationURL = mediaURL("destination.jpg")

        try MediaFileTransfer.move(from: sourceURL, to: destinationURL, fileManager: fileManager)

        XCTAssertEqual(fileManager.movedItems, [FileOperation(source: sourceURL, destination: destinationURL)])
        XCTAssertTrue(fileManager.copiedItems.isEmpty)
        XCTAssertTrue(fileManager.removedItems.isEmpty)
    }

    func testMoveExportRemovesOriginalAfterCopyFallback() throws {
        let fileManager = MockMediaFileManager()
        fileManager.moveError = MockFileError.operationFailed
        let sourceURL = mediaURL("source.jpg")
        let destinationURL = mediaURL("destination.jpg")

        try MediaFileTransfer.move(from: sourceURL, to: destinationURL, fileManager: fileManager)

        XCTAssertEqual(fileManager.copiedItems, [FileOperation(source: sourceURL, destination: destinationURL)])
        XCTAssertEqual(fileManager.removedItems, [sourceURL])
    }

    func testMoveExportRollsBackCopyWhenOriginalCannotBeRemoved() {
        let fileManager = MockMediaFileManager()
        let sourceURL = mediaURL("source.jpg")
        let destinationURL = mediaURL("destination.jpg")
        fileManager.moveError = MockFileError.operationFailed
        fileManager.removeErrors[sourceURL] = MockFileError.operationFailed

        XCTAssertThrowsError(
            try MediaFileTransfer.move(from: sourceURL, to: destinationURL, fileManager: fileManager)
        )
        XCTAssertEqual(fileManager.copiedItems, [FileOperation(source: sourceURL, destination: destinationURL)])
        XCTAssertEqual(fileManager.removedItems, [sourceURL, destinationURL])
    }

    private func mediaURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    private func id(named name: String, in playlist: Playlist) -> MediaItem.ID {
        playlist.items.first { $0.displayName == name }!.id
    }
}

private struct FileOperation: Equatable {
    let source: URL
    let destination: URL
}

private enum MockFileError: Error {
    case operationFailed
}

private final class MockMediaFileManager: MediaFileManaging {
    var moveError: Error?
    var copyError: Error?
    var removeErrors: [URL: Error] = [:]
    private(set) var movedItems: [FileOperation] = []
    private(set) var copiedItems: [FileOperation] = []
    private(set) var removedItems: [URL] = []

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if let copyError {
            throw copyError
        }
        copiedItems.append(FileOperation(source: srcURL, destination: dstURL))
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if let moveError {
            throw moveError
        }
        movedItems.append(FileOperation(source: srcURL, destination: dstURL))
    }

    func removeItem(at url: URL) throws {
        removedItems.append(url)
        if let error = removeErrors[url] {
            throw error
        }
    }
}
