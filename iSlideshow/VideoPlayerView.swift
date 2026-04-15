import SwiftUI
import AVKit

struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    var isPlaying: Bool
    var onFinished: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onPlayerReady: ((AVPlayer?) -> Void)?

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        let player = AVPlayer(url: url)
        playerView.player = player
        context.coordinator.observe(player: player)

        // Observe when video finishes
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.playerFailedToPlayToEnd),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem
        )

        if isPlaying { player.play() }
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.onPlayerReady?(player)
        }
        return playerView
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.onFinished = onFinished
        context.coordinator.onFailed = onFailed
        context.coordinator.onPlayerReady = onPlayerReady
        // Only replace player if the URL actually changed
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL == url {
            // Same video — just sync play/pause state
            if isPlaying {
                if let player = nsView.player, player.isAtEnd {
                    player.seek(to: .zero)
                }
                nsView.player?.play()
            } else {
                nsView.player?.pause()
            }
            return
        }

        // Clean up old player + observer
        if let oldPlayer = nsView.player {
            oldPlayer.pause()
            if let oldItem = oldPlayer.currentItem {
                NotificationCenter.default.removeObserver(context.coordinator, name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
                NotificationCenter.default.removeObserver(context.coordinator, name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
            }
            oldPlayer.replaceCurrentItem(with: nil)
        }

        let player = AVPlayer(url: url)
        nsView.player = player
        context.coordinator.observe(player: player)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.playerFailedToPlayToEnd),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem
        )

        if isPlaying { player.play() }
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            coordinator?.onPlayerReady?(player)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        nsView.player?.pause()
        nsView.player?.replaceCurrentItem(with: nil)
        nsView.player = nil
        coordinator.onFinished = nil
        coordinator.onFailed = nil
        coordinator.onPlayerReady?(nil)
        coordinator.onPlayerReady = nil
        coordinator.invalidate()
        NotificationCenter.default.removeObserver(coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinished: onFinished, onFailed: onFailed, onPlayerReady: onPlayerReady)
    }

    class Coordinator: NSObject {
        var onFinished: (() -> Void)?
        var onFailed: ((String) -> Void)?
        var onPlayerReady: ((AVPlayer?) -> Void)?
        private var statusObservation: NSKeyValueObservation?

        init(onFinished: (() -> Void)?, onFailed: ((String) -> Void)?, onPlayerReady: ((AVPlayer?) -> Void)?) {
            self.onFinished = onFinished
            self.onFailed = onFailed
            self.onPlayerReady = onPlayerReady
        }

        func observe(player: AVPlayer) {
            statusObservation?.invalidate()
            statusObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                DispatchQueue.main.async {
                    self?.onFailed?(item.error?.localizedDescription ?? "This video could not be played.")
                }
            }
        }

        func invalidate() {
            statusObservation?.invalidate()
            statusObservation = nil
        }

        @objc func playerDidFinish(_ notification: Notification) {
            onFinished?()
        }

        @objc func playerFailedToPlayToEnd(_ notification: Notification) {
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            onFailed?(error?.localizedDescription ?? "This video could not be played.")
        }
    }
}

private extension AVPlayer {
    var isAtEnd: Bool {
        guard let item = currentItem else { return false }
        let duration = item.duration.seconds
        let currentTime = currentTime().seconds
        guard duration.isFinite, duration > 0, currentTime.isFinite else { return false }
        return currentTime >= duration - 0.05
    }
}
