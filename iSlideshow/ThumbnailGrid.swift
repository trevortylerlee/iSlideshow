import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

struct ThumbnailGrid: View {
    @ObservedObject var playlist: Playlist
    @AppStorage(DragExportOperation.storageKey) private var dragExportOperationRawValue: String = DragExportOperation.copy.rawValue

    static let cellMinWidth: CGFloat = 140
    static let itemSpacing: CGFloat = 3

    var body: some View {
        AppKitThumbnailGrid(
            playlist: playlist,
            dragExportOperation: DragExportOperation(rawValue: dragExportOperationRawValue) ?? .copy
        )
            .task(id: playlist.count) {
                await ThumbnailPipeline.shared.prefetch(urls: Array(playlist.items.prefix(64).filter(\.isImage).map(\.url)))
            }
    }
}

@MainActor
private struct AppKitThumbnailGrid: NSViewRepresentable {
    @ObservedObject var playlist: Playlist
    let dragExportOperation: DragExportOperation

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 142, height: 126)
        layout.minimumInteritemSpacing = ThumbnailGrid.itemSpacing
        layout.minimumLineSpacing = ThumbnailGrid.itemSpacing
        layout.sectionInset = NSEdgeInsets(top: 11, left: 10, bottom: 11, right: 10)

        let collectionView = ThumbnailCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.gridCoordinator = context.coordinator
        collectionView.register(
            ThumbnailCollectionViewItem.self,
            forItemWithIdentifier: ThumbnailCollectionViewItem.reuseIdentifier
        )
        let promisedFileTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        collectionView.registerForDraggedTypes([.iSlideshowMediaItemID, .fileURL] + promisedFileTypes)
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.setDraggingSourceOperationMask(dragExportOperation.dragOperation, forLocal: false)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView

        context.coordinator.collectionView = collectionView
        context.coordinator.applySnapshot()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.collectionView = nsView.documentView as? NSCollectionView
        context.coordinator.collectionView?.setDraggingSourceOperationMask(dragExportOperation.dragOperation, forLocal: false)
        context.coordinator.applySnapshot()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        var parent: AppKitThumbnailGrid
        weak var collectionView: NSCollectionView?

        private var items: [MediaItem] = []
        private var itemIDs: [MediaItem.ID] = []
        private var isApplyingSelection = false
        private var selectionAnchorIndex: Int?
        private var pendingSelectionFocusID: MediaItem.ID?
        private var lastSelectedItemID: MediaItem.ID?
        private var quickLookItem: MediaItem?
        private var draggedItems: [MediaItem] = []

        init(_ parent: AppKitThumbnailGrid) {
            self.parent = parent
        }

        func applySnapshot() {
            guard let collectionView else { return }

            let newItems = parent.playlist.items
            let newIDs = newItems.map(\.id)
            if newIDs != itemIDs {
                items = newItems
                itemIDs = newIDs
                collectionView.reloadData()
            } else {
                items = newItems
                refreshVisibleItems(in: collectionView)
            }

            syncSelection(to: parent.playlist.selection, in: collectionView)
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let itemView = collectionView.makeItem(
                withIdentifier: ThumbnailCollectionViewItem.reuseIdentifier,
                for: indexPath
            )
            guard let thumbnailItem = itemView as? ThumbnailCollectionViewItem else {
                return itemView
            }

            let item = items[indexPath.item]
            thumbnailItem.configure(with: item, isSelected: collectionView.selectionIndexPaths.contains(indexPath))
            return thumbnailItem
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            updatePlaylistSelection(from: collectionView, newlySelectedIndexPaths: indexPaths)
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            updatePlaylistSelection(from: collectionView)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            canDragItemsAt indexPaths: Set<IndexPath>,
            with event: NSEvent
        ) -> Bool {
            true
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            pasteboardWriterForItemAt indexPath: IndexPath
        ) -> NSPasteboardWriting? {
            guard items.indices.contains(indexPath.item) else { return nil }
            return pasteboardWriter(for: items[indexPath.item])
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItemsAt indexPaths: Set<IndexPath>
        ) {
            draggedItems = indexPaths
                .compactMap { indexPath in
                    items.indices.contains(indexPath.item) ? items[indexPath.item] : nil
                }
                .sorted { lhs, rhs in
                    guard let left = items.firstIndex(of: lhs),
                          let right = items.firstIndex(of: rhs) else {
                        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                    }
                    return left < right
                }
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            dragOperation operation: NSDragOperation
        ) {
            draggedItems.removeAll()
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            validateDrop draggingInfo: NSDraggingInfo,
            proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
            dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
        ) -> NSDragOperation {
            if isLocalReorder(draggingInfo, in: collectionView) {
                proposedDropOperation.pointee = .before
                return .move
            }

            let pasteboard = draggingInfo.draggingPasteboard
            if fileURLs(from: pasteboard).isEmpty && filePromiseReceivers(from: pasteboard).isEmpty {
                return []
            }

            proposedDropOperation.pointee = .before
            return .copy
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            acceptDrop draggingInfo: NSDraggingInfo,
            indexPath: IndexPath,
            dropOperation: NSCollectionView.DropOperation
        ) -> Bool {
            let pasteboard = draggingInfo.draggingPasteboard

            if isLocalReorder(draggingInfo, in: collectionView),
               let draggedID = draggedItems.first?.id {
                let oldIDs = itemIDs
                parent.playlist.moveItems(containing: draggedID, toInsertionIndex: indexPath.item)
                applyReorderSnapshot(from: oldIDs, in: collectionView)
                return true
            }

            let urls = fileURLs(from: pasteboard)
            if !urls.isEmpty {
                let result = MediaImporter.collect(from: urls)
                guard !result.urls.isEmpty else { return false }
                _ = parent.playlist.insertURLs(result.urls, at: indexPath.item)
                return true
            }

            let receivers = filePromiseReceivers(from: pasteboard)
            guard !receivers.isEmpty else { return false }
            let insertionIndex = indexPath.item
            Task {
                let promisedURLs = await Self.receivePromisedFiles(from: receivers)
                let result = await Task.detached(priority: .userInitiated) {
                    MediaImporter.collect(from: promisedURLs)
                }.value
                guard !result.urls.isEmpty else { return }
                _ = parent.playlist.insertURLs(result.urls, at: insertionIndex)
            }
            return true
        }

        func menu(for event: NSEvent, in collectionView: NSCollectionView) -> NSMenu? {
            let point = collectionView.convert(event.locationInWindow, from: nil)
            guard collectionView.indexPathForItem(at: point) != nil else { return nil }

            let menu = NSMenu()
            let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelectedInFinder), keyEquivalent: "")
            revealItem.target = self
            menu.addItem(revealItem)

            menu.addItem(.separator())

            let removeItem = NSMenuItem(title: "Remove", action: #selector(removeSelectedItems), keyEquivalent: "")
            removeItem.target = self
            menu.addItem(removeItem)
            return menu
        }

        func selectForContextClick(at point: NSPoint, in collectionView: NSCollectionView) {
            guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
            if !collectionView.selectionIndexPaths.contains(indexPath) {
                isApplyingSelection = true
                collectionView.deselectItems(at: collectionView.selectionIndexPaths)
                collectionView.selectItems(at: [indexPath], scrollPosition: [])
                isApplyingSelection = false
                pendingSelectionFocusID = items[indexPath.item].id
                updatePlaylistSelection(from: collectionView)
            }
        }

        func deleteSelection() {
            guard !parent.playlist.selection.isEmpty else { return }
            parent.playlist.removeSelected()
        }

        func handlePrimaryMouseDown(_ event: NSEvent, in collectionView: NSCollectionView) -> Bool {
            let point = collectionView.convert(event.locationInWindow, from: nil)
            guard let indexPath = collectionView.indexPathForItem(at: point) else {
                selectionAnchorIndex = nil
                return false
            }

            if event.modifierFlags.contains(.shift) {
                selectRange(endingAt: indexPath.item, in: collectionView)
                return true
            }

            if !event.modifierFlags.contains(.command) {
                selectionAnchorIndex = indexPath.item
            }
            pendingSelectionFocusID = items[indexPath.item].id
            return false
        }

        func selectAll() {
            guard let collectionView else { return }
            let indexPaths = Set(items.indices.map { IndexPath(item: $0, section: 0) })
            isApplyingSelection = true
            collectionView.selectItems(at: indexPaths, scrollPosition: [])
            isApplyingSelection = false
            selectionAnchorIndex = items.indices.first
            lastSelectedItemID = items.first?.id
            updatePlaylistSelection(from: collectionView)
        }

        func toggleQuickLookPreview() {
            if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
                panel.orderOut(nil)
                return
            }

            guard let item = itemForQuickLookPreview() else { return }
            quickLookItem = item

            guard let panel = QLPreviewPanel.shared() else { return }
            panel.dataSource = self
            panel.delegate = self
            panel.currentPreviewItemIndex = 0
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }

        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            quickLookItem == nil ? 0 : 1
        }

        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            guard index == 0 else { return nil }
            return quickLookItem?.url as NSURL?
        }

        func previewPanelWillClose(_ panel: QLPreviewPanel!) {
            quickLookItem = nil
        }

        @objc private func revealSelectedInFinder() {
            let selectedIDs = parent.playlist.selection
            let urls = parent.playlist.items
                .filter { selectedIDs.contains($0.id) }
                .map(\.url)
            guard !urls.isEmpty else { return }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }

        @objc private func removeSelectedItems() {
            deleteSelection()
        }

        private func updatePlaylistSelection(
            from collectionView: NSCollectionView,
            newlySelectedIndexPaths: Set<IndexPath> = []
        ) {
            guard !isApplyingSelection else { return }
            let selectedIDs = Set(collectionView.selectionIndexPaths.compactMap { indexPath in
                items.indices.contains(indexPath.item) ? items[indexPath.item].id : nil
            })
            if parent.playlist.selection != selectedIDs {
                parent.playlist.selection = selectedIDs
            }
            updateLastSelectedItem(
                selectedIDs: selectedIDs,
                newlySelectedIndexPaths: newlySelectedIndexPaths
            )
            refreshQuickLookPreviewIfNeeded()
            refreshVisibleItems(in: collectionView)
        }

        private func isLocalReorder(_ draggingInfo: NSDraggingInfo, in collectionView: NSCollectionView) -> Bool {
            guard draggingInfo.draggingSource as AnyObject? === collectionView else { return false }
            return !draggedItems.isEmpty
        }

        private func promisedFileType(for item: MediaItem) -> String {
            item.url.resolvedContentType?.identifier ?? UTType.data.identifier
        }

        private func pasteboardWriter(for item: MediaItem) -> NSPasteboardWriting {
            switch parent.dragExportOperation {
            case .copy:
                return fileURLPasteboardItem(for: item)
            case .move:
                return filePromiseProvider(for: item)
            }
        }

        private func fileURLPasteboardItem(for item: MediaItem) -> NSPasteboardItem {
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(item.url.absoluteString, forType: .fileURL)
            return pasteboardItem
        }

        private func filePromiseProvider(for item: MediaItem) -> NSFilePromiseProvider {
            let provider = NSFilePromiseProvider(
                fileType: promisedFileType(for: item),
                delegate: self
            )
            provider.userInfo = DraggedMediaExport(
                itemID: item.id,
                sourceURL: item.url,
                fileName: item.displayName,
                operation: parent.dragExportOperation,
                playlist: parent.playlist
            )
            return provider
        }

        private func selectRange(endingAt endIndex: Int, in collectionView: NSCollectionView) {
            let anchorIndex = selectionAnchorIndex
                ?? collectionView.selectionIndexPaths.map(\.item).min()
                ?? endIndex
            guard items.indices.contains(anchorIndex), items.indices.contains(endIndex) else { return }

            let range = min(anchorIndex, endIndex)...max(anchorIndex, endIndex)
            let indexPaths = Set(range.map { IndexPath(item: $0, section: 0) })

            isApplyingSelection = true
            collectionView.deselectItems(at: collectionView.selectionIndexPaths.subtracting(indexPaths))
            collectionView.selectItems(at: indexPaths.subtracting(collectionView.selectionIndexPaths), scrollPosition: [])
            isApplyingSelection = false
            selectionAnchorIndex = anchorIndex
            pendingSelectionFocusID = items[endIndex].id
            updatePlaylistSelection(from: collectionView)
        }

        private func syncSelection(to selectedIDs: Set<MediaItem.ID>, in collectionView: NSCollectionView) {
            let targetIndexPaths = Set(items.enumerated().compactMap { index, item in
                selectedIDs.contains(item.id) ? IndexPath(item: index, section: 0) : nil
            })

            guard collectionView.selectionIndexPaths != targetIndexPaths else { return }

            isApplyingSelection = true
            collectionView.deselectItems(at: collectionView.selectionIndexPaths.subtracting(targetIndexPaths))
            collectionView.selectItems(at: targetIndexPaths.subtracting(collectionView.selectionIndexPaths), scrollPosition: [])
            isApplyingSelection = false
            if let lastSelectedItemID, !selectedIDs.contains(lastSelectedItemID) {
                self.lastSelectedItemID = firstSelectedItem(in: selectedIDs)?.id
            }
            refreshVisibleItems(in: collectionView)
        }

        private func updateLastSelectedItem(
            selectedIDs: Set<MediaItem.ID>,
            newlySelectedIndexPaths: Set<IndexPath>
        ) {
            defer { pendingSelectionFocusID = nil }

            if let pendingSelectionFocusID, selectedIDs.contains(pendingSelectionFocusID) {
                lastSelectedItemID = pendingSelectionFocusID
            } else if let newlySelectedItem = newlySelectedIndexPaths
                .sorted(by: { $0.item < $1.item })
                .last
                .flatMap({ items.indices.contains($0.item) ? items[$0.item] : nil }),
                selectedIDs.contains(newlySelectedItem.id) {
                lastSelectedItemID = newlySelectedItem.id
            } else if let lastSelectedItemID, !selectedIDs.contains(lastSelectedItemID) {
                self.lastSelectedItemID = firstSelectedItem(in: selectedIDs)?.id
            } else if lastSelectedItemID == nil {
                lastSelectedItemID = firstSelectedItem(in: selectedIDs)?.id
            }
        }

        private func itemForQuickLookPreview() -> MediaItem? {
            if let lastSelectedItemID,
               parent.playlist.selection.contains(lastSelectedItemID),
               let item = items.first(where: { $0.id == lastSelectedItemID }) {
                return item
            }

            return firstSelectedItem(in: parent.playlist.selection)
        }

        private func firstSelectedItem(in selectedIDs: Set<MediaItem.ID>) -> MediaItem? {
            items.first { selectedIDs.contains($0.id) }
        }

        private func refreshQuickLookPreviewIfNeeded() {
            guard QLPreviewPanel.sharedPreviewPanelExists(),
                  let panel = QLPreviewPanel.shared(),
                  panel.isVisible else {
                return
            }

            guard let item = itemForQuickLookPreview() else {
                quickLookItem = nil
                panel.orderOut(nil)
                return
            }

            quickLookItem = item
            panel.reloadData()
        }

        private func applyReorderSnapshot(from oldIDs: [MediaItem.ID], in collectionView: NSCollectionView) {
            let newItems = parent.playlist.items
            let newIDs = newItems.map(\.id)
            items = newItems
            itemIDs = newIDs

            guard oldIDs != newIDs else {
                syncSelection(to: parent.playlist.selection, in: collectionView)
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                collectionView.performBatchUpdates({
                    var current = oldIDs
                    for (targetIndex, id) in newIDs.enumerated() {
                        guard let sourceIndex = current.firstIndex(of: id),
                              sourceIndex != targetIndex else { continue }
                        collectionView.moveItem(
                            at: IndexPath(item: sourceIndex, section: 0),
                            to: IndexPath(item: targetIndex, section: 0)
                        )
                        current.remove(at: sourceIndex)
                        current.insert(id, at: targetIndex)
                    }
                }, completionHandler: nil)
            }

            syncSelection(to: parent.playlist.selection, in: collectionView)
        }

        private func refreshVisibleItems(in collectionView: NSCollectionView) {
            for case let item as ThumbnailCollectionViewItem in collectionView.visibleItems() {
                guard let indexPath = collectionView.indexPath(for: item),
                      items.indices.contains(indexPath.item) else { continue }
                item.configure(
                    with: items[indexPath.item],
                    isSelected: collectionView.selectionIndexPaths.contains(indexPath)
                )
            }
        }

        private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
            return objects.compactMap { object in
                if let url = object as? URL { return url }
                if let url = object as? NSURL { return url as URL }
                return nil
            }
        }

        private func filePromiseReceivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
            pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        }

        nonisolated private static func receivePromisedFiles(from receivers: [NSFilePromiseReceiver]) async -> [URL] {
            guard !receivers.isEmpty,
                  let destinationDirectory = try? MediaImportCache.createImportBatchDirectory() else {
                return []
            }

            return await withTaskGroup(of: PromisedFile.self) { group in
                for (index, receiver) in receivers.enumerated() {
                    group.addTask {
                        let url = await receivePromisedFile(from: receiver, at: destinationDirectory)
                        return PromisedFile(index: index, url: url)
                    }
                }

                var files: [PromisedFile] = []
                for await file in group {
                    files.append(file)
                }
                return files
                    .sorted { $0.index < $1.index }
                    .compactMap(\.url)
            }
        }

        nonisolated private static func receivePromisedFile(
            from receiver: NSFilePromiseReceiver,
            at destinationDirectory: URL
        ) async -> URL? {
            await withCheckedContinuation { continuation in
                var didResume = false
                receiver.receivePromisedFiles(
                    atDestination: destinationDirectory,
                    options: [:],
                    operationQueue: .main
                ) { fileURL, error in
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: error == nil ? fileURL : nil)
                }
            }
        }
    }
}

extension AppKitThumbnailGrid.Coordinator: NSFilePromiseProviderDelegate {
    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        dragExportOperationQueue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        promisedExport(from: filePromiseProvider)?.fileName ?? "iSlideshow Media"
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo destinationURL: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let export = promisedExport(from: filePromiseProvider) else {
            completionHandler(DragExportError.missingExport)
            return
        }

        do {
            switch export.operation {
            case .copy:
                try MediaFileTransfer.copy(from: export.sourceURL, to: destinationURL)
            case .move:
                try MediaFileTransfer.move(from: export.sourceURL, to: destinationURL)
                Task { @MainActor [weak playlist = export.playlist] in
                    playlist?.updateMediaURL(for: export.itemID, to: destinationURL)
                }
            }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    nonisolated private func promisedExport(from filePromiseProvider: NSFilePromiseProvider) -> DraggedMediaExport? {
        filePromiseProvider.userInfo as? DraggedMediaExport
    }
}

private let dragExportOperationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "iSlideshow Drag Export"
    queue.qualityOfService = .userInitiated
    return queue
}()

private final class DraggedMediaExport: @unchecked Sendable {
    let itemID: MediaItem.ID
    let sourceURL: URL
    let fileName: String
    let operation: DragExportOperation
    weak var playlist: Playlist?

    init(
        itemID: MediaItem.ID,
        sourceURL: URL,
        fileName: String,
        operation: DragExportOperation,
        playlist: Playlist
    ) {
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.fileName = fileName
        self.operation = operation
        self.playlist = playlist
    }
}

private enum DragExportError: LocalizedError {
    case missingExport
    case copiedButCouldNotRemoveOriginal(URL)

    var errorDescription: String? {
        switch self {
        case .missingExport:
            "The dragged media item is no longer available."
        case .copiedButCouldNotRemoveOriginal(let url):
            "The file was copied, but the original could not be removed: \(url.path)"
        }
    }
}

enum MediaFileTransfer {
    static func copy(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: MediaFileManaging = FileManager.default
    ) throws {
        try fileManager.copyItem(at: sourceURL, to: destinationURL)
    }

    static func move(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: MediaFileManaging = FileManager.default
    ) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try copy(from: sourceURL, to: destinationURL, fileManager: fileManager)
            do {
                try fileManager.removeItem(at: sourceURL)
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw DragExportError.copiedButCouldNotRemoveOriginal(sourceURL)
            }
        }
    }
}

protocol MediaFileManaging {
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at url: URL) throws
}

extension FileManager: MediaFileManaging {}

private struct PromisedFile: Sendable {
    let index: Int
    let url: URL?
}

@MainActor
private final class ThumbnailCollectionView: NSCollectionView {
    weak var gridCoordinator: AppKitThumbnailGrid.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:
            gridCoordinator?.deleteSelection()
        case 0 where event.modifierFlags.contains(.command):
            gridCoordinator?.selectAll()
        case 49 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
            gridCoordinator?.toggleQuickLookPreview()
        case 36, 76:
            // Forward Return / Numpad Enter past NSCollectionView so SwiftUI's
            // .keyboardShortcut(.return, modifiers: []) menu command can fire.
            nextResponder?.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if gridCoordinator?.handlePrimaryMouseDown(event, in: self) == true {
            return
        }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        gridCoordinator?.selectForContextClick(at: point, in: self)
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        gridCoordinator?.menu(for: event, in: self)
    }
}

@MainActor
private final class ThumbnailCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ThumbnailCollectionViewItem")

    private var mediaItem: MediaItem?
    private var hostingView: NSHostingView<ThumbnailCell>?

    override var isSelected: Bool {
        didSet {
            updateHostedCell()
        }
    }

    override func loadView() {
        view = NSView()
    }

    func configure(with item: MediaItem, isSelected: Bool) {
        mediaItem = item

        if self.isSelected != isSelected {
            self.isSelected = isSelected
        }

        if hostingView == nil {
            let hostingView = NSHostingView(rootView: ThumbnailCell(item: item, isSelected: isSelected))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            hostingView.setContentHuggingPriority(.required, for: .horizontal)
            hostingView.setContentHuggingPriority(.required, for: .vertical)
            view.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: view.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            self.hostingView = hostingView
        }

        updateHostedCell()
    }

    private func updateHostedCell() {
        guard let mediaItem else { return }
        hostingView?.rootView = ThumbnailCell(item: mediaItem, isSelected: isSelected)
    }
}

private extension NSPasteboard.PasteboardType {
    static let iSlideshowMediaItemID = NSPasteboard.PasteboardType("com.trevortylerlee.iSlideshow.media-item-id")
}
