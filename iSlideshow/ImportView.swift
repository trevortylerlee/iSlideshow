import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImportView: View {
    @ObservedObject var playlist: Playlist
    var onBeginSlideshow: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var errorMessage: String?
    @State private var isDropZoneHovered = false
    @State private var importTask: Task<Void, Never>?
    @State private var importID = UUID()
    @State private var isImporting = false
    @State private var dropIconBounce = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if playlist.isEmpty {
                    emptyState
                } else {
                    populatedState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
        }
        .overlay(alignment: .bottomTrailing) {
            if !playlist.isEmpty {
                floatingSlideshowControls
                    .padding(.trailing, 24)
                    .padding(.bottom, 48)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .background(MainWindowMaterialBackground().ignoresSafeArea())
        .onDrop(of: MediaDropDelegate.acceptedContentTypes, delegate: MediaDropDelegate { urls in
            addMedia(urls)
        } onEntered: {
            isDropZoneHovered = true
        } onExited: {
            isDropZoneHovered = false
        })
        .onAppear { wireAppState() }
        .onDisappear {
            importTask?.cancel()
        }
        .onChange(of: playlist.count) { _, newCount in
            appState.canBeginSlideshow = newCount > 0
            if newCount == 0 {
                Task {
                    await ThumbnailPipeline.shared.removeAll()
                }
            }
        }
    }

    private func wireAppState() {
        appState.openImporter = { openFilePanel() }
        appState.beginSlideshow = { onBeginSlideshow() }
        appState.canBeginSlideshow = !playlist.isEmpty
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            VStack(spacing: 8) {
                Spacer()
                dropZone
                Spacer()
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .transition(.opacity)
                }
                if isImporting {
                    importStatus
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isDropZoneHovered = $0 }
        .onTapGesture {
            animateDropIcon()
            openFilePanel()
        }
    }

    private var dropZone: some View {
        let size: CGFloat = 180

        return ZStack {
            Image(systemName: "plus")
                .font(.system(size: 76, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.secondary.opacity(isDropZoneHovered ? 0.62 : 0.42))
                .symbolEffect(.bounce, value: dropIconBounce)
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.15), value: isDropZoneHovered)
    }

    // MARK: - Populated State

    private var populatedState: some View {
        ZStack {
            ThumbnailGrid(playlist: playlist)
        }
        .overlay(alignment: .bottom) {
            if isImporting {
                importStatus
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Button {
                animateDropIcon()
                openFilePanel()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 18)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Add media")
            .accessibilityHint("Opens the file picker.")
            .help("Add images, videos, or a folder")

            Text(statusBarText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Text(statusBarStatsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var statusBarText: String {
        "Drag and drop files onto the area above"
    }

    private var statusBarStatsText: String {
        if !playlist.selection.isEmpty {
            return "\(fileCountText(playlist.selection.count)) selected, \(fileSizeText(forByteCount: playlist.selectedFileSizeBytes))"
        }

        guard !playlist.items.isEmpty else {
            return "0 files"
        }

        return "\(fileCountText(playlist.count)), \(fileSizeText(forByteCount: playlist.totalFileSizeBytes))"
    }

    private func fileCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "file" : "files")"
    }

    private func animateDropIcon() {
        dropIconBounce += 1
    }

    private func fileSizeText(forByteCount byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: byteCount)
    }

    private var importStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.65)
            Text(importStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    private var importStatusText: String {
        "Scanning media..."
    }

    private var floatingSlideshowControls: some View {
        HStack(spacing: 6) {
            Button {
                clearMedia()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .accessibilityLabel("Clear all media")
            .accessibilityHint("Removes all imported images and videos.")
            .help("Remove all imported media")

            Button(action: onBeginSlideshow) {
                Label("Play", systemImage: "play.fill")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(playlist.isEmpty || isImporting)
            .accessibilityLabel("Play slideshow")
            .accessibilityHint("Starts the slideshow.")
            .help("Start slideshow")
        }
    }

    // MARK: - Actions

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = URL.supportedMediaTypes
        panel.treatsFilePackagesAsDirectories = false

        guard panel.runModal() == .OK else { return }
        beginImport(from: panel.urls)
    }

    private func beginImport(from selectedURLs: [URL]) {
        importTask?.cancel()
        let currentImportID = UUID()
        importID = currentImportID
        isImporting = true
        importTask = Task {
            let result = await MediaImporter.collectCancellable(from: selectedURLs)

            guard importID == currentImportID else { return }
            guard !Task.isCancelled else { return }

            let addedCount = playlist.addURLs(result.urls)
            isImporting = false
            showImportSummary(result: result, addedCount: addedCount)
        }
    }

    private func showImportSummary(result: MediaImportResult, addedCount: Int) {
        let skippedFiles = result.skippedFileCount
        let emptyFolders = result.emptyFolderCount
        guard skippedFiles > 0 || emptyFolders > 0 || addedCount == 0 else { return }

        let message: String
        if addedCount == 0 {
            message = skippedFiles > 0
                ? "No recognized media found. Skipped \(skippedFiles) unrecognized file\(skippedFiles == 1 ? "" : "s")."
                : "No recognized media found in folder"
        } else if skippedFiles > 0 {
            message = "Skipped \(skippedFiles) unrecognized file\(skippedFiles == 1 ? "" : "s")."
        } else {
            message = "Skipped \(emptyFolders) empty folder\(emptyFolders == 1 ? "" : "s")."
        }

        withAnimation { errorMessage = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { errorMessage = nil }
        }
    }

    private func addMedia(_ newURLs: [URL]) {
        updateMediaWithOptionalAnimation(animated: newURLs.count < 250) {
            playlist.addURLs(newURLs)
            errorMessage = nil
        }
    }

    private func clearMedia() {
        MediaImportCache.clearIgnoringErrors()
        let shouldAnimate = playlist.count < 250
        updateMediaWithOptionalAnimation(animated: shouldAnimate) {
            playlist.clear()
        }
        Task {
            await ThumbnailPipeline.shared.removeAll()
        }
    }

    private func updateMediaWithOptionalAnimation(animated: Bool, _ update: () -> Void) {
        if animated {
            withAnimation {
                update()
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                update()
            }
        }
    }
}

private struct MainWindowMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = WindowMaterialView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .underWindowBackground
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }

    private final class WindowMaterialView: NSVisualEffectView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.titlebarAppearsTransparent = true
        }
    }
}
