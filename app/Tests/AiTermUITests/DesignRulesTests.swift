import Foundation
import Testing

/// The README's two boundaries, read off the source: nothing in `AiTermUI` imports the rest of the
/// package, and no file but `Palette.swift` writes a literal colour. Every Swift file under
/// `Sources/AiTermUI`, subfolders included, is read; the app target is not. Comments are skipped —
/// a doc comment that names `.white` is not a violation — and string literals are too, so a `//`
/// inside one (an SVG's `http://`) does not cut the line short.
struct DesignRulesTests {
    /// A literal that is allowed where it stands, with the reason. Matched by file and by a piece of
    /// the offending line, so an entry covers one site rather than a whole file.
    private struct Exception {
        let file: String
        let line: String
        let reason: String
    }

    private static let exceptions = [
        Exception(file: "ControlChrome.swift", line: ".shadow(color: .black.opacity(",
                  reason: "a shadow's black is part of its geometry, which the README leaves untokenised"),
        Exception(file: "Metrics.swift", line: "case .black: nsWeight = .black",
                  reason: "Font.Weight.black mapped to NSFont.Weight.black: a weight, not a colour"),
    ]

    private static let colourLiteral = try! NSRegularExpression(
        pattern: #"\b(?:NS)?Color\((?:red|white|srgbRed|calibratedRed|deviceRed|calibratedWhite|deviceWhite|genericGamma22White|displayP3Red|hue|srgbHue|calibratedHue|deviceHue):|\b(?:NS)?Color\.(?:white|black)\b|(?<![\w)\]])\.(?:white|black)\b"#)
    private static let foreignImport = try! NSRegularExpression(pattern: #"^\s*(?:@testable\s+)?import\s+AiTerm(?:Core)?\s*$"#)

    @Test func aiTermUIImportsNothingElseInThePackage() throws {
        let violations = try Self.sources().flatMap { file, lines in
            lines.filter { Self.matches(Self.foreignImport, $0.code) }.map { "\(file):\($0.number): \($0.code)" }
        }
        #expect(violations.isEmpty, "AiTermUI must not import AiTermCore or AiTerm: \(violations)")
    }

    @Test func onlyPaletteWritesALiteralColour() throws {
        var used = Set<String>()
        var violations: [String] = []
        for (file, lines) in try Self.sources() where file != "Palette.swift" {
            for line in lines where Self.matches(Self.colourLiteral, line.code) {
                if let exception = Self.exceptions.first(where: { $0.file == file && line.code.contains($0.line) }) {
                    used.insert(exception.line)
                } else {
                    violations.append("\(file):\(line.number): \(line.code.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(violations.isEmpty, "a literal colour outside Palette.swift — name it in Palette: \(violations)")
        let stale = Self.exceptions.filter { !used.contains($0.line) }.map { "\($0.file): \($0.line)" }
        #expect(stale.isEmpty, "exceptions that no longer match anything — remove them: \(stale)")
    }

    /// The patterns themselves, so a regex that quietly matches nothing cannot pass the two scans.
    @Test func thePatternsCatchWhatTheyAreFor() {
        for literal in ["Circle().fill(.white)", "Color.black.opacity(0.4)", "Color(red: 1, green: 0, blue: 0)",
                        ".foregroundStyle(Color.white)", "NSColor.white", "x ? .white : .clear", "Color(white: 0.5)",
                        "NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)", "NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1)",
                        "Color(hue: 0.5, saturation: 1, brightness: 1)"] {
            #expect(Self.matches(Self.colourLiteral, literal), "missed \(literal)")
        }
        for fine in ["Palette.onAccent", "surface.ink", ".whitespaces", "Color(nsColor: .labelColor)", "blackBox"] {
            #expect(!Self.matches(Self.colourLiteral, fine), "flagged \(fine)")
        }
        #expect(Self.code(#"let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"; Color.white // note"#)
                    .contains("Color.white"), "a // inside a string cut the line")
        #expect(!Self.code("let a = 1 // Color.white").contains("Color.white"), "a comment was scanned")
        #expect(Self.code(##"let svg = #"<svg xmlns="http://www.w3.org/2000/svg"/>"#; Color.white"##)
                    .contains("Color.white"), "a // inside a raw string cut the line")
        #expect(!Self.code(##"let svg = #"a"#  // Color.white"##).contains("Color.white"), "a raw string swallowed a comment")
        #expect(Self.matches(Self.foreignImport, "import AiTermCore"))
        #expect(Self.matches(Self.foreignImport, "@testable import AiTerm"))
        #expect(!Self.matches(Self.foreignImport, "import AiTermUI"))
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `line` with any `//` comment removed. A `//` inside a string literal is text, not a comment:
    /// in a plain string an escaped quote does not end it, and a raw string (`#"…"#`, `##"…"##`)
    /// ends only at a quote followed by as many `#` as opened it. Multi-line strings and `/* */`
    /// blocks are not in this module's sources, so they are not modelled.
    static func code(_ line: String) -> String {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "/", i + 1 < chars.count, chars[i + 1] == "/" { return String(chars[..<i]) }
            if ch == "#" || ch == "\"" {
                var hashes = 0
                while i + hashes < chars.count, chars[i + hashes] == "#" { hashes += 1 }
                guard i + hashes < chars.count, chars[i + hashes] == "\"" else { i += 1; continue }
                i += hashes + 1
                // Inside the string: find its closing quote and the same run of `#`.
                while i < chars.count {
                    if hashes == 0, chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "\"", (0..<hashes).allSatisfy({ i + 1 + $0 < chars.count && chars[i + 1 + $0] == "#" }) {
                        i += hashes + 1
                        break
                    }
                    i += 1
                }
                continue
            }
            i += 1
        }
        return line
    }

    /// Every Swift file under `Sources/AiTermUI`, by its path there, as numbered lines of code.
    private static func sources() throws -> [(file: String, lines: [(number: Int, code: String)])] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AiTermUI")
        let enumerator = try #require(FileManager.default.enumerator(atPath: directory.path))
        let files = enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") }.sorted()
        #expect(files.contains("Palette.swift"), "the scan is not reading AiTermUI")
        return try files.map { file in
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            let lines = source.components(separatedBy: "\n").enumerated().map { index, line in
                (number: index + 1, code: code(line))
            }
            return (file: file, lines: lines)
        }
    }
}
