import CryptoKit
import Foundation

enum AppStorage {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JamakTrans", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Per-file checkpoints

/// Sentences already translated for one (source file, target language) pair.
/// Written after every batch so an interrupted file resumes where it stopped.
struct Checkpoint: Codable {
    var sourcePath: String
    var target: String
    var fingerprint: String           // SHA-256 of the source file; a changed file invalidates the checkpoint
    var translations: [String: String] // clientIdentifier "cue:part" -> translated text
    var updated: Date
}

enum CheckpointStore {
    static let directory: URL = {
        let dir = AppStorage.directory.appendingPathComponent("Checkpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fileURL(source: URL, target: String) -> URL {
        // Plain `path`, not `standardizedFileURL`: the latter resolves /private/tmp differently
        // once the source has been renamed to .org, which would orphan the checkpoint.
        let key = AppStorage.sha256(Data((source.path + "|" + target).utf8))
        return directory.appendingPathComponent(key + ".json")
    }

    static func load(source: URL, target: String, fingerprint: String) -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL(source: source, target: target)),
              let cp = try? JSONDecoder().decode(Checkpoint.self, from: data),
              cp.fingerprint == fingerprint else { return [:] }
        return cp.translations
    }

    static func save(source: URL, target: String, fingerprint: String, translations: [String: String]) {
        guard !translations.isEmpty else { return }
        let cp = Checkpoint(sourcePath: source.path, target: target,
                            fingerprint: fingerprint, translations: translations, updated: Date())
        if let data = try? JSONEncoder().encode(cp) {
            try? data.write(to: fileURL(source: source, target: target), options: .atomic)
        }
    }

    static func remove(source: URL, target: String) {
        try? FileManager.default.removeItem(at: fileURL(source: source, target: target))
    }

    /// Drops checkpoints nobody resumed for a long time.
    static func prune(olderThan days: Double = 30) {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-days * 86_400)
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < limit { try? fm.removeItem(at: file) }
        }
    }
}

// MARK: - Queue snapshot (session restore, export/import)

struct QueueSnapshot: Codable {
    struct Entry: Codable {
        enum State: String, Codable { case pending, completed, skipped, failed, cancelled }
        var path: String
        var relativeDirectory: String
        var state: State
        var message: String?
        var outputPath: String?
    }

    var version = 1
    var savedAt = Date()
    var targetID: String
    var entries: [Entry]

    static let sessionURL = AppStorage.directory.appendingPathComponent("session.json")

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> QueueSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(QueueSnapshot.self, from: Data(contentsOf: url))
    }
}
