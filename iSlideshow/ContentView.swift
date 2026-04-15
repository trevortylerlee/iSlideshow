import SwiftUI

struct ContentView: View {
    @ObservedObject var playlist: Playlist
    @AppStorage("duration") private var duration: Double = 5.0
    @AppStorage("isShuffled") private var isShuffled: Bool = true
    @AppStorage("isLooping") private var isLooping: Bool = false

    @EnvironmentObject private var appState: AppState
    @State private var windowController: SlideshowWindowController?
    @State private var activeAlert: PlaybackAlert?

    var body: some View {
        ImportView(
            playlist: playlist,
            onBeginSlideshow: beginSlideshow
        )
        .alert(
            "Play Selected Files?",
            isPresented: isPresentedBinding(for: .selectionPrompt),
            presenting: selectionPrompt
        ) { prompt in
            Button("Play Selected Files") {
                continueSlideshow(with: selectedItems())
            }
            Button("Play All Files") {
                continueSlideshow(with: playlist.items)
            }
            Button("Cancel", role: .cancel) { }
        } message: { prompt in
            Text("You have \(prompt.itemCount) \(prompt.itemCount == 1 ? "item" : "items") selected. Choose whether to play just the selection or every imported item.")
        }
        .alert(
            "Unsupported Files Present",
            isPresented: isPresentedBinding(for: .unsupportedMedia),
            presenting: unsupportedMediaPrompt
        ) { prompt in
            Button("Remove Unsupported") {
                removeUnsupportedAndStart(prompt.items)
            }
            Button("Play Supported") {
                startSlideshow(with: prompt.playableItems)
            }
            Button("Cancel", role: .cancel) { }
        } message: { prompt in
            Text("There are \(prompt.unsupportedCount) unsupported \(prompt.unsupportedCount == 1 ? "file" : "files") in this slideshow. Unsupported files will not play.")
        }
        .alert(
            "No Playable Media",
            isPresented: isPresentedBinding(for: .noPlayableMedia),
            presenting: noPlayableMediaMessage
        ) { _ in
            Button("OK", role: .cancel) { }
        } message: { message in
            Text(message)
        }
    }

    private func beginSlideshow() {
        guard !playlist.items.isEmpty else { return }
        let selectedCount = selectedItems().count
        guard selectedCount > 0, selectedCount < playlist.items.count else {
            continueSlideshow(with: playlist.items)
            return
        }

        activeAlert = .selectionPrompt(SelectionPrompt(itemCount: selectedCount))
    }

    private func continueSlideshow(with mediaItems: [MediaItem]) {
        let playableItems = mediaItems.filter(\.isPlayable)
        guard !playableItems.isEmpty else {
            presentNextAlert(.noPlayableMedia(message: noPlayableMediaMessage(for: mediaItems)))
            return
        }

        let unsupportedCount = mediaItems.count - playableItems.count
        guard unsupportedCount == 0 else {
            presentNextAlert(.unsupportedMedia(UnsupportedMediaPrompt(items: mediaItems)))
            return
        }

        startSlideshow(with: playableItems)
    }

    private func startSlideshow(with playableItems: [MediaItem]) {
        guard !playableItems.isEmpty else { return }
        windowController?.close()

        let engine = SlideshowEngine()
        engine.configure(
            mediaItems: playableItems,
            duration: duration,
            isLooping: isLooping,
            shuffle: isShuffled
        )

        let controller = SlideshowWindowController(engine: engine, appState: appState, onClose: { [weak appState] in
            appState?.activeEngine = nil
        })
        controller.open()
        self.windowController = controller
        appState.activeEngine = engine
    }

    private func removeUnsupportedAndStart(_ mediaItems: [MediaItem]) {
        let unsupportedItems = mediaItems.filter { !$0.isPlayable }
        for item in unsupportedItems {
            playlist.remove(item)
        }

        let playableItems = mediaItems.filter(\.isPlayable)
        startSlideshow(with: playableItems)
    }

    private func selectedItems() -> [MediaItem] {
        playlist.items.filter { playlist.selection.contains($0.id) }
    }

    private func presentNextAlert(_ alert: PlaybackAlert) {
        activeAlert = nil
        DispatchQueue.main.async {
            activeAlert = alert
        }
    }

    private func noPlayableMediaMessage(for mediaItems: [MediaItem]) -> String {
        if mediaItems.count == playlist.items.count {
            "The imported files are not supported for slideshow playback."
        } else {
            "The selected files are not supported for slideshow playback."
        }
    }

    private var selectionPrompt: SelectionPrompt? {
        if case .selectionPrompt(let prompt) = activeAlert { return prompt }
        return nil
    }

    private var unsupportedMediaPrompt: UnsupportedMediaPrompt? {
        if case .unsupportedMedia(let prompt) = activeAlert { return prompt }
        return nil
    }

    private var noPlayableMediaMessage: String? {
        if case .noPlayableMedia(let message) = activeAlert { return message }
        return nil
    }

    private func isPresentedBinding(for kind: PlaybackAlert.Kind) -> Binding<Bool> {
        Binding(
            get: { activeAlert?.kind == kind },
            set: { newValue in
                if !newValue, activeAlert?.kind == kind {
                    activeAlert = nil
                }
            }
        )
    }
}

private enum PlaybackAlert: Identifiable {
    case selectionPrompt(SelectionPrompt)
    case unsupportedMedia(UnsupportedMediaPrompt)
    case noPlayableMedia(message: String)

    enum Kind {
        case selectionPrompt
        case unsupportedMedia
        case noPlayableMedia
    }

    var kind: Kind {
        switch self {
        case .selectionPrompt: .selectionPrompt
        case .unsupportedMedia: .unsupportedMedia
        case .noPlayableMedia: .noPlayableMedia
        }
    }

    var id: String {
        switch self {
        case .selectionPrompt(let prompt):
            prompt.id.uuidString
        case .unsupportedMedia(let prompt):
            prompt.id.uuidString
        case .noPlayableMedia:
            UUID().uuidString
        }
    }
}

private struct SelectionPrompt {
    let id = UUID()
    let itemCount: Int
}

private struct UnsupportedMediaPrompt {
    let id = UUID()
    let items: [MediaItem]

    var playableItems: [MediaItem] {
        items.filter(\.isPlayable)
    }

    var unsupportedCount: Int {
        items.count - playableItems.count
    }
}
