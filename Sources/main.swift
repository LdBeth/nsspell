import AppKit

enum Mode { case pipe, list, dicts, config, version, help, grammar }

let usage = """
    usage: nsspell [options] -a | -l | dicts | config KEY | -v
           nsspell grammar [-d NAME] [--quick] [--spelling] [-t] [--server | FILE...]
    Ispell/Aspell-compatible spell checker using the macOS spell checker.

    modes:
      -a, pipe            ispell pipe protocol (for Emacs)
      -l, list            print misspelled words of standard input
      grammar             print grammar issues of FILEs (or standard input)
                          as FILE:LINE:COL: MESSAGE [-> CORRECTIONS]
      dicts               list available dictionaries
      config KEY          print configuration value (dict-dir, data-dir, lang)
      -v, --version       print version banner
    options:
      -d, --lang NAME     dictionary (macOS language code, ispell name, or "auto")
      -p, --personal FILE personal word list (default: the system dictionary)
      --encoding ENC      utf-8 (default) or iso-8859-1
      -t, --mode=tex      skip TeX commands
    grammar options:
      --full, --quick     wait for the full analysis (default) or not
      --spelling          also report misspelled words
      --server            JSON-lines server for nsspell.el
    """

func fail(_ message: String) -> Never {
    printError(message)
    exit(1)
}

var mode: Mode?
var dictionary: String?
var personalPath: String?
var encodingName = "utf-8"
var tex = false
var configKey = ""
var grammarSettings = GrammarSettings()
var server = false
var files: [String] = []

let args = CommandLine.arguments
var index = 1

@MainActor
func argument(for option: String) -> String {
    index += 1
    guard index < args.count else { fail("option \(option) requires an argument") }
    return args[index]
}

/// Options taking an argument that we accept and ignore.
let ignoredWithArgument: Set<String> = [
    "-T", "-W", "-w", "--sug-mode", "--home-dir", "--data-dir", "--dict-dir",
    "--keyboard", "--add-extra-dicts",
]
let ignoredFlags: Set<String> = ["-m", "-B", "-C", "-S", "-P", "-x", "-n", "-H", "-o", "-b"]

while index < args.count {
    let arg = args[index]
    switch arg {
    case "": break
    case "-a", "pipe": mode = .pipe
    case "-l", "list": mode = .list
    case "dicts": mode = .dicts
    case "dump":
        if index + 1 < args.count && args[index + 1] == "dicts" {
            index += 1
            mode = .dicts
        } else {
            fail("unknown command \"dump\"")
        }
    case "config":
        mode = .config
        if index + 1 < args.count { configKey = argument(for: arg) }
    case "grammar": mode = .grammar
    case "--full": grammarSettings.full = true
    case "--quick": grammarSettings.full = false
    case "--spelling": grammarSettings.spelling = true
    case "--server": server = true
    case "-" where mode == .grammar: files.append(arg)
    case "-v", "-vv", "-V", "--version", "version": mode = .version
    case "-h", "--help", "help": mode = .help
    case "-d", "--lang", "--master": dictionary = argument(for: arg)
    case "-p", "--personal": personalPath = argument(for: arg)
    case "-i", "--encoding": encodingName = argument(for: arg)
    case "-t": tex = true
    case "--mode": if argument(for: arg) == "tex" { tex = true }
    case _ where ignoredWithArgument.contains(arg): _ = argument(for: arg)
    case _ where ignoredFlags.contains(arg): break
    case _ where arg.hasPrefix("--"):
        guard let eq = arg.firstIndex(of: "=") else { break }
        let key = String(arg[..<eq])
        let value = String(arg[arg.index(after: eq)...])
        switch key {
        case "--lang", "--master": dictionary = value
        case "--personal": personalPath = value
        case "--encoding": encodingName = value
        case "--mode": if value == "tex" { tex = true }
        default: break
        }
    case _ where arg.hasPrefix("-d"): dictionary = String(arg.dropFirst(2))
    case _ where arg.hasPrefix("-p"): personalPath = String(arg.dropFirst(2))
    case _ where arg.hasPrefix("-T") || arg.hasPrefix("-W") || arg.hasPrefix("-w"): break
    case _ where arg.hasPrefix("-"): fail("unknown option \(arg)")
    case _ where mode == .grammar: files.append(arg)
    default: fail("unknown command \"\(arg)\"")
    }
    index += 1
}

guard let encoding = parseEncoding(encodingName) else {
    fail("unsupported encoding \"\(encodingName)\"")
}
let output = Output(stream: stdout, encoding: encoding)

guard let mode else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(1)
}

switch mode {
case .help:
    output.line(usage)
case .version:
    output.line(banner)
case .dicts:
    for name in Languages.available { output.line(name) }
case .config, .pipe, .list, .grammar:
    guard let choice = Languages.resolve(dictionary) else {
        fail("The language \"\(dictionary ?? "")\" is not known.")
    }
    switch mode {
    case .config:
        output.line(Languages.configValue(configKey, choice: choice))
    case .grammar:
        grammarSettings.language = choice.fixedCode
        grammarSettings.tex = tex
        let checker = GrammarChecker()
        if server {
            GrammarServer(checker: checker, defaults: grammarSettings).start()
        } else {
            let settings = grammarSettings
            let paths = files
            Task {
                let status = await runGrammarFiles(paths, checker: checker, settings: settings,
                                                   output: output)
                output.flush()
                exit(status)
            }
        }
        runMainLoop()
    case .pipe:
        let speller = Speller(choice: choice, personalPath: personalPath)
        let input = LineReader(stream: stdin, encoding: encoding)
        PipeSession(speller: speller, input: input, output: output, tex: tex).run()
    default:
        let speller = Speller(choice: choice, personalPath: personalPath)
        let input = LineReader(stream: stdin, encoding: encoding)
        runList(speller: speller, input: input, output: output, tex: tex)
    }
}
output.flush()
