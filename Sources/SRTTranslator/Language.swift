import Foundation
import NaturalLanguage

struct LanguageOption: Identifiable, Hashable, Sendable {
    let id: String   // minimal identifier, e.g. "ko", "zh-TW"
    let name: String

    var language: Locale.Language { Locale.Language(identifier: id) }

    init(_ language: Locale.Language) {
        id = language.minimalIdentifier
        name = LanguageNames.name(for: language)
    }
}

enum LanguageNames {
    static func name(for language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)
            ?? language.minimalIdentifier
    }

    static func name(forCode code: String) -> String {
        name(for: Locale.Language(identifier: code))
    }
}

enum LanguageMatch {
    /// Same language; for Chinese the script (Simplified/Traditional) must match too.
    static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        guard let ca = a.languageCode, let cb = b.languageCode, ca == cb else { return false }
        if ca.identifier == "zh" { return script(a) == script(b) }
        return true
    }

    private static func script(_ l: Locale.Language) -> String? {
        Locale.Language(identifier: l.maximalIdentifier).script?.identifier
    }
}

/// Language statistics of a subtitle file.
struct LanguageProfile: Sendable {
    var dominant: String?            // NLLanguage raw value, e.g. "en", "ja", "zh-Hans"
    var segmentCounts: [String: Int] // per-sentence dominant language counts
    var segmentTotal: Int

    var dominantLanguage: Locale.Language? { dominant.map { Locale.Language(identifier: $0) } }

    func share(of target: Locale.Language) -> Double {
        guard segmentTotal > 0 else { return 0 }
        let hits = segmentCounts
            .filter { LanguageMatch.same(Locale.Language(identifier: $0.key), target) }
            .map(\.value)
            .reduce(0, +)
        return Double(hits) / Double(segmentTotal)
    }
}

enum LanguageDetector {
    static func profile(of segments: [String]) -> LanguageProfile {
        let recognizer = NLLanguageRecognizer()

        // Whole-file detection over a bounded sample spread across the file.
        let step = max(1, segments.count / 600)
        let sample = stride(from: 0, to: segments.count, by: step).map { segments[$0] }.joined(separator: "\n")
        recognizer.processString(sample)
        let dominant = recognizer.dominantLanguage.flatMap { $0 == .undetermined ? nil : $0.rawValue }

        // Per-sentence detection to catch files that already contain a translation (bilingual subs).
        var counts: [String: Int] = [:]
        var total = 0
        for s in segments where s.count >= 4 {
            recognizer.reset()
            recognizer.processString(s)
            guard let lang = recognizer.dominantLanguage, lang != .undetermined else { continue }
            counts[lang.rawValue, default: 0] += 1
            total += 1
        }
        return LanguageProfile(dominant: dominant, segmentCounts: counts, segmentTotal: total)
    }
}

enum OutputNaming {
    static func outputURL(for source: URL, target: Locale.Language, options: OutputOptions) -> URL {
        let ext = options.format.rawValue
        switch options.naming {
        case .replaceOriginal:
            // movie.srt -> movie.srt (SRT) / movie.smi (SMI); the original becomes movie.srt.org
            return source.deletingPathExtension().appendingPathExtension(ext)
        case .languageSuffix:
            return suffixedURL(for: source, target: target, ext: ext)
        }
    }

    /// Where the original goes in `.replaceOriginal` mode.
    static func backupURL(for source: URL) -> URL {
        source.appendingPathExtension("org")
    }

    /// movie.en.srt -> movie.ko.srt, movie.srt -> movie.ko.srt
    private static func suffixedURL(for source: URL, target: Locale.Language, ext: String) -> URL {
        let dir = source.deletingLastPathComponent()
        var base = source.deletingPathExtension().lastPathComponent
        var parts = base.components(separatedBy: ".")
        if parts.count > 1, let last = parts.last, looksLikeLanguageTag(last) {
            parts.removeLast()
            base = parts.joined(separator: ".")
        }
        let code = target.minimalIdentifier
        var url = dir.appendingPathComponent("\(base).\(code).\(ext)")
        if url.standardizedFileURL == source.standardizedFileURL {
            url = dir.appendingPathComponent("\(base).translated.\(code).\(ext)")
        }
        return url
    }

    private static func looksLikeLanguageTag(_ s: String) -> Bool {
        guard s.range(of: #"^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,4})?$"#, options: .regularExpression) != nil else { return false }
        let code = String(s.prefix { $0.isLetter }).lowercased()
        return Locale.current.localizedString(forLanguageCode: code) != nil
    }
}
