import Foundation
import CoreGraphics
import UniformTypeIdentifiers

enum MediaKind: String, Hashable, Sendable {
    case image
    case video
    case other
}

struct MediaItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let kind: MediaKind
    let displayName: String
    let importedAt: Date
    let fileSize: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let dimensions: CGSize?
    let duration: TimeInterval?

    var isVideo: Bool { kind == .video }
    var isImage: Bool { kind == .image }
    var isPlayable: Bool {
        switch kind {
        case .image:
            true
        case .video:
            url.isSupportedVideo
        case .other:
            false
        }
    }

    init(
        id: UUID = UUID(),
        url: URL,
        importedAt: Date = Date(),
        fileSize: Int64? = nil
    ) {
        let values = try? url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
            .fileSizeKey,
            .contentTypeKey
        ])
        let contentType = values?.contentType ?? url.resolvedContentType
        let isVideo = contentType?.conforms(to: .movie) == true || contentType?.conforms(to: .video) == true
        let isImage = contentType?.conforms(to: .image) == true

        self.id = id
        self.url = url
        self.kind = isVideo ? .video : (isImage ? .image : .other)
        self.displayName = url.lastPathComponent
        self.importedAt = importedAt
        self.fileSize = fileSize ?? values?.fileSize.map(Int64.init)
        self.createdAt = values?.creationDate
        self.modifiedAt = values?.contentModificationDate
        self.dimensions = nil
        self.duration = nil
    }
}

enum PlaylistSortMode: String, CaseIterable, Identifiable {
    case manual
    case nameAscending
    case nameDescending
    case createdOldestFirst
    case createdNewestFirst
    case modifiedOldestFirst
    case modifiedNewestFirst
    case fileType

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .nameAscending: "Name A-Z"
        case .nameDescending: "Name Z-A"
        case .createdOldestFirst: "Created Oldest"
        case .createdNewestFirst: "Created Newest"
        case .modifiedOldestFirst: "Modified Oldest"
        case .modifiedNewestFirst: "Modified Newest"
        case .fileType: "File Type"
        }
    }
}

@MainActor
final class Playlist: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published var selection: Set<MediaItem.ID> = [] {
        didSet {
            selectedFileSizeBytes = fileSizeBytes(for: selection)
        }
    }
    @Published private(set) var sortMode: PlaylistSortMode = .manual
    private(set) var totalFileSizeBytes: Int64 = 0
    private(set) var selectedFileSizeBytes: Int64 = 0

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    @discardableResult
    func addURLs(_ urls: [URL]) -> Int {
        let importedAt = Date()
        return addItems(urls.map { MediaItem(url: $0, importedAt: importedAt) })
    }

    @discardableResult
    func addItems(_ newItems: [MediaItem]) -> Int {
        var seen = Set(items.map(\.url))
        let uniqueItems = newItems.filter { seen.insert($0.url).inserted }
        guard !uniqueItems.isEmpty else { return 0 }
        totalFileSizeBytes += Self.fileSizeBytes(for: uniqueItems)
        items.append(contentsOf: uniqueItems)
        applySort(sortMode)
        selectedFileSizeBytes = fileSizeBytes(for: selection)
        return uniqueItems.count
    }

    @discardableResult
    func insertURLs(_ urls: [URL], at insertionIndex: Int) -> Int {
        let importedAt = Date()
        let newItems = urls.map { MediaItem(url: $0, importedAt: importedAt) }
        var seen = Set(items.map(\.url))
        let uniqueItems = newItems.filter { seen.insert($0.url).inserted }
        guard !uniqueItems.isEmpty else { return 0 }
        totalFileSizeBytes += Self.fileSizeBytes(for: uniqueItems)
        let boundedIndex = min(max(insertionIndex, 0), items.count)
        items.insert(contentsOf: uniqueItems, at: boundedIndex)
        sortMode = .manual
        selectedFileSizeBytes = fileSizeBytes(for: selection)
        return uniqueItems.count
    }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        let selectedIDs = selection
        let removedItems = items.filter { selectedIDs.contains($0.id) }
        totalFileSizeBytes -= Self.fileSizeBytes(for: removedItems)
        items.removeAll { selectedIDs.contains($0.id) }
        selection.removeAll()
    }

    func remove(_ item: MediaItem) {
        let removedItems = items.filter { $0.id == item.id }
        totalFileSizeBytes -= Self.fileSizeBytes(for: removedItems)
        items.removeAll { $0.id == item.id }
        selection.remove(item.id)
    }

    func updateMediaURL(for id: MediaItem.ID, to url: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].url != url else { return }

        let currentItem = items[index]
        items[index] = MediaItem(
            id: currentItem.id,
            url: url,
            importedAt: currentItem.importedAt,
            fileSize: currentItem.fileSize
        )
        totalFileSizeBytes = Self.fileSizeBytes(for: items)
        selectedFileSizeBytes = fileSizeBytes(for: selection)
        applySort(sortMode)
    }

    func clear() {
        totalFileSizeBytes = 0
        items.removeAll()
        selection.removeAll()
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    func applySort(_ mode: PlaylistSortMode) {
        sortMode = mode
        switch mode {
        case .manual:
            return
        case .nameAscending:
            items.sort { compareNames($0, $1, ascending: true) }
        case .nameDescending:
            items.sort { compareNames($0, $1, ascending: false) }
        case .createdOldestFirst:
            items.sort { compareDates($0.createdAt, $1.createdAt, fallbackA: $0.displayName, fallbackB: $1.displayName, ascending: true) }
        case .createdNewestFirst:
            items.sort { compareDates($0.createdAt, $1.createdAt, fallbackA: $0.displayName, fallbackB: $1.displayName, ascending: false) }
        case .modifiedOldestFirst:
            items.sort { compareDates($0.modifiedAt, $1.modifiedAt, fallbackA: $0.displayName, fallbackB: $1.displayName, ascending: true) }
        case .modifiedNewestFirst:
            items.sort { compareDates($0.modifiedAt, $1.modifiedAt, fallbackA: $0.displayName, fallbackB: $1.displayName, ascending: false) }
        case .fileType:
            items.sort {
                let left = $0.url.pathExtension.localizedLowercase
                let right = $1.url.pathExtension.localizedLowercase
                if left == right { return compareNames($0, $1, ascending: true) }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        }
    }

    func moveItems(containing draggedID: MediaItem.ID, to targetID: MediaItem.ID) {
        guard draggedID != targetID,
              let targetIndex = items.firstIndex(where: { $0.id == targetID }) else { return }

        let movingIDs = selection.contains(draggedID) ? selection : [draggedID]
        guard !movingIDs.contains(targetID) else { return }
        let movingItems = items.filter { movingIDs.contains($0.id) }
        guard !movingItems.isEmpty else { return }

        items.removeAll { movingIDs.contains($0.id) }
        let adjustedTargetIndex = items.firstIndex(where: { $0.id == targetID }) ?? min(targetIndex, items.count)
        items.insert(contentsOf: movingItems, at: adjustedTargetIndex)
        sortMode = .manual
    }

    func moveItems(containing draggedID: MediaItem.ID, toInsertionIndex proposedIndex: Int) {
        let movingIDs = selection.contains(draggedID) ? selection : [draggedID]
        let movingItems = items.filter { movingIDs.contains($0.id) }
        guard !movingItems.isEmpty else { return }

        let boundedIndex = min(max(proposedIndex, 0), items.count)
        let removedBeforeInsertion = items.prefix(boundedIndex).filter { movingIDs.contains($0.id) }.count
        let adjustedIndex = boundedIndex - removedBeforeInsertion

        items.removeAll { movingIDs.contains($0.id) }
        items.insert(contentsOf: movingItems, at: min(adjustedIndex, items.count))
        sortMode = .manual
    }

    private func compareNames(_ lhs: MediaItem, _ rhs: MediaItem, ascending: Bool) -> Bool {
        let result = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if result == .orderedSame {
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == (ascending ? .orderedAscending : .orderedDescending)
        }
        return result == (ascending ? .orderedAscending : .orderedDescending)
    }

    private func compareDates(
        _ lhs: Date?,
        _ rhs: Date?,
        fallbackA: String,
        fallbackB: String,
        ascending: Bool
    ) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return ascending ? left < right : left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            let result = fallbackA.localizedStandardCompare(fallbackB)
            return result == (ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private func fileSizeBytes(for ids: Set<MediaItem.ID>) -> Int64 {
        items.reduce(Int64(0)) { total, item in
            guard ids.contains(item.id) else { return total }
            return total + Self.fileSizeBytes(for: item)
        }
    }

    private static func fileSizeBytes(for items: [MediaItem]) -> Int64 {
        items.reduce(Int64(0)) { total, item in
            total + fileSizeBytes(for: item)
        }
    }

    private static func fileSizeBytes(for item: MediaItem) -> Int64 {
        max(item.fileSize ?? 0, 0)
    }
}
