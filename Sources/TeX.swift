/// Blanks TeX markup so it is not spell-checked.  The result has the same
/// UTF-16 length as the input, so ranges found in it apply to the original.
enum TeX {
    /// Commands whose first braced argument is not prose.
    static let argumentCommands: Set<String> = [
        "begin", "end", "ref", "eqref", "pageref", "cref", "label",
        "usepackage", "documentclass", "input", "include",
        "bibliography", "bibliographystyle", "url", "href",
    ]

    static func mask(_ text: String) -> String {
        var u = Array(text.utf16)
        let n = u.count
        let space: UInt16 = 0x20
        func isLetter(_ c: UInt16) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x40
        }
        func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 }
        func blank(_ from: Int, _ to: Int) {
            for k in from..<to { u[k] = space }
        }
        /// End index (exclusive) of a group opened at `start`, or nil if unclosed.
        func groupEnd(_ start: Int, open: UInt16, close: UInt16) -> Int? {
            var depth = 0
            var k = start
            while k < n {
                if u[k] == 0x5C { k += 2; continue }
                if u[k] == open { depth += 1 }
                else if u[k] == close {
                    depth -= 1
                    if depth == 0 { return k + 1 }
                }
                k += 1
            }
            return nil
        }

        var i = 0
        while i < n {
            guard u[i] == 0x5C else { i += 1; continue }
            var j = i + 1
            if j < n && isLetter(u[j]) {
                while j < n && isLetter(u[j]) { j += 1 }
                let name = String(decoding: u[(i + 1)..<j], as: UTF16.self)
                if j < n && u[j] == 0x2A { j += 1 }  // starred form
                if argumentCommands.contains(name) || name.hasPrefix("cite") {
                    var k = j
                    while k < n && isSpace(u[k]) { k += 1 }
                    if k < n && u[k] == 0x5B, let e = groupEnd(k, open: 0x5B, close: 0x5D) {
                        k = e
                        while k < n && isSpace(u[k]) { k += 1 }
                    }
                    if k < n && u[k] == 0x7B, let e = groupEnd(k, open: 0x7B, close: 0x7D) {
                        j = e
                    }
                }
            } else if j < n {
                j += UTF16.isLeadSurrogate(u[j]) && j + 1 < n ? 2 : 1
            }
            blank(i, j)
            i = j
        }
        return String(decoding: u, as: UTF16.self)
    }
}
