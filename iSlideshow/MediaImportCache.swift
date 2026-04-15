import Foundation
import UniformTypeIdentifiers

enum MediaImportCache {
    private static let folderName = "ImportedMedia"

    static var directoryURL: URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directoryURL(baseURL: baseURL)
    }

    static func directoryURL(baseURL: URL) -> URL {
        return baseURL
            .appendingPathComponent("iSlideshow", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func ensureDirectoryExists() throws -> URL {
        let url = directoryURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func createImportBatchDirectory() throws -> URL {
        let rootURL = try ensureDirectoryExists()
        let batchURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: batchURL, withIntermediateDirectories: true)
        return batchURL
    }

    static func copyImportedFile(from sourceURL: URL, suggestedName: String?, contentType: UTType?) throws -> URL {
        let destinationDirectory = try ensureDirectoryExists()
        let destinationURL = uniqueDestinationURL(
            in: destinationDirectory,
            sourceURL: sourceURL,
            suggestedName: suggestedName,
            contentType: contentType
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    static func clear() throws {
        let url = directoryURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func clearStaleFilesOnLaunch() {
        clearIgnoringErrors()
    }

    static func clearIgnoringErrors() {
        try? clear()
    }

    private static func uniqueDestinationURL(
        in directory: URL,
        sourceURL: URL,
        suggestedName: String?,
        contentType: UTType?
    ) -> URL {
        let baseName = sanitizedBaseName(from: suggestedName, fallback: sourceURL.deletingPathExtension().lastPathComponent)
        let pathExtension = resolvedPathExtension(sourceURL: sourceURL, contentType: contentType)
        let initialName = pathExtension.isEmpty ? baseName : "\(baseName).\(pathExtension)"
        var candidate = directory.appendingPathComponent(initialName, isDirectory: false)

        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = pathExtension.isEmpty ? "\(baseName) \(index)" : "\(baseName) \(index).\(pathExtension)"
            candidate = directory.appendingPathComponent(name, isDirectory: false)
            index += 1
        }
        return candidate
    }

    private static func resolvedPathExtension(sourceURL: URL, contentType: UTType?) -> String {
        let existingExtension = sourceURL.pathExtension
        if !existingExtension.isEmpty {
            return existingExtension
        }
        return contentType?.preferredFilenameExtension ?? ""
    }

    private static func sanitizedBaseName(from suggestedName: String?, fallback: String) -> String {
        let rawName = suggestedName?.isEmpty == false ? suggestedName ?? fallback : fallback
        let withoutExtension = URL(fileURLWithPath: rawName).deletingPathExtension().lastPathComponent
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let sanitized = withoutExtension
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Imported Media" : sanitized
    }
}
