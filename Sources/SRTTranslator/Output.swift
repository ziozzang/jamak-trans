import Foundation

enum OutputContent: String, CaseIterable, Identifiable, Sendable {
    case translation, bilingual
    var id: String { rawValue }
    var title: String { self == .translation ? "번역문만" : "번역문 + 원문" }
}

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case srt, smi
    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum NamingMode: String, CaseIterable, Identifiable, Sendable {
    /// movie.en.srt -> movie.ko.srt (original untouched)
    case languageSuffix
    /// movie.srt -> movie.srt (translated) + movie.srt.org (original)
    case replaceOriginal
    var id: String { rawValue }
    var title: String { self == .languageSuffix ? "새 파일 (이름.ko.srt)" : "원본 이름 사용 (원본 → .org)" }
}

struct OutputOptions: Sendable, Equatable {
    var content: OutputContent = .translation
    var format: OutputFormat = .srt
    var naming: NamingMode = .languageSuffix

    static let originalColor = "#a0a0a0"
}

/// One cue ready to be written: translated lines plus (for bilingual output) the plain original.
struct RenderedCue: Sendable {
    var index: String
    var timing: String
    var translated: [String]
    var original: [String]
}

enum SubtitleWriter {
    static func text(for cues: [RenderedCue], options: OutputOptions, lineEnding: String,
                     title: String, language: Locale.Language) -> String {
        switch options.format {
        case .srt: srt(cues, options: options, lineEnding: lineEnding)
        case .smi: smi(cues, options: options, title: title, language: language)
        }
    }

    // MARK: SRT

    private static func srt(_ cues: [RenderedCue], options: OutputOptions, lineEnding: String) -> String {
        let document = SubtitleDocument(
            cues: cues.map { cue in
                var lines = cue.translated
                if options.content == .bilingual {
                    lines += cue.original.map { "<font color=\"\(OutputOptions.originalColor)\">\($0)</font>" }
                }
                return SubtitleCue(index: cue.index, timing: cue.timing, lines: lines)
            },
            lineEnding: lineEnding
        )
        return document.serialized()
    }

    // MARK: SAMI

    private static func smi(_ cues: [RenderedCue], options: OutputOptions, title: String, language: Locale.Language) -> String {
        let code = language.minimalIdentifier
        let className = (language.languageCode?.identifier ?? "xx").uppercased() + "CC"
        let name = LanguageNames.name(for: language)

        var out = """
        <SAMI>
        <HEAD>
        <TITLE>\(escape(title))</TITLE>
        <STYLE TYPE="text/css">
        <!--
        P { margin-left:8pt; margin-right:8pt; margin-bottom:2pt; margin-top:2pt;
            text-align:center; font-size:20pt; font-family:sans-serif; font-weight:normal; color:white; }
        .\(className) { Name:\(name); lang:\(code); SAMIType:CC; }
        -->
        </STYLE>
        </HEAD>
        <BODY>

        """

        let timed = cues.compactMap { cue -> (start: Int, end: Int, cue: RenderedCue)? in
            guard let (start, end) = parseTiming(cue.timing) else { return nil }
            return (start, end, cue)
        }
        .sorted { $0.start < $1.start }

        for (i, item) in timed.enumerated() {
            var body = item.cue.translated.map(inlineHTML).joined(separator: "<br>")
            if options.content == .bilingual, !item.cue.original.isEmpty {
                let original = item.cue.original.map(escape).joined(separator: "<br>")
                body += "<br><font color=\"\(OutputOptions.originalColor)\">\(original)</font>"
            }
            out += "<SYNC Start=\(item.start)><P Class=\(className)>\(body)\n"
            // Clear the screen unless the next cue starts right away.
            let nextStart = i + 1 < timed.count ? timed[i + 1].start : Int.max
            if item.end < nextStart {
                out += "<SYNC Start=\(item.end)><P Class=\(className)>&nbsp;\n"
            }
        }
        out += "</BODY>\n</SAMI>\n"
        return out
    }

    /// "00:01:02,345 --> 00:01:04,000" -> milliseconds
    static func parseTiming(_ timing: String) -> (Int, Int)? {
        let sides = timing.components(separatedBy: "-->")
        guard sides.count == 2, let start = milliseconds(sides[0]), let end = milliseconds(sides[1]) else { return nil }
        return (start, end)
    }

    private static func milliseconds(_ s: String) -> Int? {
        // Ignore trailing SRT position hints ("X1:... Y1:...").
        let token = s.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        let parts = token.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let sec = Double(parts[2]) else { return nil }
        return (h * 3600 + m * 60) * 1000 + Int((sec * 1000).rounded())
    }

    /// Keeps <i>/<b>/<u> from the rendered SRT line, escapes the rest, drops {\anX}.
    private static func inlineHTML(_ line: String) -> String {
        var s = line.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
        s = escape(s)
        for tag in ["i", "b", "u"] {
            s = s.replacingOccurrences(of: "&lt;\(tag)&gt;", with: "<\(tag)>", options: .caseInsensitive)
                .replacingOccurrences(of: "&lt;/\(tag)&gt;", with: "</\(tag)>", options: .caseInsensitive)
        }
        return s
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
