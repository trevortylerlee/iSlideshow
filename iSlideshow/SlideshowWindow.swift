import SwiftUI

@MainActor
final class SlideshowWindowController {
    private var window: NSWindow?
    private let engine: SlideshowEngine
    private let appState: AppState
    private var closeObserver: NSObjectProtocol?
    private let onClose: (() -> Void)?

    init(engine: SlideshowEngine, appState: AppState, onClose: (() -> Void)? = nil) {
        self.engine = engine
        self.appState = appState
        self.onClose = onClose
    }

    func open() {
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(
            rootView: SlideshowView(engine: engine).environmentObject(appState)
        )

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentView = hostingView
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = .black
        win.center()
        win.isReleasedWhenClosed = false
        win.setFrameAutosaveName("SlideshowWindow")

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.closeObserver = nil
                }
                self.engine.stop()
                self.window = nil
                self.onClose?()
            }
        }

        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    func close() {
        if let observer = closeObserver {
            NotificationCenter.default.removeObserver(observer)
            closeObserver = nil
        }
        engine.stop()
        window?.close()
        window = nil
        onClose?()
    }
}
