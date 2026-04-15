import SwiftUI
import AVKit

struct SlideshowView: View {
    @ObservedObject var engine: SlideshowEngine
    @EnvironmentObject private var appState: AppState

    @State private var showHUD = true
    @State private var hudTimer: Task<Void, Never>?
    @State private var isCursorHidden = false
    @State private var isMouseInsideWindow = false

    @State private var displayedImage: NSImage?
    @State private var previousImage: NSImage?
    @State private var crossfadePhase: CGFloat = 1.0
    @State private var fadeCleanupTask: Task<Void, Never>?
    @State private var useInstantCut = false
    @State private var showingVideoURL: URL?
    @State private var slideLoadTask: Task<Void, Never>?
    @State private var resizeTask: Task<Void, Never>?
    @State private var failedSlide: FailedSlide?
    @State private var failedSlideSkipTask: Task<Void, Never>?
    @State private var activePlayer: AVPlayer?
    @State private var imageMaxPixelSize = 4096

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Progress bar at top
            if showingVideoURL == nil && failedSlide == nil {
                SlideProgressBar(
                    startDate: engine.slideStartDate,
                    endDate: engine.slideEndDate
                )
                .ignoresSafeArea()
            } else if let player = activePlayer {
                VideoProgressBar(player: player)
                    .ignoresSafeArea()
            }

            if let failedSlide {
                FailedSlideView(
                    failedSlide: failedSlide,
                    canSkip: engine.totalCount > 1,
                    onSkip: {
                        useInstantCut = true
                        engine.next()
                    }
                )
            } else if let videoURL = showingVideoURL {
                // Video playback
                VideoPlayerView(
                    url: videoURL,
                    isPlaying: engine.isPlaying,
                    onFinished: { engine.next() },
                    onFailed: { reason in
                        if showingVideoURL == videoURL {
                            showFailedSlide(for: videoURL, reason: reason)
                        }
                    },
                    onPlayerReady: { player in
                        if showingVideoURL == videoURL {
                            activePlayer = player
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                // Crossfade: outgoing image fades out underneath
                if let previousImage {
                    Image(nsImage: previousImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(1.0 - crossfadePhase)
                }

                // Crossfade: incoming image fades in on top
                if let displayedImage {
                    Image(nsImage: displayedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(crossfadePhase)
                }
            }

            // HUD controls
            if showHUD {
                VStack {
                    HStack {
                        Spacer()
                        infoBar
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                    controlsBar
                        .padding(.bottom, 16)
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: showHUD)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(WindowPixelSizeReader { maxPixelSize in
            updateDisplayMaxPixelSize(maxPixelSize)
        })
        .onAppear {
            engine.updateDisplayMaxPixelSize(imageMaxPixelSize)
            loadCurrentSlide()
            engine.play()
            scheduleHUDHide()
            wireMenuActions()
        }
        .onDisappear {
            hudTimer?.cancel()
            showCursorIfNeeded()
            fadeCleanupTask?.cancel()
            slideLoadTask?.cancel()
            resizeTask?.cancel()
            failedSlideSkipTask?.cancel()
            clearDisplayedMedia()
            engine.stop()
            unwireMenuActions()
        }
        .onChange(of: engine.currentIndex) {
            transitionToCurrentSlide()
        }
        .onChange(of: engine.isPlaying) { _, isPlaying in
            guard let failedSlide else { return }
            if isPlaying {
                scheduleFailedSlideSkip(for: failedSlide.url)
            } else {
                failedSlideSkipTask?.cancel()
                failedSlideSkipTask = nil
            }
        }
        .onMouseActivity(
            onEnter: { revealHUDAndScheduleHide() },
            onMove: { revealHUDAndScheduleHide() },
            onExit: { hideHUDImmediately() }
        )
        .background(KeyEventHandlingView(
            onLeftArrow: { useInstantCut = true; engine.previous() },
            onRightArrow: { useInstantCut = true; engine.next() },
            onSpace: { engine.togglePlayPause() },
            onEscape: { engine.stop(); NSApp.keyWindow?.close() },
            onFullscreen: { toggleFullscreen() }
        ))
    }

    // MARK: - Slide Transitions

    private func imageFor(_ url: URL) -> NSImage? {
        engine.cachedImage(for: url, maxPixelSize: imageMaxPixelSize)
    }

    private func loadImageAsync(_ url: URL) async -> NSImage? {
        await engine.loadDisplayImage(for: url, maxPixelSize: imageMaxPixelSize)
    }

    private func updateDisplayMaxPixelSize(_ maxPixelSize: Int) {
        let bucketedMaxPixelSize = bucketedDisplayMaxPixelSize(maxPixelSize)
        guard bucketedMaxPixelSize > 0, bucketedMaxPixelSize != imageMaxPixelSize else { return }

        resizeTask?.cancel()
        resizeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            imageMaxPixelSize = bucketedMaxPixelSize
            engine.updateDisplayMaxPixelSize(bucketedMaxPixelSize)
            if showingVideoURL == nil {
                loadCurrentSlide()
            }
        }
    }

    private func bucketedDisplayMaxPixelSize(_ maxPixelSize: Int) -> Int {
        let bucketSize = 512
        return max(bucketSize, Int(ceil(Double(maxPixelSize) / Double(bucketSize))) * bucketSize)
    }

    private func loadCurrentSlide() {
        slideLoadTask?.cancel()
        guard let url = engine.currentMediaURL else { return }
        clearFailedSlide()
        guard validateMediaExists(url) else { return }
        if engine.currentMediaIsVideo {
            showingVideoURL = url
            displayedImage = nil
            previousImage = nil
        } else {
            showingVideoURL = nil
            activePlayer = nil
            if let img = imageFor(url) {
                displayedImage = img
                crossfadePhase = 1.0
            } else {
                slideLoadTask = Task {
                    if let img = await loadImageAsync(url) {
                        guard !Task.isCancelled, engine.currentMediaURL == url else { return }
                        displayedImage = img
                        crossfadePhase = 1.0
                    } else {
                        guard !Task.isCancelled, engine.currentMediaURL == url else { return }
                        showFailedSlide(for: url, reason: "This image could not be loaded.")
                    }
                }
            }
        }
    }

    private func transitionToCurrentSlide() {
        slideLoadTask?.cancel()
        guard let url = engine.currentMediaURL else { return }
        let shouldCut = useInstantCut
        useInstantCut = false
        clearFailedSlide()
        guard validateMediaExists(url) else { return }
        if engine.currentMediaIsVideo {
            fadeCleanupTask?.cancel()
            showingVideoURL = url
            displayedImage = nil
            previousImage = nil
        } else {
            showingVideoURL = nil
            activePlayer = nil
            if shouldCut {
                cutTo(url)
            } else {
                crossfadeTo(url)
            }
        }
    }

    private func clearDisplayedMedia() {
        activePlayer?.pause()
        activePlayer?.replaceCurrentItem(with: nil)
        activePlayer = nil
        showingVideoURL = nil
        displayedImage = nil
        previousImage = nil
        clearFailedSlide()
    }

    private func cutTo(_ url: URL) {
        fadeCleanupTask?.cancel()
        previousImage = nil
        if let img = imageFor(url) {
            displayedImage = img
            crossfadePhase = 1.0
        } else {
            slideLoadTask = Task {
                if let img = await loadImageAsync(url) {
                    guard !Task.isCancelled, engine.currentMediaURL == url else { return }
                    displayedImage = img
                    crossfadePhase = 1.0
                } else {
                    guard !Task.isCancelled, engine.currentMediaURL == url else { return }
                    showFailedSlide(for: url, reason: "This image could not be loaded.")
                }
            }
        }
    }

    private func crossfadeTo(_ url: URL) {
        fadeCleanupTask?.cancel()
        if let newImage = imageFor(url) {
            applyCrossfade(newImage)
        } else {
            slideLoadTask = Task {
                if let newImage = await loadImageAsync(url) {
                    guard !Task.isCancelled, engine.currentMediaURL == url else { return }
                    applyCrossfade(newImage)
                } else {
                    guard !Task.isCancelled, engine.currentMediaURL == url else { return }
                    showFailedSlide(for: url, reason: "This image could not be loaded.")
                }
            }
        }
    }

    private func applyCrossfade(_ newImage: NSImage) {
        previousImage = displayedImage
        displayedImage = newImage
        crossfadePhase = 0.0
        withAnimation(.easeInOut(duration: 0.5)) {
            crossfadePhase = 1.0
        }
        fadeCleanupTask = Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            previousImage = nil
        }
    }

    private func validateMediaExists(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            showFailedSlide(for: url, reason: "The file is missing or no longer reachable.")
            return false
        }
        return true
    }

    private func showFailedSlide(for url: URL, reason: String) {
        showingVideoURL = nil
        activePlayer = nil
        displayedImage = nil
        previousImage = nil
        failedSlide = FailedSlide(url: url, reason: reason)
        scheduleFailedSlideSkip(for: url)
    }

    private func clearFailedSlide() {
        failedSlideSkipTask?.cancel()
        failedSlideSkipTask = nil
        failedSlide = nil
    }

    private func scheduleFailedSlideSkip(for url: URL) {
        failedSlideSkipTask?.cancel()
        guard engine.isPlaying, engine.totalCount > 1 else { return }
        failedSlideSkipTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, engine.currentMediaURL == url else { return }
            useInstantCut = true
            engine.next()
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 16) {
            Button { engine.previous(); scheduleHUDHide() } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)

            Button { engine.togglePlayPause(); scheduleHUDHide() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)

            Button { engine.next(); scheduleHUDHide() } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.8), in: Capsule())
    }

    private var infoBar: some View {
        HStack(spacing: 8) {
            if let item = engine.currentMediaItem {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("\(engine.currentIndex + 1) / \(engine.totalCount)")
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundColor(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.8), in: Capsule())
    }

    // MARK: - HUD Timing

    private func revealHUDAndScheduleHide() {
        isMouseInsideWindow = true
        showCursorIfNeeded()
        scheduleHUDHide()
    }

    private func scheduleHUDHide() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showHUD = true
        }
        hudTimer?.cancel()
        hudTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.3)) {
                    showHUD = false
                }
                if isMouseInsideWindow {
                    hideCursorIfNeeded()
                }
            }
        }
    }

    private func hideHUDImmediately() {
        isMouseInsideWindow = false
        hudTimer?.cancel()
        showCursorIfNeeded()
        withAnimation(.easeInOut(duration: 0.2)) {
            showHUD = false
        }
    }

    private func hideCursorIfNeeded() {
        guard !isCursorHidden else { return }
        NSCursor.hide()
        isCursorHidden = true
    }

    private func showCursorIfNeeded() {
        guard isCursorHidden else { return }
        NSCursor.unhide()
        isCursorHidden = false
    }

    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: - Menu Wiring

    private func wireMenuActions() {
        appState.nextSlide = {
            useInstantCut = true
            engine.next()
        }
        appState.previousSlide = {
            useInstantCut = true
            engine.previous()
        }
        appState.togglePlayPause = {
            engine.togglePlayPause()
        }
    }

    private func unwireMenuActions() {
        appState.nextSlide = nil
        appState.previousSlide = nil
        appState.togglePlayPause = nil
    }
}

private struct FailedSlide: Equatable {
    let url: URL
    let reason: String
}

private struct FailedSlideView: View {
    let failedSlide: FailedSlide
    let canSkip: Bool
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white.opacity(0.72))

            Text("Unable to Display Media")
                .font(.headline)
                .foregroundStyle(.white)

            Text(failedSlide.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420)

            Text(failedSlide.reason)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if canSkip {
                Button("Skip") {
                    onSkip()
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, 4)
            }
        }
        .padding(24)
    }
}

// MARK: - Progress Bar

struct SlideProgressBar: View {
    let startDate: Date?
    let endDate: Date?
    @State private var progress: Double = 0

    var body: some View {
        if startDate != nil, endDate != nil {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: geo.size.width, height: 3)
                        .scaleEffect(x: progress, y: 1, anchor: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }
            }
            .onAppear { restartAnimation() }
            .onChange(of: startDate) { restartAnimation() }
            .onChange(of: endDate) { restartAnimation() }
        }
    }

    private func restartAnimation() {
        let now = Date()
        let initialProgress = progress(at: now)
        let remainingDuration = max(endDate?.timeIntervalSince(now) ?? 0, 0)

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            progress = initialProgress
        }

        guard remainingDuration > 0 else {
            progress = initialProgress
            return
        }

        withAnimation(.linear(duration: remainingDuration)) {
            progress = 1
        }
    }

    private func progress(at now: Date) -> Double {
        guard let start = startDate, let end = endDate else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        return min(max(elapsed / total, 0), 1)
    }
}

// MARK: - Video Progress Bar (driven by AVPlayer periodic time observer)

struct VideoProgressBar: View {
    let player: AVPlayer
    @State private var progress: Double = 0
    @State private var observation: (player: AVPlayer, token: Any)?

    private let observerIntervalSeconds = 0.25
    private let jumpThreshold = 0.15

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: geo.size.width * progress, height: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
        }
        .onAppear { attachObserver(to: player) }
        .onDisappear { detachObserver() }
        .onChange(of: player) { _, newPlayer in
            detachObserver()
            setProgress(0, animated: false)
            attachObserver(to: newPlayer)
        }
    }

    private func attachObserver(to player: AVPlayer) {
        let interval = CMTime(seconds: observerIntervalSeconds, preferredTimescale: 600)
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard let item = player.currentItem else { return }
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else {
                setProgress(0, animated: false)
                return
            }

            let nextProgress = min(max(time.seconds / duration, 0), 1)
            setProgress(
                nextProgress,
                animated: shouldAnimateProgressChange(
                    to: nextProgress,
                    duration: duration,
                    player: player
                )
            )
        }
        observation = (player, token)
    }

    private func detachObserver() {
        if let observation {
            observation.player.removeTimeObserver(observation.token)
        }
        observation = nil
    }

    private func shouldAnimateProgressChange(to nextProgress: Double, duration: Double, player: AVPlayer) -> Bool {
        guard player.rate > 0 else { return false }
        guard nextProgress > progress else { return false }

        let delta = nextProgress - progress
        let expectedDelta = observerIntervalSeconds / duration
        let maxNormalDelta = max(jumpThreshold, expectedDelta * 3)
        return delta <= maxNormalDelta
    }

    private func setProgress(_ nextProgress: Double, animated: Bool) {
        let clampedProgress = min(max(nextProgress, 0), 1)
        guard animated else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                progress = clampedProgress
            }
            return
        }

        withAnimation(.linear(duration: observerIntervalSeconds)) {
            progress = clampedProgress
        }
    }
}

// MARK: - Mouse Activity Tracking

struct MouseActivityModifier: ViewModifier {
    let onEnter: () -> Void
    let onMove: () -> Void
    let onExit: () -> Void

    func body(content: Content) -> some View {
        content.background(MouseActivityTracker(onEnter: onEnter, onMove: onMove, onExit: onExit))
    }
}

extension View {
    func onMouseActivity(
        onEnter: @escaping () -> Void,
        onMove: @escaping () -> Void,
        onExit: @escaping () -> Void
    ) -> some View {
        modifier(MouseActivityModifier(onEnter: onEnter, onMove: onMove, onExit: onExit))
    }
}

struct MouseActivityTracker: NSViewRepresentable {
    let onEnter: () -> Void
    let onMove: () -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onEnter = onEnter
        view.onMove = onMove
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onEnter = onEnter
        nsView.onMove = onMove
        nsView.onExit = onExit
        nsView.syncMouseInsideState()
    }

    class TrackingView: NSView {
        var onEnter: (() -> Void)?
        var onMove: (() -> Void)?
        var onExit: (() -> Void)?
        private var trackingArea: NSTrackingArea?
        private var isMouseInside = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
            syncMouseInsideState()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncMouseInsideState()
        }

        func syncMouseInsideState() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window else { return }
                let location = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                updateInsideState(bounds.contains(location))
            }
        }

        override func mouseEntered(with event: NSEvent) {
            updateInsideState(true)
        }

        override func mouseMoved(with event: NSEvent) {
            updateInsideState(true, notifyEnter: false)
            onMove?()
        }

        override func mouseExited(with event: NSEvent) {
            updateInsideState(false)
        }

        private func updateInsideState(_ newValue: Bool, notifyEnter: Bool = true) {
            guard isMouseInside != newValue else { return }
            isMouseInside = newValue
            if newValue {
                if notifyEnter { onEnter?() }
            } else {
                onExit?()
            }
        }
    }
}

// MARK: - Window Pixel Size Tracking

struct WindowPixelSizeReader: NSViewRepresentable {
    let onChange: (Int) -> Void

    func makeNSView(context: Context) -> PixelSizeView {
        let view = PixelSizeView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: PixelSizeView, context: Context) {
        nsView.onChange = onChange
        nsView.reportPixelSizeIfNeeded()
    }

    final class PixelSizeView: NSView {
        var onChange: ((Int) -> Void)?
        private var lastMaxPixelSize: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportPixelSizeIfNeeded()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportPixelSizeIfNeeded()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            reportPixelSizeIfNeeded()
        }

        func reportPixelSizeIfNeeded() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
                let maxPixelSize = max(1, Int(ceil(max(bounds.width, bounds.height) * scale)))
                guard maxPixelSize != lastMaxPixelSize else { return }
                lastMaxPixelSize = maxPixelSize
                onChange?(maxPixelSize)
            }
        }
    }
}

// MARK: - Keyboard Event Handling

struct KeyEventHandlingView: NSViewRepresentable {
    var onLeftArrow: () -> Void
    var onRightArrow: () -> Void
    var onSpace: () -> Void
    var onEscape: () -> Void
    var onFullscreen: () -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onLeftArrow = onLeftArrow
        view.onRightArrow = onRightArrow
        view.onSpace = onSpace
        view.onEscape = onEscape
        view.onFullscreen = onFullscreen
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onLeftArrow = onLeftArrow
        nsView.onRightArrow = onRightArrow
        nsView.onSpace = onSpace
        nsView.onEscape = onEscape
        nsView.onFullscreen = onFullscreen
    }

    class KeyView: NSView {
        var onLeftArrow: (() -> Void)?
        var onRightArrow: (() -> Void)?
        var onSpace: (() -> Void)?
        var onEscape: (() -> Void)?
        var onFullscreen: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: onLeftArrow?()
            case 124: onRightArrow?()
            case 49: onSpace?()
            case 53: onEscape?()
            default:
                if let chars = event.charactersIgnoringModifiers?.lowercased(), chars == "f" {
                    onFullscreen?()
                } else {
                    super.keyDown(with: event)
                }
            }
        }
    }
}
