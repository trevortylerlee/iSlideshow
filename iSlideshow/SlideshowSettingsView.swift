import SwiftUI

struct SlideshowSettingsView: View {
    @ObservedObject var playlist: Playlist
    @AppStorage("duration") private var storedDuration: Double = 5.0
    @AppStorage("isShuffled") private var isShuffled: Bool = true
    @AppStorage("isLooping") private var isLooping: Bool = false
    @AppStorage(DragExportOperation.storageKey) private var dragExportOperationRawValue: String = DragExportOperation.copy.rawValue
    @State private var showsHelp = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                settingsRow("Sort") {
                    Picker("Sort", selection: sortMode) {
                        ForEach(PlaylistSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .help("Sort imported files.")
                }

                Divider()

                settingsRow("Image Duration") {
                    HStack(spacing: 6) {
                        TextField("Seconds", value: duration, format: .number.precision(.fractionLength(0...1)))
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("Image duration")
                            .accessibilityValue("\(storedDuration) seconds")
                            .help("Set how long each image is shown, in seconds.")

                        Text("sec")
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                settingsRow("Shuffle") {
                    Toggle("Shuffle", isOn: $isShuffled)
                        .labelsHidden()
                        .help("Randomize slideshow order.")
                }

                Divider()

                settingsRow("Loop") {
                    Toggle("Loop", isOn: $isLooping)
                        .labelsHidden()
                        .help("Repeat slideshow when it reaches the end.")
                }

                Divider()

                settingsRow("Dragging Out") {
                    Picker("Dragging Out", selection: dragExportOperation) {
                        ForEach(DragExportOperation.allCases) { operation in
                            Text(operation.title).tag(operation)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .help("Choose what happens when files are dragged from iSlideshow to Finder or another folder.")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }

            HStack {
                Spacer()

                Button {
                    showsHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings Help")
                .help("Show settings help.")
                .popover(isPresented: $showsHelp, arrowEdge: .bottom) {
                    settingsHelp
                }
            }
            .padding(.top, 10)
        }
        .padding(18)
        .frame(width: 390)
    }

    private var sortMode: Binding<PlaylistSortMode> {
        Binding(
            get: { playlist.sortMode },
            set: { playlist.applySort($0) }
        )
    }

    private var duration: Binding<Double> {
        Binding(
            get: { SlideshowEngine.sanitizedDuration(storedDuration) },
            set: { storedDuration = SlideshowEngine.sanitizedDuration($0) }
        )
    }

    private var dragExportOperation: Binding<DragExportOperation> {
        Binding(
            get: { DragExportOperation(rawValue: dragExportOperationRawValue) ?? .copy },
            set: { dragExportOperationRawValue = $0.rawValue }
        )
    }

    private func settingsRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)

            content()
        }
        .frame(height: 42)
    }

    private var settingsHelp: some View {
        VStack(alignment: .leading, spacing: 12) {
            helpItem("Sort", "Controls the order of imported media. The selected sort is also applied to files you import later.")
            helpItem("Image Duration", "Sets how many seconds each image is shown before advancing. Videos play for their own duration.")
            helpItem("Shuffle", "Randomizes the slideshow order when playback starts.")
            helpItem("Loop", "Starts again from the beginning when the slideshow reaches the end.")
            helpItem("Dragging Out", "Controls whether dragging media from iSlideshow to Finder copies the files or moves them.")
        }
        .padding(16)
        .frame(width: 320)
    }

    private func helpItem(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
