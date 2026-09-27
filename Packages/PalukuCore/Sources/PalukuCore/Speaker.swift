import AVFoundation

/// Spoken agent replies via the system's neural voices.
/// ponytail: AVSpeechSynthesizer; WhisperKit's TTSKit (Qwen3-TTS) is the upgrade path for more natural voices.
@MainActor
public final class Speaker {
    private let synth = AVSpeechSynthesizer()
    public var voiceIdentifier: String?
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    public init() {}

    public var isSpeaking: Bool { synth.isSpeaking }

    public func speak(_ text: String, language: String? = nil) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        u.rate = rate
        u.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? Self.bestVoice(language: language)
        synth.speak(u)
    }

    public func stop() { synth.stopSpeaking(at: .immediate) }

    /// Strip markdown/URLs that sound bad read aloud.
    static func speakable(_ s: String) -> String {
        s.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[*_`#>|]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func bestVoice(language: String?) -> AVSpeechSynthesisVoice? {
        let lang = language ?? AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(String(lang.prefix(2))) }
        return voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: lang)
    }

    public static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }
}
