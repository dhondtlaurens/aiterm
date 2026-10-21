import Foundation

/// What a person types or pastes into a broadcast's prompt, Review, Done or Instructions, every kind
/// of it: quotes and backticks, dollar signs as a shell reads them, backslashes, `!` and history-like
/// text, `#` and `-` at line starts, tabs, CRLF line ends, blank lines, non-ASCII, and lines several
/// thousand characters long. Each text starts with a bullet and ends on a word, so trimming what a
/// person typed (`OperatorCommand.said`) leaves it as it is.
public enum TypedText {
    public static let kinds = [
        #"It's "double" and 'single' quoted, with a `backtick`, ``two`` and an unclosed " and '."#,
        #"Dollars: $HOME, $(whoami), `id`, ${PATH}, ${HOME:-none}, $1, $@, $*, $$, $? and $((1 + 2)); it costs $5."#,
        #"Backslashes: C:\Users\me, \n, \t, \\, \$HOME, \" and one at the end \"#,
        "History: !!, !$, !-2, !grep, ^old^new^ and a bang! in a sentence!",
        "# a heading at a line start",
        "## and another",
        "- a bullet",
        "  - a nested bullet",
        "* a star bullet",
        "1. a numbered item",
        "--model opus --dangerously-skip-permissions",
        "\tA tab-indented line\twith a tab inside\t",
        "A Windows line end follows\r",
        "",
        "",
        "Arrows → ← ↑ ↓ ⇒, the middle dot ·, accents é è ü ñ ç å, quotes “ ” ‘ ’, an ellipsis …, "
            + "a non-breaking\u{00A0}space, emoji 🚀 👩‍💻 🇧🇪 and CJK 日本語.",
        "Globs * ? [abc] {a,b} ~/x ~root, redirections < > >> << | & ; 2>&1 && || and a comment # here",
        "%s %d %n %% \\0 printf's own escapes",
    ]

    /// `label`'s text: every kind above, then `longLines` lines each over 4,000 characters, then
    /// more of the same until it holds at least `bytes` bytes of UTF-8.
    public static func text(_ label: String, longLines: Int = 3, bytes: Int = 0) -> String {
        var lines = ["- \(label) starts with a bullet"] + kinds
        let all = kinds.joined(separator: " ")
        for n in 1...max(longLines, 1) {
            lines.append("\(label) long line \(n): " + String(repeating: all + " ", count: 4_000 / all.utf8.count + 1) + "end of line \(n).")
        }
        var n = 0
        while lines.joined(separator: "\n").utf8.count < bytes {
            n += 1
            lines.append("\(label) block \(n):")
            lines += kinds
        }
        lines.append("END OF \(label)")
        return lines.joined(separator: "\n")
    }
}
