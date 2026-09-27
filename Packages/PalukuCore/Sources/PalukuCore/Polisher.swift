import Foundation

/// Turns a raw transcript into text ready to paste.
public struct Polisher: Sendable {
    public var llm: any LLM
    public var model: String
    /// Seconds before giving up on the model (dictation pastes raw text; edit reports an error).
    public var timeout: Double = 20

    public init(llm: any LLM, model: String) {
        self.llm = llm
        self.model = model
    }

    /// Whisper's well-known outputs on silence/noise.
    static let hallucinations: Set<String> = [
        "", "you", "thank you", "thank you.", "thanks for watching!", "thanks for watching.", "bye.", "[blank_audio]",
        "(silence)", "[silence]", "[music]", "(music)", "subtitles by the amara.org community", ".",
    ]

    public static func isHallucination(_ s: String) -> Bool {
        hallucinations.contains(s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Replace configured mis-hearings with the preferred term (case-insensitive, whole words).
    public static func applyVocabulary(_ text: String, _ vocab: [VocabEntry]) -> String {
        var out = text
        for v in vocab where v.enabled {
            for alias in v.soundsLike where !alias.isEmpty {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: alias) + "\\b"
                out = out.replacingOccurrences(of: pattern, with: v.term, options: [.regularExpression, .caseInsensitive])
            }
        }
        return out
    }

    /// Strip Whisper tokens like "[BLANK_AUDIO]" and collapse whitespace.
    public static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\\[[A-Z_ ]+\\]|<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Remove wrapping quotes / "Here is…" preambles models sometimes add.
    public static func stripWrapper(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: "^(here is|here's)[^\\n]*:\\s*\\n", options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(r)
        }
        for (open, close) in [("\"", "\""), ("“", "”"), ("```", "```")] where t.hasPrefix(open) && t.hasSuffix(close) && t.count > open.count + close.count {
            t = String(t.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    public func polish(_ transcript: String, style: PolishStyle, vocabulary: [VocabEntry], appName: String?) async -> String {
        let raw = Self.applyVocabulary(Self.clean(transcript), vocabulary)
        if Self.isHallucination(raw) { return "" }
        guard style != .raw else { return raw }
        let terms = vocabulary.filter(\.enabled).map(\.term)
        do {
            let out = try await withTimeout(timeout) {
                try await llm.complete(
                    model: model, system: Prompts.polish(style: style, vocabulary: terms, appName: appName),
                    user: "Transcript:\n\(raw)", temperature: 0.1)
            }
            let cleaned = Self.stripWrapper(out)
            // Guard against the model answering the transcript instead of cleaning it.
            if cleaned.isEmpty || cleaned.count > raw.count * 2 + 80 { return raw }
            return cleaned
        } catch {
            return raw  // never lose the user's words because the LLM is down
        }
    }

    public func edit(selection: String, instruction: String) async throws -> String {
        let out = try await withTimeout(timeout * 2) {
            try await llm.complete(
                model: model, system: Prompts.edit,
                user: "SELECTED TEXT:\n\(selection)\n\nINSTRUCTION: \(instruction)", temperature: 0.3)
        }
        return Self.stripWrapper(out)
    }
}
