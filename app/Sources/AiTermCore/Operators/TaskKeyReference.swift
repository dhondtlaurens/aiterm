import Foundation

/// A task's key as a wake line says it (`OperatorWaker`), and as the Operator's tools take it back
/// (`AppState.task(inRun:named:)`). A wake line carries no digit and no one-letter word, which a menu opening as it lands
/// could take for its answer (`1`, `y`, `a`; the daemon's `delivery.wake_text_problem`). So a key keeps its letters as
/// written and spells its digits, its parts joined by hyphens into one word: `area-E` stays `area-E`, `T7` is `T-seven`.
/// Only a key that is itself one letter is spelled out (`letter-ay`). The exact key is in `run_status`.
public enum TaskKeyReference {
    private static let digits = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let letters: [String: String] = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "eff", "g": "gee", "h": "aitch", "i": "eye", "j": "jay",
        "k": "kay", "l": "ell", "m": "em", "n": "en", "o": "oh", "p": "pee", "q": "cue", "r": "ar", "s": "ess", "t": "tee",
        "u": "you", "v": "vee", "w": "double-you", "x": "ex", "y": "why", "z": "zed",
    ]

    public static func spoken(_ key: String) -> String {
        var words: [String] = [], word = ""
        func flush() {
            if !word.isEmpty { words.append(word) }
            word = ""
        }
        for character in key {
            if character.isLetter { word.append(character) }
            else {
                flush()
                if let digit = character.wholeNumberValue, digit < digits.count { words.append(digits[digit]) }
            }
        }
        flush()
        if words.count == 1, let only = words.first, only.count == 1 { return "letter-" + (letters[only.lowercased()] ?? only) }
        return words.isEmpty ? "task" : words.joined(separator: "-")
    }
}
