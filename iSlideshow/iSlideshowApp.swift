import SwiftUI

@main
struct iSlideshowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var playlist = Playlist()

    var body: some Scene {
        WindowGroup {
            ContentView(playlist: playlist)
                .navigationTitle("iSlideshow")
                .environmentObject(appState)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 800, height: 600)
        .commands {
            AppMenuCommands(appState: appState)
        }

        Settings {
            SlideshowSettingsView(playlist: playlist)
        }
    }
}

struct AppMenuCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                appState.openImporter?()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Start Slideshow") {
                appState.beginSlideshow?()
            }
            .keyboardShortcut(.return, modifiers: [])
            .disabled(!appState.canBeginSlideshow || appState.activeEngine != nil)
        }

        CommandMenu("Slideshow") {
            Button(appState.activeEngineIsPlaying ? "Pause" : "Play") {
                appState.togglePlayPause?()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(appState.activeEngine == nil)

            Button("Next") {
                appState.nextSlide?()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(appState.activeEngine == nil)

            Button("Previous") {
                appState.previousSlide?()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(appState.activeEngine == nil)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MediaImportCache.clearStaleFilesOnLaunch()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaImportCache.clearIgnoringErrors()
    }
}
