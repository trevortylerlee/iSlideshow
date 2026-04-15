import SwiftUI

struct ThumbnailCell: View {
    let item: MediaItem
    let isSelected: Bool
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else if !item.isPlayable {
                    unsupportedPlaceholder
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                }
            }
            .frame(width: 120, height: 90)
            .background(isSelected ? Color.gray.opacity(0.3) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                if item.isVideo && item.isPlayable {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(4)
                        .background(.black.opacity(0.6), in: Circle())
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !item.isPlayable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(4)
                        .background(.black.opacity(0.68), in: Circle())
                        .padding(4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text(item.displayName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 130)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .padding(6)
        .contentShape(Rectangle())
        .help(item.isPlayable ? item.displayName : "\(item.displayName) is not supported for slideshow playback")
        .task(id: item.id) {
            thumbnail = nil
            guard item.isPlayable else { return }
            if item.isVideo {
                try? await Task.sleep(nanoseconds: 250_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            guard !Task.isCancelled else { return }

            let loadedThumbnail = await ThumbnailPipeline.shared.thumbnail(for: item.url)
            guard !Task.isCancelled else { return }
            thumbnail = loadedThumbnail
        }
        .onDisappear {
            thumbnail = nil
        }
    }

    private var unsupportedPlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.16))
            VStack(spacing: 4) {
                Image(systemName: "questionmark")
                    .font(.system(size: 26, weight: .medium))
                Text("Unsupported")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
        }
    }
}
