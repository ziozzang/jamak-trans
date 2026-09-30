import Foundation

// MARK: - SRT document

struct SubtitleCue: Sendable {
    var index: String
    var timing: String
    var lines: [String]
}

struct SubtitleDocument: Sendable {
    var cues: [SubtitleCue]
    var lineEnding: String

    static func load(url: URL) throws -> SubtitleDocument {
        let data = try Data(contentsOf: url)
        return parse(try TextDecoding.decode(data))
    }

    static func parse(_ raw: String) -> SubtitleDocument {
        let lineEnding = raw.contains("\r\n") ? "\r\n" : "\n"
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        func trimmed(_ i: Int) -> String { lines[i].trimmingCharacters(in: .whitespaces) }
        func isTiming(_ i: Int) -> Bool { i < lines.count && lines[i].contains("-->") }
        func isIndex(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(\.isNumber) }

        var cues: [SubtitleCue] = []
        var i = 0
        while i < lines.count {
            let line = trimmed(i)
            if line.isEmpty { i += 1; continue }

            var index = ""
            let timing: String
            if isTiming(i) {
                timing = line
                i += 1
            } else if isIndex(line), isTiming(i + 1) {
                index = line
                timing = trimmed(i + 1)
                i += 2
            } else {
                // Stray text (e.g. a blank line inside a cue): keep it with the previous cue.
                if !cues.isEmpty { cues[cues.count - 1].lines.append(lines[i]) }
                i += 1
                continue
            }

            var body: [String] = []
            while i < lines.count, !trimmed(i).isEmpty {
                body.append(lines[i])
                i += 1
            }
            cues.append(SubtitleCue(index: index, timing: timing, lines: body))
        }
        return SubtitleDocument(cues: cues, lineEnding: lineEnding)
    }

    func serialized() -> String {
        cues.enumerated().map { offset, cue in
            let index = cue.index.isEmpty ? String(offset + 1) : cue.index
            return ([index, cue.timing] + cue.lines).joined(separator: lineEnding)
        }
        .joined(separator: lineEnding + lineEnding) + lineEnding
    }
}

// MARK: - Text encoding

enum TextDecoding {
    struct DecodeError: LocalizedError {
        var errorDescription: String? { "파일 인코딩을 인식할 수 없습니다." }
    }

    static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return s }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }

        // Legacy encodings commonly found in subtitle files.
        func cf(_ e: CFStringEncodings) -> UInt { CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)) }
        let suggested: [UInt] = [
            cf(.dosKorean),            // CP949
            String.Encoding.shiftJIS.rawValue,
            cf(.GB_18030_2000),
            cf(.big5),
            String.Encoding.windowsCP1252.rawValue,
        ]
        var converted: NSString?
        var lossy = ObjCBool(false)
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.suggestedEncodingsKey: suggested.map { NSNumber(value: $0) }],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        if encoding != 0, let converted { return converted as String }
        throw DecodeError()
    }
}

// MARK: - Cue text <-> translatable segments

/// A cue reduced to plain sentences for the translator, plus what is needed to rebuild it.
struct PreparedCue: Sendable {
    var positionTag = ""          // e.g. {\an8}
    var italic = false
    var dialogDashes: [Bool] = [] // non-empty => dialog cue, one segment per line
    var parts: [String] = []
    var originalLineCount = 0
    var translatable: Bool { !parts.isEmpty }
}

enum CueFormatter {
    static func prepare(_ cue: SubtitleCue) -> PreparedCue {
        var result = PreparedCue()
        var lines = cue.lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return result }

        if let r = lines[0].range(of: #"^(\{\\[^}]*\})+"#, options: .regularExpression) {
            result.positionTag = String(lines[0][r])
            lines[0] = String(lines[0][r.upperBound...])
        }
        let joined = lines.joined(separator: "\n").lowercased()
        result.italic = joined.hasPrefix("<i>") && joined.hasSuffix("</i>")

        let clean = lines
            .map(stripTags)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        result.originalLineCount = clean.count

        let isDialog = clean.count >= 2 && clean.dropFirst().allSatisfy(startsWithDash)
        if isDialog {
            result.dialogDashes = clean.map(startsWithDash)
            result.parts = clean.map(dropDash)
        } else {
            result.parts = [clean.joined(separator: " ")]
        }
        // Nothing worth translating (music notes, punctuation only, ...).
        if !result.parts.contains(where: { $0.unicodeScalars.contains(where: CharacterSet.letters.contains) }) {
            result.parts = []
        }
        return result
    }

    static func render(_ cue: PreparedCue, original: SubtitleCue, translated: [String]) -> [String] {
        guard cue.translatable else { return original.lines }
        let texts = translated.map {
            $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        var out: [String]
        if !cue.dialogDashes.isEmpty {
            out = zip(cue.dialogDashes, texts).map { dash, text in dash ? "- " + text : text }
        } else {
            out = balancedSplit(texts.first ?? "", into: cue.originalLineCount)
        }
        if cue.italic {
            out[0] = "<i>" + out[0]
            out[out.count - 1] += "</i>"
        }
        out[0] = cue.positionTag + out[0]
        return out
    }

    /// Original text without markup, for showing below the translation.
    static func plainLines(_ cue: SubtitleCue) -> [String] {
        cue.lines.map(stripTags)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Re-wraps a long translated line into two lines when the source cue used two lines.
    private static func balancedSplit(_ text: String, into lineCount: Int) -> [String] {
        guard lineCount >= 2, text.count > 24 else { return [text] }
        let chars = Array(text)
        let middle = chars.count / 2
        let spaces = chars.indices.filter { chars[$0] == " " }
        guard let best = spaces.min(by: { abs($0 - middle) < abs($1 - middle) }),
              abs(best - middle) < chars.count / 3 else { return [text] }
        return [String(chars[..<best]), String(chars[(best + 1)...])]
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
    }

    private static func startsWithDash(_ s: String) -> Bool {
        s.hasPrefix("-") || s.hasPrefix("–") || s.hasPrefix("—")
    }

    private static func dropDash(_ s: String) -> String {
        guard startsWithDash(s) else { return s }
        return String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
}
