import Foundation

/// The HTML sanitizer every platform runs on the `html` of a text clip (CLIP-01 API 5 `html`): the same algorithm as
/// the reference in `shared/tools/vectors/build_clipboard_html_vectors.py`, proven equal by `clipboard-html.json`.
///
/// Comments go; tag and attribute names are case-insensitive and output tags are lowercase; scripts, styles, frames
/// and the like go with their content; a fixed set of tags stays with its allowed attributes only; any other tag is
/// unwrapped (the tag goes, its content stays). The work is done on UTF-8 bytes: every piece of syntax is ASCII, so a
/// multi-byte character is never split.
public enum HtmlClipSanitizer {
    private static let dropContent: Set<String> = [
        "script", "style", "iframe", "object", "embed", "svg", "math", "template", "noscript", "head", "title",
        "textarea", "select", "button", "form", "input", "video", "audio", "canvas", "link", "meta", "base", "applet",
        "frame", "frameset"
    ]
    private static let keep: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "caption", "code", "div", "em", "figcaption", "figure", "h1", "h2", "h3",
        "h4", "h5", "h6", "hr", "i", "img", "li", "ol", "p", "pre", "s", "span", "strong", "sub", "sup", "table",
        "tbody", "td", "tfoot", "th", "thead", "tr", "u", "ul"
    ]
    private static let void: Set<String> = ["br", "hr", "img"]
    private static let allowedAttributes: [String: [String]] = [
        "a": ["href"], "img": ["src", "alt", "width", "height"], "td": ["colspan", "rowspan"],
        "th": ["colspan", "rowspan"]
    ]
    private static let urlSchemes: [String: [String]] = ["href": ["http:", "https:", "mailto:"], "src": ["http:", "https:"]]
    private static let digitsOnly: Set<String> = ["width", "height", "colspan", "rowspan"]

    /// The sanitized form of `html`; the size limit (`CLIP_MAX_HTML`) is measured on this output.
    public static func sanitize(_ html: String) -> String {
        let text = removeComments(Array(html.utf8))
        var out: [UInt8] = []
        var pos = 0
        while let tag = nextTag(in: text, from: pos) {
            out.append(contentsOf: text[pos..<tag.start])
            pos = tag.end
            if dropContent.contains(tag.name) {
                if !tag.closing { pos = closeTagEnd(of: tag.name, in: text, from: pos) ?? text.count }
                continue
            }
            guard keep.contains(tag.name) else { continue }
            if tag.closing {
                if !void.contains(tag.name) { out.append(contentsOf: Array("</\(tag.name)>".utf8)) }
            } else if let open = renderOpen(tag.name, attributes: text[tag.attributes]) {
                out.append(contentsOf: Array(open.utf8))
            }
        }
        out.append(contentsOf: text[pos...])
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Tokenizing

    private struct Tag {
        let start: Int
        let end: Int
        let closing: Bool
        let name: String
        let attributes: Range<Int>
    }

    private static func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
    private static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }

    /// `<!-- … -->` removed; an unclosed comment stays as it is.
    private static func removeComments(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var pos = 0
        while let open = find([60, 33, 45, 45], in: bytes, from: pos), let close = find([45, 45, 62], in: bytes, from: open + 4) {
            out.append(contentsOf: bytes[pos..<open])
            pos = close + 3
        }
        out.append(contentsOf: bytes[pos...])
        return out
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard from + needle.count <= bytes.count else { return nil }
        for index in from...(bytes.count - needle.count) where bytes[index] == needle[0] {
            if bytes[index..<(index + needle.count)].elementsEqual(needle) { return index }
        }
        return nil
    }

    /// The next `<name attrs>` or `</name attrs>` at or after `from`: a quoted `>` inside an attribute value does not end
    /// it; a `<` that does not start a complete tag is text.
    private static func nextTag(in bytes: [UInt8], from: Int) -> Tag? {
        var index = from
        while index < bytes.count {
            if bytes[index] == 60, let tag = tag(in: bytes, at: index) { return tag }
            index += 1
        }
        return nil
    }

    private static func tag(in bytes: [UInt8], at start: Int) -> Tag? {
        var index = start + 1
        let closing = index < bytes.count && bytes[index] == 47
        if closing { index += 1 }
        let nameStart = index
        guard index < bytes.count, isLetter(bytes[index]) else { return nil }
        while index < bytes.count, isLetter(bytes[index]) || isDigit(bytes[index]) { index += 1 }
        let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()
        let attributesStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 62 {
                return Tag(start: start, end: index + 1, closing: closing, name: name, attributes: attributesStart..<index)
            }
            if byte == 34 || byte == 39 {
                guard let quoteEnd = bytes[(index + 1)...].firstIndex(of: byte) else { return nil }
                index = quoteEnd
            }
            index += 1
        }
        return nil
    }

    /// End of the first `</name>` (case-insensitive, spaces allowed before `>`) at or after `from`.
    private static func closeTagEnd(of name: String, in bytes: [UInt8], from: Int) -> Int? {
        let wanted = Array(name.utf8)
        var index = from
        while index + 1 < bytes.count {
            defer { index += 1 }
            guard bytes[index] == 60, bytes[index + 1] == 47 else { continue }
            let nameEnd = index + 2 + wanted.count
            guard nameEnd <= bytes.count,
                  bytes[(index + 2)..<nameEnd].map({ isLetter($0) ? $0 | 0x20 : $0 }).elementsEqual(wanted)
            else { continue }
            var end = nameEnd
            while end < bytes.count, isSpace(bytes[end]) { end += 1 }
            if end < bytes.count, bytes[end] == 62 { return end + 1 }
        }
        return nil
    }

    // MARK: - Attributes

    /// `name`, then optionally `= value` (double-quoted, single-quoted or bare), found anywhere in the attribute text.
    private static func attributes(in bytes: ArraySlice<UInt8>) -> [(name: String, raw: String?)] {
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
            let name = String(decoding: bytes[index..<nameEnd], as: UTF8.self).lowercased()
            var valueStart = nameEnd
            while valueStart < bytes.endIndex, isSpace(bytes[valueStart]) { valueStart += 1 }
            var raw: String?
            var end = nameEnd
            if valueStart < bytes.endIndex, bytes[valueStart] == 61 {
                valueStart += 1
                while valueStart < bytes.endIndex, isSpace(bytes[valueStart]) { valueStart += 1 }
                if let valueEnd = valueEnd(in: bytes, from: valueStart) {
                    raw = String(decoding: bytes[valueStart..<valueEnd], as: UTF8.self)
                    end = valueEnd
                }
            }
            result.append((name, raw))
            index = end
        }
        return result
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte == 45 || byte == 95 || byte == 58 || byte == 46
    }

    /// End of a value starting at `from`: a quoted one up to its closing quote, a bare one up to a space, quote, `=`,
    /// `<`, `>` or backtick; `nil` when there is none.
    private static func valueEnd(in bytes: ArraySlice<UInt8>, from: Int) -> Int? {
        guard from < bytes.endIndex else { return nil }
        let first = bytes[from]
        if first == 34 || first == 39 {
            return bytes[(from + 1)...].firstIndex(of: first).map { $0 + 1 }
        }
        var end = from
        while end < bytes.endIndex, !isSpace(bytes[end]), ![34, 39, 61, 60, 62, 96].contains(bytes[end]) { end += 1 }
        return end > from ? end : nil
    }

    private static func unquoted(_ raw: String?) -> String {
        guard let raw else { return "" }
        let bytes = Array(raw.utf8)
        if bytes.count >= 2, bytes[0] == bytes[bytes.count - 1], bytes[0] == 34 || bytes[0] == 39 {
            return String(decoding: bytes[1..<(bytes.count - 1)], as: UTF8.self)
        }
        return raw
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The opening tag with its allowed attributes in a fixed order; `nil` for an `img` without a usable `src`.
    private static func renderOpen(_ name: String, attributes attributeBytes: ArraySlice<UInt8>) -> String? {
        let allowed = allowedAttributes[name] ?? []
        var found: [String: String] = [:]
        for (key, raw) in attributes(in: attributeBytes) where found[key] == nil && allowed.contains(key) {
            var value = unquoted(raw)
            if let schemes = urlSchemes[key] {
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
