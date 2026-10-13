import Foundation

/// Reads raw lines from a C stream with getline(3) and decodes them.
final class LineReader {
    let encoding: String.Encoding
    private let stream: UnsafeMutablePointer<FILE>
    private var buffer: UnsafeMutablePointer<CChar>? = nil
    private var capacity: Int = 0

    init(stream: UnsafeMutablePointer<FILE>, encoding: String.Encoding) {
        self.stream = stream
        self.encoding = encoding
    }

    deinit { free(buffer) }

    /// Next line without its terminator, or nil at end of input.
    func readLine() -> String? {
        let n = getline(&buffer, &capacity, stream)
        guard n >= 0, let buffer else { return nil }
        var length = n
        buffer.withMemoryRebound(to: UInt8.self, capacity: n) { bytes in
            if length > 0 && bytes[length - 1] == 0x0A { length -= 1 }
            if length > 0 && bytes[length - 1] == 0x0D { length -= 1 }
        }
        let data = Data(bytes: buffer, count: length)
        return String(data: data, encoding: encoding) ?? latin1(data)
    }

    private func latin1(_ data: Data) -> String {
        String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// Writes encoded text to a C stream; callers flush after each response.
final class Output {
    let encoding: String.Encoding
    private let stream: UnsafeMutablePointer<FILE>

    init(stream: UnsafeMutablePointer<FILE>, encoding: String.Encoding) {
        self.stream = stream
        self.encoding = encoding
    }

    func write(_ s: String) {
        guard let data = s.data(using: encoding, allowLossyConversion: true) else { return }
        data.withUnsafeBytes { raw in
            _ = fwrite(raw.baseAddress, 1, raw.count, stream)
        }
    }

    func line(_ s: String = "") { write(s + "\n") }

    func flush() { fflush(stream) }
}

/// Parses an encoding name given on the command line.
func parseEncoding(_ name: String) -> String.Encoding? {
    switch name.lowercased() {
    case "utf-8", "utf8": return .utf8
    case "iso-8859-1", "iso8859-1", "latin1", "latin-1": return .isoLatin1
    default: return nil
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("Error: \(message)\n".utf8))
}
