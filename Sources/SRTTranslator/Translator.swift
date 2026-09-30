import Foundation
import Translation

/// Everything a worker needs to translate one file; built on the main actor, used off it.
struct WorkInput: Sendable {
    var sourceURL: URL
    var fingerprint: String
    var targetKey: String
    var document: SubtitleDocument
    var prepared: [PreparedCue]
    var source: Locale.Language
    var target: Locale.Language
    var output: URL
    var options: OutputOptions
}

enum WorkError: LocalizedError {
    case unsupportedPair(String, String)
    case modelNotInstalled(String, String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedPair(s, t): "\(s) → \(t) 번역은 지원되지 않습니다."
        case let .modelNotInstalled(s, t): "\(s) → \(t) 언어 모델이 설치되지 않았습니다."
        }
    }
}

enum Worker {
    static let batchSize = 40

    /// Translates one file with the on-device Translation framework and writes the result.
    static func run(
        _ input: WorkInput,
        preparer: LanguagePreparer,
        phase: @escaping @Sendable (JobStatus) async -> Void,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> URL {
        let src = input.source, tgt = input.target
        let srcName = LanguageNames.name(for: src), tgtName = LanguageNames.name(for: tgt)

        let availability = LanguageAvailability()
        switch await availability.status(from: src, to: tgt) {
        case .unsupported:
            throw WorkError.unsupportedPair(srcName, tgtName)
        case .supported:
            await phase(.waitingForModel)
            try await preparer.ensureInstalled(source: src, target: tgt)
            guard await availability.status(from: src, to: tgt) == .installed else {
                throw WorkError.modelNotInstalled(srcName, tgtName)
            }
        case .installed:
            break
        @unknown default:
            break
        }
        try Task.checkCancellation()
        await phase(.translating)

        var requests: [TranslationSession.Request] = []
        for (ci, cue) in input.prepared.enumerated() {
            for (pi, part) in cue.parts.enumerated() {
                requests.append(.init(sourceText: part, clientIdentifier: "\(ci):\(pi)"))
            }
        }

        // Resume: sentences translated in an earlier, interrupted run are not sent again.
        var results = CheckpointStore.load(source: input.sourceURL, target: input.targetKey, fingerprint: input.fingerprint)
        let allIDs = Set(requests.compactMap(\.clientIdentifier))
        results = results.filter { allIDs.contains($0.key) }
        requests.removeAll { results[$0.clientIdentifier ?? ""] != nil }
        var done = results.count
        await progress(done)
        func saveCheckpoint() {
            CheckpointStore.save(source: input.sourceURL, target: input.targetKey,
                                 fingerprint: input.fingerprint, translations: results)
        }

        let session = TranslationSession(installedSource: src, target: tgt)
        do {
            try await withTaskCancellationHandler {
                var start = 0
                while start < requests.count {
                    try Task.checkCancellation()
                    let chunk = Array(requests[start..<min(start + batchSize, requests.count)])
                    start += chunk.count
                    do {
                        for try await response in session.translate(batch: chunk) {
                            if let id = response.clientIdentifier { results[id] = response.targetText }
                            done += 1
                            await progress(done)
                        }
                    } catch {
                        if Task.isCancelled { throw CancellationError() }
                        // A batch failed: retry the remaining sentences one by one, keeping the original on failure.
                        for request in chunk where results[request.clientIdentifier ?? ""] == nil {
                            try Task.checkCancellation()
                            if let r = try? await session.translate(request.sourceText), let id = request.clientIdentifier {
                                results[id] = r.targetText
                            }
                            done += 1
                            await progress(done)
                        }
                    }
                    saveCheckpoint()
                }
            } onCancel: {
                session.cancel()
            }
        } catch {
            saveCheckpoint() // keep partial work for the next run
            throw error
        }

        let rendered = zip(input.document.cues, input.prepared).enumerated().map { ci, pair -> RenderedCue in
            let (original, cue) = pair
            guard cue.translatable else {
                return RenderedCue(index: original.index, timing: original.timing, translated: original.lines, original: [])
            }
            let translated = cue.parts.indices.map { results["\(ci):\($0)"] ?? cue.parts[$0] }
            return RenderedCue(index: original.index, timing: original.timing,
                               translated: CueFormatter.render(cue, original: original, translated: translated),
                               original: CueFormatter.plainLines(original))
        }
        let text = SubtitleWriter.text(for: rendered, options: input.options, lineEnding: input.document.lineEnding,
                                       title: input.sourceURL.deletingPathExtension().lastPathComponent, language: tgt)
        try write(text, input: input)
        CheckpointStore.remove(source: input.sourceURL, target: input.targetKey)
        return input.output
    }

    private static func write(_ text: String, input: WorkInput) throws {
        // SMI players (PotPlayer etc.) detect UTF-8 reliably only with a BOM.
        let data = Data(((input.options.format == .smi ? "\u{FEFF}" : "") + text).utf8)
        guard input.options.naming == .replaceOriginal else {
            try data.write(to: input.output, options: .atomic)
            return
        }
        // Write to a temp file first so the original is only moved once the translation is safely on disk.
        let fm = FileManager.default
        let temp = input.output.deletingLastPathComponent()
            .appendingPathComponent(".\(input.output.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: .atomic)
        do {
            try fm.moveItem(at: input.sourceURL, to: OutputNaming.backupURL(for: input.sourceURL))
            if fm.fileExists(atPath: input.output.path) {
                _ = try fm.replaceItemAt(input.output, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: input.output)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}

/// Language models that are supported but not downloaded can only be fetched through a
/// SwiftUI-hosted session (`.translationTask`), which shows the system download prompt.
/// Requests are serialized so only one prompt is shown at a time.
@MainActor
final class LanguagePreparer: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?

    private struct Waiter {
        let source: Locale.Language
        let target: Locale.Language
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var current: Waiter?

    func ensureInstalled(source: Locale.Language, target: Locale.Language) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(source: source, target: target, continuation: continuation))
            startNext()
        }
    }

    func handle(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            finish(nil)
        } catch {
            finish(error)
        }
    }

    private func startNext() {
        guard current == nil, !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        current = next
        Task {
            // A pair downloaded for an earlier waiter needs no second prompt.
            if await LanguageAvailability().status(from: next.source, to: next.target) == .installed {
                finish(nil)
            } else {
                configuration = .init(source: next.source, target: next.target)
            }
        }
    }

    private func finish(_ error: Error?) {
        guard let waiter = current else { return }
        current = nil
        configuration = nil
        if let error { waiter.continuation.resume(throwing: error) } else { waiter.continuation.resume() }
        startNext()
    }
}
