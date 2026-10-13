import Foundation

let banner = "@(#) International Ispell Version 3.1.20 (but really Aspell 0.60.8) [nsspell 0.1; macOS NSSpellChecker]"

/// The ispell `-a` pipe protocol.
@MainActor
final class PipeSession {
    let speller: Speller
    let input: LineReader
    let output: Output
    var terse = false
    var tex: Bool

    init(speller: Speller, input: LineReader, output: Output, tex: Bool) {
        self.speller = speller
        self.input = input
        self.output = output
        self.tex = tex
    }

    func run() {
        output.line(banner)
        output.flush()
        while let line = input.readLine() {
            handle(line)
        }
    }

    private func handle(_ line: String) {
        guard let first = line.unicodeScalars.first else {
            output.line()
            output.flush()
            return
        }
        let rest = String(line.unicodeScalars.dropFirst())
        let argument = rest.trimmingCharacters(in: .whitespaces)
        switch first {
        case "*": speller.addToPersonal(argument)
        case "&": speller.addToPersonal(argument.lowercased())
        case "@": speller.accept(argument)
        case "#": speller.savePersonal()
        case "!": terse = true
        case "%": terse = false
        case "+": tex = true
        case "-": tex = false
        case "~": break
        case "^": check(rest, prefixLength: 1)
        case "$" where line.hasPrefix("$$"):
            extensionCommand(String(line.dropFirst(2)))
        default: check(line, prefixLength: 0)
        }
    }

    private func extensionCommand(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first == "cr" else { return }
        let key = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        output.line(Languages.configValue(key, choice: speller.choice))
        output.flush()
    }

    private func check(_ text: String, prefixLength: Int) {
        let checked = tex ? TeX.mask(text) : text
        let misspellings = speller.misspellings(in: checked, original: text)
        var events: [(location: Int, line: String)] = misspellings.map { m in
            let offset = m.offset + prefixLength
            let line = m.suggestions.isEmpty
                ? "# \(m.word) \(offset)"
                : "& \(m.word) \(m.suggestions.count) \(offset): \(m.suggestions.joined(separator: ", "))"
            return (m.range.location, line)
        }
        if !terse {
            for word in wordRanges(in: checked)
            where !misspellings.contains(where: { NSIntersectionRange($0.range, word).length > 0 }) {
                events.append((word.location, "*"))
            }
            events.sort { $0.location < $1.location }
        }
        for event in events { output.line(event.line) }
        output.line()
        output.flush()
    }
}

/// UTF-16 ranges of words: runs of letters, marks and digits, with internal
/// apostrophes and hyphens.
func wordRanges(in text: String) -> [NSRange] {
    func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        let p = s.properties
        switch p.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber: return true
        default: return p.isAlphabetic
        }
    }
    func isJoiner(_ s: Unicode.Scalar) -> Bool { s == "'" || s == "\u{2019}" || s == "-" }

    let scalars = Array(text.unicodeScalars)
    var ranges: [NSRange] = []
    var offset = 0  // UTF-16 offset of scalars[i]
    var i = 0
    while i < scalars.count {
        guard isWordScalar(scalars[i]) else {
            offset += scalars[i].utf16.count
            i += 1
            continue
        }
        let start = offset
        while i < scalars.count {
            if isWordScalar(scalars[i]) {
                offset += scalars[i].utf16.count
                i += 1
            } else if isJoiner(scalars[i]), i + 1 < scalars.count, isWordScalar(scalars[i + 1]) {
                offset += scalars[i].utf16.count
                i += 1
            } else {
                break
            }
        }
        ranges.append(NSRange(location: start, length: offset - start))
    }
    return ranges
}

/// `-l` mode: prints each misspelled word of standard input.
@MainActor
func runList(speller: Speller, input: LineReader, output: Output, tex: Bool) {
    while let line = input.readLine() {
        let checked = tex ? TeX.mask(line) : line
        for m in speller.misspellings(in: checked, original: line) {
            output.line(m.word)
        }
    }
    output.flush()
}
