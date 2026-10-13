import AppKit

/// How the spell-checking language is chosen.
enum LanguageChoice {
    /// NSSpellChecker's current language at check time.
    case system
    /// A fixed NSSpellChecker language code.
    case fixed(String)
    /// Per-line detection with NaturalLanguage.
    case auto
}

@MainActor
enum Languages {
    static var available: [String] { NSSpellChecker.shared.availableLanguages }

    /// Traditional ispell dictionary names mapped to macOS language codes.
    static let legacyNames: [String: String] = [
        "american": "en", "english": "en", "british": "en_GB",
        "deutsch": "de", "deutsch8": "de", "german": "de", "german8": "de",
        "francais": "fr", "francais7": "fr", "francais-tex": "fr", "french": "fr",
        "castellano": "es", "castellano8": "es", "spanish": "es", "espanol": "es",
        "italiano": "it", "italian": "it",
        "nederlands": "nl", "nederlands8": "nl", "dutch": "nl",
        "norsk": "nb", "norsk7-tex": "nb", "bokmal": "nb", "nynorsk": "nn",
        "portugues": "pt_PT", "brasileiro": "pt_BR",
        "russian": "ru", "russianw": "ru",
        "svenska": "sv", "swedish": "sv", "dansk": "da", "danish": "da",
        "finnish": "fi", "polish": "pl", "czech": "cs", "slovenian": "sl",
        "hebrew": "he", "greek": "el", "turkish": "tr", "ukrainian": "uk",
        "hungarian": "hu",
    ]

    /// Resolves a dictionary name given with -d, or nil if unknown.
    static func resolve(_ name: String?) -> LanguageChoice? {
        guard let name, !name.isEmpty, name.lowercased() != "default" else { return .system }
        if name.lowercased() == "auto" { return .auto }
        let avail = available
        func find(_ n: String) -> String? {
            avail.first { $0.lowercased() == n.lowercased() }
        }
        let lower = name.lowercased()
        if let hit = find(lower) { return .fixed(hit) }
        let normalized = lower.replacingOccurrences(of: "-", with: "_")
        if let hit = find(normalized) { return .fixed(hit) }
        if let target = legacyNames[lower], let hit = find(target) { return .fixed(hit) }
        // Aspell variant suffix, e.g. en_US-w_accents.
        let base = String(lower.split(separator: "-", maxSplits: 1,
                                      omittingEmptySubsequences: false)[0])
            .replacingOccurrences(of: "-", with: "_")
        if let hit = find(base) { return .fixed(hit) }
        // Region, e.g. en_US -> en.
        let language = String(base.split(separator: "_", maxSplits: 1,
                                         omittingEmptySubsequences: false)[0])
        if let hit = find(language) { return .fixed(hit) }
        if !language.isEmpty,
           let hit = avail.first(where: { $0.lowercased().hasPrefix(language + "_") }) {
            return .fixed(hit)
        }
        return nil
    }

    /// Primary language subtag of a code: "pt_BR" -> "pt".
    static func prefix(_ code: String) -> String {
        String(code.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)[0])
    }

    /// Distinct primary subtags of the available languages, in order.
    static var prefixes: [String] {
        var seen = Set<String>()
        return available.map(prefix).filter { seen.insert($0).inserted }
    }

    /// Best available code for a bare language subtag such as "pt".
    static func bestCode(for language: String) -> String? {
        let avail = available
        return avail.first { $0 == language }
            ?? avail.first { $0.hasPrefix(language + "_") }
    }

    /// Directory holding generated Aspell .dat files for Emacs's dictionary discovery.
    static var dataDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("nsspell/aspell", isDirectory: true)
    }

    /// Creates the data directory with one <prefix>.dat file per language and
    /// one <legacy>.alias file per traditional name, as Aspell installs them.
    /// Without the aliases Emacs falls back to its ASCII-only "english" entry.
    static func ensureDataDirectory() -> URL {
        let dir = dataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ name: String, _ content: String) {
            let file = dir.appendingPathComponent(name)
            if (try? String(contentsOf: file, encoding: .utf8)) != content {
                try? content.write(to: file, atomically: true, encoding: .utf8)
            }
        }
        for p in prefixes {
            write("\(p).dat", "name \(p)\ncharset utf-8\nspecial ' -*- \u{2019} -*-\n")
        }
        for (legacy, target) in legacyNames {
            if case .fixed(let code)? = resolve(target) {
                write("\(legacy).alias", "add \(code).multi\n")
            }
        }
        return dir
    }

    /// Value for `config KEY` and `$$cr KEY`.
    static func configValue(_ key: String, choice: LanguageChoice) -> String {
        switch key {
        case "dict-dir", "data-dir": return ensureDataDirectory().path
        case "lang", "master":
            switch choice {
            case .system: return NSSpellChecker.shared.language()
            case .fixed(let code): return code
            case .auto: return "auto"
            }
        case "encoding": return "utf-8"
        default: return ""
        }
    }
}
