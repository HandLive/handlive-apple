import Foundation

/// Attribute scanning and the rendering of an opening tag for `HtmlClipSanitizer`: same byte-level rules as the
/// reference (`ATTR_RE` and `_render_open` in `build_clipboard_html_vectors.py`), kept apart from the tag scanner so
/// each file stays readable.
extension HtmlClipSanitizer {
    /// `name`, then optionally `= value` (double-quoted, single-quoted or bare), found anywhere in the attribute text.
    static func attributes(in bytes: ArraySlice<UInt8>) -> [(name: String, raw: String?)] {
        var result: [(String, String?)] = []
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let first = bytes[index]
            guard isLetter(first) || first == 95 || first == 58 else {
                index += 1
                continue
            }
            var nameEnd = index + 1
            while nameEnd < bytes.endIndex, isNameByte(bytes[nameEnd]) { nameEnd += 1 }
            let name = string(bytes[index..<nameEnd]).lowercased()
            var valueStart = skipSpaces(in: bytes, from: nameEnd)
            var raw: String?
            var end = nameEnd
            if valueStart < bytes.endIndex, bytes[valueStart] == 61 {
                valueStart = skipSpaces(in: bytes, from: valueStart + 1)
                if let valueEnd = valueEnd(in: bytes, from: valueStart) {
                    raw = string(bytes[valueStart..<valueEnd])
                    end = valueEnd
                }
            }
            result.append((name, raw))
            index = end
        }
        return result
    }

    static func skipSpaces(in bytes: ArraySlice<UInt8>, from: Int) -> Int {
        var index = from
        while index < bytes.endIndex, isSpace(bytes[index]) { index += 1 }
        return index
    }

    static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte == 45 || byte == 95 || byte == 58 || byte == 46
    }

    /// End of a value starting at `from`: a quoted one up to its closing quote, a bare one up to a space, quote, `=`,
    /// `<`, `>` or backtick; `nil` when there is none.
    static func valueEnd(in bytes: ArraySlice<UInt8>, from: Int) -> Int? {
        guard from < bytes.endIndex else { return nil }
        let first = bytes[from]
        if first == 34 || first == 39 {
            return bytes[(from + 1)...].firstIndex(of: first).map { $0 + 1 }
        }
        var end = from
        while end < bytes.endIndex, !isSpace(bytes[end]), ![34, 39, 61, 60, 62, 96].contains(bytes[end]) { end += 1 }
        return end > from ? end : nil
    }

    static func unquoted(_ raw: String?) -> String {
        guard let raw else { return "" }
        let bytes = Array(raw.utf8)
        if bytes.count >= 2, bytes[0] == bytes[bytes.count - 1], bytes[0] == 34 || bytes[0] == 39 {
            return string(bytes[1..<(bytes.count - 1)])
        }
        return raw
    }

    static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The opening tag with its allowed attributes in a fixed order; `nil` for an `img` without a usable `src`.
    static func renderOpen(_ name: String, attributes attributeBytes: ArraySlice<UInt8>) -> String? {
        let allowed = allowedAttributes[name] ?? []
        var found: [String: String] = [:]
        for (key, raw) in attributes(in: attributeBytes) where found[key] == nil && allowed.contains(key) {
            var value = unquoted(raw)
            if let schemes = urlSchemes[key] {
                value = trimSpace(value)
                let lower = Array(value.lowercased().utf8)
                guard schemes.contains(where: { lower.starts(with: $0.utf8) }) else { continue }
            } else if digitsOnly.contains(key), value.isEmpty || !value.utf8.allSatisfy(isDigit) {
                continue
            }
            found[key] = value
        }
        if name == "img", found["src"] == nil { return nil }
        return "<" + name + allowed.compactMap { key in found[key].map { " \(key)=\"\(escaped($0))\"" } }.joined() + ">"
    }
}
