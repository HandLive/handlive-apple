// Variable names follow RFC 3492 section 6.3 so the code can be checked against it.
// swiftlint:disable identifier_name

/// Punycode encoder (RFC 3492) for one host label, without the `xn--` prefix. Foundation on macOS 13 has no public
/// IDNA conversion; the label is lower-cased by the caller (full IDNA mapping is out of the spike's scope).
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 128

    static func encode(_ label: String) -> String? {
        let input = label.unicodeScalars.map { Int($0.value) }
        var output = input.filter { $0 < 0x80 }.compactMap { Unicode.Scalar($0).map(Character.init) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < input.count {
            guard let next = input.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (next - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = next
            for code in input {
                if code < n { delta += 1 }
                guard code == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, numPoints: handled + 1, firstTime: handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    private static func digit(_ value: Int) -> Character {
        Character(Unicode.Scalar(UInt8(value < 26 ? value + 97 : value + 22)))
    }

    private static func adapt(_ delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
// swiftlint:enable identifier_name
