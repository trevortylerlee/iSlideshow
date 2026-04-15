import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var canBeginSlideshow: Bool = false
    @Published private(set) var activeEngineIsPlaying: Bool = false
    @Published var activeEngine: SlideshowEngine? {
        didSet {
            engineSubscription?.cancel()
            activeEngineIsPlaying = activeEngine?.isPlaying == true
            engineSubscription = activeEngine?.$isPlaying.sink { [weak self] isPlaying in
                self?.activeEngineIsPlaying = isPlaying
            }
        }
    }

    // Wired by the importer/slideshow views so menu commands can drive them.
    var openImporter: (() -> Void)?
    var beginSlideshow: (() -> Void)?
    var nextSlide: (() -> Void)?
    var previousSlide: (() -> Void)?
    var togglePlayPause: (() -> Void)?

    private var engineSubscription: AnyCancellable?
}
