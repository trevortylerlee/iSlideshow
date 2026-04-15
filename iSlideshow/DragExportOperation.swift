import AppKit

enum DragExportOperation: String, CaseIterable, Identifiable {
    case copy
    case move

    static let storageKey = "dragExportOperation"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: "Copy"
        case .move: "Move"
        }
    }

    var dragOperation: NSDragOperation {
        switch self {
        case .copy: .copy
        case .move: .move
        }
    }
}
