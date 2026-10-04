import Foundation

/// The HTML sanitizer every platform runs on the `html` of a text clip (CLIP-01 API 5 `html`): the same algorithm as
/// the reference in `shared/tools/vectors/build_clipboard_html_vectors.py`, proven equal by `clipboard-html.json`.
///
/// Comments (and `<!…>` / `<?…>` bogus comments) go; tag and attribute names are case-insensitive and output tags are lowercase; scripts, styles, frames
/// and the like go with their content; a fixed set of tags stays with its allowed attributes only; any other tag is
/// unwrapped (the tag goes, its content stays). A `<` in text that did not complete a tag becomes `&lt;`. The work is done on UTF-8 bytes: every piece of syntax is ASCII, so a
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
    static let allowedAttributes: [String: [String]] = [
        "a": ["href"], "img": ["src", "alt", "width", "height"], "td": ["colspan", "rowspan"],
        "th": ["colspan", "rowspan"]
    ]
    static let urlSchemes: [String: [String]] = ["href": ["http:", "https:", "mailto:"], "src": ["http:", "https:"]]
    static let digitsOnly: Set<String> = ["width", "height", "colspan", "rowspan"]

    /// The sanitized form of `html`; the size limit (`CLIP_MAX_HTML`) is measured on this output.
    public static func sanitize(_ html: String) -> String {
        let text = removeBogusComments(removeComments(Array(html.utf8)))
        var out: [UInt8] = []
        var pos = 0
        while let tag = nextTag(in: text, from: pos) {
            appendText(text[pos..<tag.start], to: &out)
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
        appendText(text[pos...], to: &out)
        return string(out)
    }

    // MARK: - Tokenizing

    private struct Tag {
        let start: Int
        let end: Int
        let closing: Bool
        let name: String
        let attributes: Range<Int>
    }

    /// Bytes cut at ASCII syntax characters of a valid UTF-8 string are valid UTF-8 again, so decoding never repairs.
    static func string(_ bytes: some Collection<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    static func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    static func isDigit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
    static func isSpace(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }

    /// `str.strip` of the reference on ASCII whitespace only: NBSP and other Unicode spaces stay part of the value.
    static func trimSpace(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var start = 0
        var end = bytes.count
        while start < end, isSpace(bytes[start]) { start += 1 }
        while end > start, isSpace(bytes[end - 1]) { end -= 1 }
        return string(bytes[start..<end])
    }

    /// `<!-- … -->` removed; an unclosed comment runs to the end of the input, as in HTML.
    private static func removeComments(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var pos = 0
        while let open = find([60, 33, 45, 45], in: bytes, from: pos) {
            out.append(contentsOf: bytes[pos..<open])
            guard let close = find([45, 45, 62], in: bytes, from: open + 4) else { return out }
            pos = close + 3
        }
        out.append(contentsOf: bytes[pos...])
        return out
    }

    /// `<!…>` that is not a comment (doctype, CDATA) and `<?…>` removed up to and including the next `>`, or to the
    /// end of the input when there is none.
    private static func removeBogusComments(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let bogus = bytes[index] == 60 && index + 1 < bytes.count && (bytes[index + 1] == 33 || bytes[index + 1] == 63)
            guard bogus else {
                out.append(bytes[index])
                index += 1
                continue
            }
            guard let close = bytes[(index + 2)...].firstIndex(of: 62) else { return out }
            index = close + 1
        }
        return out
    }

    /// Text between tags: copied as is, except a `<` followed by `/` or an ASCII letter (it did not complete a tag, so
    /// the receiving parser would close it at the next `>`) becomes `&lt;`.
    private static func appendText(_ segment: ArraySlice<UInt8>, to out: inout [UInt8]) {
        for index in segment.indices {
            let opensTag = segment[index] == 60 && index + 1 < segment.endIndex
                && (segment[index + 1] == 47 || isLetter(segment[index + 1]))
            if opensTag { out.append(contentsOf: Array("&lt;".utf8)) } else { out.append(segment[index]) }
        }
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
        let name = string(bytes[nameStart..<index]).lowercased()
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

    /// End of the first `</name>` (ASCII case-insensitive only, spaces allowed before `>`) at or after `from`.
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
}
