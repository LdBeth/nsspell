import AppKit

/// What a grammar check looks for.
struct GrammarSettings: Hashable, Sendable {
    /// Fixed language code, or nil to let the system decide.
    var language: String?
    /// Wait for the full (slow, context-aware) analysis.
    var full = true
    /// Also report misspelled words.
    var spelling = false
    /// Skip TeX markup.
    var tex = false
}

/// A reported issue.  Offsets are in Unicode scalars (Emacs characters).
struct GrammarIssue: Sendable {
    var start: Int
    var end: Int
    var message: String
    var short: String?
    var corrections: [String]
    var category: String?
    var kind: String
    var uuid: String?

    func shifted(by delta: Int) -> GrammarIssue {
        var issue = self
        issue.start += delta
        issue.end += delta
        return issue
    }
}

/// A result as delivered by the text checker, before offsets are converted.
/// Ranges are UTF-16; `range` is relative to the paragraph, `grammarRange`
/// to the sentence.
private struct RawIssue: Sendable {
    var range: NSRange
    var sentence: NSRange
    var grammarRange: NSRange
    var message: String?
    var short: String?
    var corrections: [String]
    var category: String?
    var uuid: String?
    var spelling: Bool

    static func extract(_ result: NSTextCheckingResult) -> [RawIssue] {
        switch result.resultType {
        case .spelling:
            return [RawIssue(range: result.range, sentence: result.range,
                             grammarRange: NSRange(location: 0, length: result.range.length),
                             corrections: [], spelling: true)]
        case .grammar:
            let sentence = result.range
            return (result.grammarDetails ?? []).map { detail in
                let local = (detail[NSGrammarRange] as? NSValue)?.rangeValue
                    ?? NSRange(location: 0, length: sentence.length)
                return RawIssue(
                    range: NSRange(location: sentence.location + local.location, length: local.length),
                    sentence: sentence, grammarRange: local,
                    message: detail[NSGrammarUserDescription] as? String,
                    short: detail["NSGrammarUserShortDescription"] as? String,
                    corrections: detail[NSGrammarCorrections] as? [String] ?? [],
                    category: describe(detail["NSGrammarUserCategory"])
                        ?? describe(detail["NSGrammarSystemCategory"]),
                    uuid: describe(detail["NSGrammarUUID"]),
                    spelling: false)
            }
        default:
            return []
        }
    }

    private static func describe(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s
        case let u as UUID: return u.uuidString
        case let u as NSUUID: return u.uuidString
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}

/// Paragraphs of a text: runs of lines separated by blank lines.
struct Paragraph {
    /// Offset of the paragraph in Unicode scalars.
    let offset: Int
    let text: String

    static func split(_ text: String) -> [Paragraph] {
        let scalars = Array(text.unicodeScalars)
        var result: [Paragraph] = []
        var start: Int? = nil   // first scalar of the current paragraph
        var end = 0             // end of its last non-blank line
        var i = 0
        func flush() {
            if let s = start {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[s..<end])
                result.append(Paragraph(offset: s, text: String(view)))
            }
            start = nil
        }
        while i < scalars.count {
            var j = i
            while j < scalars.count && scalars[j] != "\n" { j += 1 }
            let blank = scalars[i..<j].allSatisfy { $0.properties.isWhitespace }
            if blank {
                flush()
            } else {
                if start == nil { start = i }
                end = j
            }
            i = j + 1
        }
        flush()
        return result
    }
}

/// Limits the number of concurrent checker requests.
@MainActor
private final class Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = count }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Grammar checking with NSSpellChecker, cached per paragraph.
@MainActor
final class GrammarChecker {
    /// NSTextCheckingWaitForAllGrammarCheckingResultsKey (macOS 27), which
    /// Swift does not expose by name.
    static let waitForAllKey = NSSpellChecker.OptionKey(rawValue: "WaitForAllGrammarCheckingResults")
    static let cacheLimit = 2000

    private struct Key: Hashable {
        let text: String
        let settings: GrammarSettings
    }

    private struct Checked {
        /// Issues with offsets relative to the paragraph.
        var issues: [GrammarIssue]
        /// Sentences the issues were found in, for invalidation on ignore.
        var sentences: Set<String>
    }

    let checker = NSSpellChecker.shared
    let tag = NSSpellChecker.uniqueSpellDocumentTag()
    private var cache: [Key: Checked] = [:]
    private var inflight: [Key: Task<Checked, Never>] = [:]
    /// Grammar detail UUID -> the sentence and range to ignore.
    private var ignorable: [String: (sentence: String, range: NSRange)] = [:]
    private let limiter = Limiter(4)

    /// Issues of `text`, with offsets relative to it.
    func check(_ text: String, settings: GrammarSettings) async -> [GrammarIssue] {
        let paragraphs = Paragraph.split(text)
        let tasks = paragraphs.map { task(for: $0.text, settings: settings) }
        var issues: [GrammarIssue] = []
        for (paragraph, task) in zip(paragraphs, tasks) {
            issues += await task.value.issues.map { $0.shifted(by: paragraph.offset) }
        }
        return issues
    }

    /// Ignores a grammar issue from now on.  Returns false if it is unknown.
    func ignore(uuid: String) -> Bool {
        guard let entry = ignorable.removeValue(forKey: uuid) else { return false }
        checker.ignoreGrammarRange(entry.range, inSentence: entry.sentence, inSpellDocumentWithTag: tag)
        cache = cache.filter { !$0.value.sentences.contains(entry.sentence) }
        return true
    }

    private func task(for paragraph: String, settings: GrammarSettings) -> Task<Checked, Never> {
        let key = Key(text: paragraph, settings: settings)
        if let checked = cache[key] { return Task { checked } }
        if let running = inflight[key] { return running }
        let task = Task {
            let checked = await self.compute(paragraph, settings: settings)
            if self.cache.count >= Self.cacheLimit { self.cache.removeAll() }
            self.cache[key] = checked
            self.inflight[key] = nil
            return checked
        }
        inflight[key] = task
        return task
    }

    private func compute(_ paragraph: String, settings: GrammarSettings) async -> Checked {
        await limiter.acquire()
        let text = settings.tex ? TeX.mask(paragraph) : paragraph
        let raws = await request(text, settings: settings)
        limiter.release()

        let source = text as NSString
        let language = settings.language ?? checker.language()
        var checked = Checked(issues: [], sentences: [])
        for raw in raws where settings.spelling || !raw.spelling {
            let start = scalarOffset(raw.range.location, in: paragraph)
            let end = scalarOffset(raw.range.location + raw.range.length, in: paragraph)
            if raw.spelling {
                let word = (paragraph as NSString).substring(with: raw.range)
                let guesses = checker.guesses(forWordRange: raw.range, in: text, language: language,
                                              inSpellDocumentWithTag: tag) ?? []
                checked.issues.append(GrammarIssue(
                    start: start, end: end, message: "Misspelled word \u{2018}\(word)\u{2019}",
                    corrections: Array(guesses.prefix(8)), kind: "spelling"))
            } else {
                let sentence = source.substring(with: raw.sentence)
                checked.sentences.insert(sentence)
                if let uuid = raw.uuid { ignorable[uuid] = (sentence, raw.grammarRange) }
                checked.issues.append(GrammarIssue(
                    start: start, end: end,
                    message: raw.message ?? raw.short ?? "Grammar issue",
                    short: raw.short, corrections: raw.corrections, category: raw.category,
                    kind: "grammar", uuid: raw.uuid))
            }
        }
        checked.issues.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        return checked
    }

    private func request(_ text: String, settings: GrammarSettings) async -> [RawIssue] {
        // Grammar results only arrive when spelling is requested as well;
        // unwanted spelling results are dropped by the caller.
        let types = NSTextCheckingResult.CheckingType.grammar.rawValue
            | NSTextCheckingResult.CheckingType.spelling.rawValue
        var options: [NSSpellChecker.OptionKey: Any] = [:]
        if settings.full { options[Self.waitForAllKey] = true }
        if let language = settings.language {
            options[.orthography] = NSOrthography.defaultOrthography(forLanguage: language)
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return await withCheckedContinuation { continuation in
            checker.requestChecking(of: text, range: range, types: types, options: options,
                                    inSpellDocumentWithTag: tag,
                                    completionHandler: Self.completion(continuation))
        }
    }

    /// The completion runs on a background queue, so it must not inherit
    /// main-actor isolation from the method creating it.
    nonisolated private static func completion(
        _ continuation: CheckedContinuation<[RawIssue], Never>
    ) -> (Int, [NSTextCheckingResult], NSOrthography, Int) -> Void {
        { _, results, _, _ in continuation.resume(returning: results.flatMap(RawIssue.extract)) }
    }
}

// MARK: - One-shot mode

/// Checks files (or standard input) and prints `FILE:LINE:COL: MESSAGE`.
/// Returns the exit status: 0 clean, 1 issues found, 2 on error.
@MainActor
func runGrammarFiles(_ files: [String], checker: GrammarChecker, settings: GrammarSettings,
                     output: Output) async -> Int32 {
    var status: Int32 = 0
    let inputs = files.isEmpty ? ["-"] : files
    for file in inputs {
        let data: Data
        let name: String
        if file == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
            name = "<stdin>"
        } else {
            guard let contents = FileManager.default.contents(atPath: file) else {
                printError("cannot read \(file)")
                status = 2
                continue
            }
            data = contents
            name = file
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let issues = await checker.check(text, settings: settings)
        let lines = LineIndex(text)
        for issue in issues {
            let (line, column) = lines.position(of: issue.start)
            var message = "\(name):\(line):\(column): \(issue.message)"
            if !issue.corrections.isEmpty {
                message += " [-> " + issue.corrections.joined(separator: " | ") + "]"
            }
            output.line(message)
        }
        output.flush()
        if !issues.isEmpty && status == 0 { status = 1 }
    }
    return status
}

/// Maps scalar offsets to 1-based line and column numbers.
struct LineIndex {
    private var starts: [Int] = [0]

    init(_ text: String) {
        for (i, scalar) in text.unicodeScalars.enumerated() where scalar == "\n" {
            starts.append(i + 1)
        }
    }

    func position(of offset: Int) -> (line: Int, column: Int) {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return (low + 1, offset - starts[low] + 1)
    }
}

// MARK: - Server mode

/// Lets a value cross into the stdin reader thread, which is its only user.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// A request id echoed back in replies.
enum RequestID: Sendable {
    case number(Int)
    case string(String)

    init?(_ value: Any?) {
        switch value {
        case let n as NSNumber: self = .number(n.intValue)
        case let s as String: self = .string(s)
        default: return nil
        }
    }

    var json: Any {
        switch self {
        case .number(let n): return n
        case .string(let s): return s
        }
    }
}

/// The JSON-lines grammar server used by nsspell.el.
@MainActor
final class GrammarServer {
    let checker: GrammarChecker
    let defaults: GrammarSettings
    let output: Output
    /// The reply written last; each reply waits for its predecessor so that
    /// replies come out in request order.
    private var tail: Task<Void, Never>?
    /// The latest ignore request; checks arriving after it wait for it.
    private var barrier: Task<String, Never>?

    init(checker: GrammarChecker, defaults: GrammarSettings) {
        self.checker = checker
        self.defaults = defaults
        output = Output(stream: stdout, encoding: .utf8)
    }

    func start() {
        output.line(Self.serialize(["nsspell": "0.1", "protocol": 1]))
        output.flush()
        let reader = UncheckedBox(LineReader(stream: stdin, encoding: .utf8))
        Thread(block: Self.readLoop(reader, server: self)).start()
    }

    /// Reads requests on a background thread and handles them on the main one.
    nonisolated private static func readLoop(_ reader: UncheckedBox<LineReader>,
                                             server: GrammarServer) -> @Sendable () -> Void {
        {
            while let line = reader.value.readLine() {
                DispatchQueue.main.async { MainActor.assumeIsolated { server.handle(line) } }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { server.quit() } }
        }
    }

    private func handle(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let request = object as? [String: Any] else {
            reply(error: "invalid JSON request", id: nil)
            return
        }
        let id = RequestID(request["id"])
        switch request["op"] as? String {
        case "check":
            check(request, id: id)
        case "ignore":
            guard let uuid = request["uuid"] as? String else {
                reply(error: "ignore: missing uuid", id: id)
                return
            }
            // The uuid comes from an earlier reply, and later checks must see
            // the ignore, so run it after every earlier request.
            let previous = tail
            let work = Task {
                await previous?.value
                var response: [String: Any] = ["ok": self.checker.ignore(uuid: uuid)]
                if let id { response["id"] = id.json }
                return Self.serialize(response)
            }
            barrier = work
            enqueue(work)
        case "quit":
            quit()
        default:
            reply(error: "unknown op", id: id)
        }
    }

    private func check(_ request: [String: Any], id: RequestID?) {
        var settings = defaults
        if let full = request["full"] as? Bool { settings.full = full }
        if let spelling = request["spelling"] as? Bool { settings.spelling = spelling }
        if let tex = request["tex"] as? Bool { settings.tex = tex }
        if let name = request["lang"] as? String {
            guard let choice = Languages.resolve(name) else {
                reply(error: "The language \"\(name)\" is not known.", id: id)
                return
            }
            settings.language = choice.fixedCode
        }
        var segments: [(start: Int, text: String)] = []
        for case let segment as [String: Any] in request["segments"] as? [Any] ?? [] {
            guard let text = segment["text"] as? String else { continue }
            segments.append(((segment["start"] as? NSNumber)?.intValue ?? 0, text))
        }
        let barrier = barrier
        let work = Task {
            _ = await barrier?.value
            var issues: [GrammarIssue] = []
            for segment in segments {
                issues += await self.checker.check(segment.text, settings: settings)
                    .map { $0.shifted(by: segment.start) }
            }
            var response: [String: Any] = ["issues": issues.map(Self.json)]
            if let id { response["id"] = id.json }
            return Self.serialize(response)
        }
        enqueue(work)
    }

    private func reply(error message: String, id: RequestID?) {
        var response: [String: Any] = ["error": message]
        if let id { response["id"] = id.json }
        send(Self.serialize(response))
    }

    private func send(_ line: String) {
        enqueue(Task { line })
    }

    private func enqueue(_ work: Task<String, Never>) {
        let previous = tail
        tail = Task {
            await previous?.value
            let line = await work.value
            self.output.line(line)
            self.output.flush()
        }
    }

    /// Exits once every earlier request has been answered.
    private func quit() {
        let previous = tail
        tail = Task {
            await previous?.value
            self.output.flush()
            exit(0)
        }
    }

    private static func json(_ issue: GrammarIssue) -> [String: Any] {
        var object: [String: Any] = [
            "start": issue.start, "end": issue.end, "message": issue.message,
            "corrections": issue.corrections, "kind": issue.kind,
        ]
        if let short = issue.short { object["short"] = short }
        if let category = issue.category { object["category"] = category }
        if let uuid = issue.uuid { object["uuid"] = uuid }
        return object
    }

    private static func serialize(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return #"{"error":"cannot encode reply"}"# }
        return String(decoding: data, as: UTF8.self)
    }
}

extension LanguageChoice {
    /// The language to pass to the text checker; nil lets the system decide.
    var fixedCode: String? {
        if case .fixed(let code) = self { return code }
        return nil
    }
}

/// Runs the main run loop forever; NSSpellChecker delivers results through it.
func runMainLoop() -> Never {
    let keepAlive = Timer(timeInterval: 1e9, repeats: true) { _ in }
    RunLoop.main.add(keepAlive, forMode: .default)
    while true {
        _ = RunLoop.main.run(mode: .default, before: .distantFuture)
    }
}
