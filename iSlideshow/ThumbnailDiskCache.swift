import AppKit
import CryptoKit

final class ThumbnailDiskCache: @unchecked Sendable {
    private let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let maxDiskBytes: Int
    private let trimTargetRatio = 0.9
    private var currentDiskBytes = 0

    convenience init?() {
        guard let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        self.init(
            directory: cachesDirectory.appendingPathComponent("iSlideshow/Thumbnails", isDirectory: true),
            maxDiskBytes: 256 * 1024 * 1024
        )
    }

    init(directory: URL, maxDiskBytes: Int) {
        self.directory = directory
        self.maxDiskBytes = max(1, maxDiskBytes)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        currentDiskBytes = cacheFiles().totalBytes
        trimIfNeeded()
    }

    func image(for url: URL) -> NSImage? {
        let fileURL = cacheFileURL(for: url)
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return NSImage(contentsOf: fileURL)
    }

    func store(_ image: NSImage, for url: URL) {
        let fileURL = cacheFileURL(for: url)
        guard !fileManager.fileExists(atPath: fileURL.path),
              let data = image.thumbnailPNGData else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }
        try? data.write(to: fileURL, options: .atomic)
        currentDiskBytes += data.count
        if currentDiskBytes > maxDiskBytes {
            trimIfNeeded()
        }
    }

    private func cacheFileURL(for url: URL) -> URL {
        let key = ThumbnailCacheKey(url: url).filename
        return directory.appendingPathComponent(key).appendingPathExtension("png")
    }

    private func trimIfNeeded() {
        guard currentDiskBytes > maxDiskBytes else { return }
        let snapshot = cacheFiles()
        currentDiskBytes = snapshot.totalBytes
        guard currentDiskBytes > maxDiskBytes else { return }

        let targetBytes = Int(Double(maxDiskBytes) * trimTargetRatio)
        for file in snapshot.files.sorted(by: { $0.modified < $1.modified }) {
            try? fileManager.removeItem(at: file.url)
            currentDiskBytes -= file.size
            if currentDiskBytes <= targetBytes { break }
        }
    }

    private func cacheFiles() -> (files: [(url: URL, modified: Date, size: Int)], totalBytes: Int) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], 0) }

        var files: [(url: URL, modified: Date, size: Int)] = []
        var totalBytes = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            totalBytes += size
            files.append((fileURL, values?.contentModificationDate ?? .distantPast, size))
        }

        return (files, totalBytes)
    }
}

private struct ThumbnailCacheKey {
    let url: URL

    var filename: String {
        var metadataURL = url
        metadataURL.removeAllCachedResourceValues()
        let values = (try? metadataURL.resourceValues(forKeys: [
            .attributeModificationDateKey,
            .contentModificationDateKey,
            .fileSizeKey
        ])) ?? URLResourceValues()
        let attributeModified = values.attributeModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let fileSize = values.fileSize ?? 0
        let rawKey = "\(metadataURL.standardizedFileURL.path)-\(attributeModified.bitPattern)-\(modified.bitPattern)-\(fileSize)"
        let digest = SHA256.hash(data: Data(rawKey.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension NSImage {
    var cacheCost: Int {
        guard let representation = representations.first else { return 1 }
        let pixels = max(1, representation.pixelsWide * representation.pixelsHigh)
        return pixels * 4
    }

    var thumbnailPNGData: Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}
