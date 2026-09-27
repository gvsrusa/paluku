import Foundation

public enum VoiceConfirmation {
    /// Whole-utterance match only: "okay but send it to Bob instead" must not approve anything.
    public static func parse(_ s: String) -> Bool? {
        let t = s.lowercased().components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")
            .replacingOccurrences(of: #"^(please )|( please)$"#, with: "", options: .regularExpression)
        if ["yes", "yeah", "yep", "confirm", "send it", "do it", "go ahead", "ok", "okay", "sure", "approve", "yes do it", "yes send it"].contains(t) {
            return true
        }
        if ["no", "nope", "cancel", "dont", "stop", "never mind", "nevermind", "no thanks"].contains(t) { return false }
        return nil
    }
}
