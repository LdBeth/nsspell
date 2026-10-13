import AppKit
import NaturalLanguage

struct Misspelling {
    /// The word as it appears in the original text.
    let word: String
    /// Offset in Unicode scalars (Emacs characters) from the start of the text.
    let offset: Int
    let range: NSRange
    let suggestions: [String]
}

/// A word list in Aspell's personal dictionary format.
final class PersonalDictionary {
    let path: String
    private(set) var words: Set<String> = []
    private var hadHeader = false
    private let existed: Bool
    private var dirty = false

    init(path: String) {
        self.path = (path as NSString).expandingTildeInPath
        existed = FileManager.default.fileExists(atPath: self.path)
        guard existed, let text = try? String(contentsOfFile: self.path, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: .newlines)
        if let first = lines.first, first.hasPrefix("personal_ws-") {
            hadHeader = true
            lines.removeFirst()
        }
        for line in lines {
            let word = line.trimmingCharacters(in: .whitespaces)
            if !word.isEmpty { words.insert(word) }
        }
    }

    /// Returns true if the word was not already present.
    @discardableResult
    func insert(_ word: String) -> Bool {
        let added = words.insert(word).inserted
        if added { dirty = true }
        return added
    }

    func save(language: String) throws {
        guard dirty else { return }
        var text = ""
        if hadHeader || (!existed && path.hasSuffix(".pws")) {
            text += "personal_ws-1.1 \(language) \(words.count)\n"
        }
        for word in words.sorted() { text += word + "\n" }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        dirty = false
    }
}

@MainActor
final class Speller {
    let checker = NSSpellChecker.shared
    let tag = NSSpellChecker.uniqueSpellDocumentTag()
    let choice: LanguageChoice
    let personal: PersonalDictionary?

    init(choice: LanguageChoice, personalPath: String?) {
        self.choice = choice
        personal = personalPath.map(PersonalDictionary.init)
        for word in personal?.words ?? [] {
            checker.ignoreWord(word, inSpellDocumentWithTag: tag)
        }
    }

    /// Language code used for a piece of text.
    func language(for text: String) -> String {
        switch choice {
        case .system: return checker.language()
        case .fixed(let code): return code
        case .auto: return detectLanguage(text) ?? checker.language()
        }
    }

    private func detectLanguage(_ text: String) -> String? {
        guard text.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Languages.prefixes.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        guard let (language, probability) = recognizer.languageHypotheses(withMaximum: 1).first,
              probability >= 0.6 else { return nil }
        return Languages.bestCode(for: language.rawValue)
    }

    /// Misspelled words of `text`.  `original`, which must have the same
    /// UTF-16 length, supplies the reported words and offsets.
    func misspellings(in text: String, original: String? = nil) -> [Misspelling] {
        let original = original ?? text
        let source = original as NSString
        let length = (text as NSString).length
        let language = language(for: text)
        var result: [Misspelling] = []
        var start = 0
        while start < length {
            let range = checker.checkSpelling(of: text, startingAt: start, language: language,
                                              wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0,
                  range.location >= start else { break }
            result.append(Misspelling(word: source.substring(with: range),
                                      offset: scalarOffset(range.location, in: original),
                                      range: range,
                                      suggestions: suggestions(for: range, in: text, language: language)))
            start = range.location + range.length
        }
        return result
    }

    private func suggestions(for range: NSRange, in text: String, language: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        let correction = checker.correction(forWordRange: range, in: text, language: language,
                                            inSpellDocumentWithTag: tag)
        let guesses = checker.guesses(forWordRange: range, in: text, language: language,
                                      inSpellDocumentWithTag: tag) ?? []
        for s in [correction].compactMap({ $0 }) + guesses
        where !s.contains(",") && seen.insert(s).inserted {
            result.append(s)
        }
        return result
    }

    /// Adds a word to the personal dictionary, or to the system one without -p.
    func addToPersonal(_ word: String) {
        guard !word.isEmpty else { return }
        if let personal {
            personal.insert(word)
            checker.ignoreWord(word, inSpellDocumentWithTag: tag)
        } else {
            checker.learnWord(word)
        }
    }

    /// Accepts a word for the rest of this session.
    func accept(_ word: String) {
        guard !word.isEmpty else { return }
        checker.ignoreWord(word, inSpellDocumentWithTag: tag)
    }

    func savePersonal() {
        guard let personal else { return }
        let language: String
        if case .fixed(let code) = choice { language = Languages.prefix(code) } else { language = "en" }
        do {
            try personal.save(language: language)
        } catch {
            printError("cannot save \(personal.path): \(error.localizedDescription)")
        }
    }
}

/// Converts a UTF-16 offset into a Unicode scalar offset.
func scalarOffset(_ utf16Offset: Int, in text: String) -> Int {
    let index = String.Index(utf16Offset: utf16Offset, in: text)
    return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
}
