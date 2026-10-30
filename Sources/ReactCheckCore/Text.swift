import Foundation

typealias Scalars = [Unicode.Scalar]

enum Text {
    private static let kept: Set<Unicode.Scalar> = [".", ",", ";", ":", "(", ")"]
    private static let dropped: Set<Unicode.Scalar> = ["'", "\u{2019}", "\u{02BC}", "`", "\u{00B4}"]
    private static let mapped: [Unicode.Scalar: Unicode.Scalar] = [
        "\u{3002}": ".", "\u{3001}": ",", "\u{FF0C}": ",", "\u{FF1B}": ";", "\u{FF1A}": ":",
        "\u{FF08}": "(", "\u{FF09}": ")",
    ]
    private static let letterMap: [(String, String)] = [
        ("ß", "ss"), ("œ", "oe"), ("æ", "ae"), ("ø", "o"), ("ł", "l"), ("đ", "d"),
    ]

    /// Lowercase, strip Latin accents, reduce to letters, digits and a few sentence marks.
    /// Hyphens and other punctuation become spaces. Japanese voiced marks survive.
    static func normalize(_ input: String) -> String {
        var s = input.precomposedStringWithCompatibilityMapping.lowercased()
        for (a, b) in letterMap { s = s.replacingOccurrences(of: a, with: b) }
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for raw in s.decomposedStringWithCanonicalMapping.unicodeScalars {
            if (0x300...0x36F).contains(raw.value) { continue }
            if dropped.contains(raw) { continue }
            let sc = mapped[raw] ?? raw
            if kept.contains(sc) {
                out.append(sc)
                pendingSpace = true
                continue
            }
            let cat = sc.properties.generalCategory
            let isWordChar = sc.properties.isAlphabetic
                || sc.properties.numericType != nil
                || cat == .nonspacingMark || cat == .spacingMark
            if isWordChar {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(sc)
            } else {
                pendingSpace = true
            }
        }
        var result = String(out).precomposedStringWithCanonicalMapping
        // "E 322" and "E-322" read as one token.
        result = result.replacingOccurrences(
            of: #"\be (\d{3,4}[a-z]?)\b"#, with: "e$1", options: .regularExpression)
        return result
    }

    /// One scalar in, one scalar out, so offsets line up with the normalised text.
    /// Collapses characters OCR commonly confuses: 0->o, 1->l, i->l, 5->s.
    static func fold(_ s: String) -> String {
        var v = String.UnicodeScalarView()
        for sc in s.unicodeScalars { v.append(foldScalar(sc)) }
        return String(v)
    }

    static func foldScalar(_ sc: Unicode.Scalar) -> Unicode.Scalar {
        switch sc {
        case "0": return "o"
        case "1", "i": return "l"
        case "5": return "s"
        default: return sc
        }
    }

    static func canon(_ term: String) -> Scalars { Array(fold(normalize(term)).unicodeScalars) }

    static func string(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var v = String.UnicodeScalarView()
        v.append(contentsOf: s)
        return String(v).precomposedStringWithCanonicalMapping
    }

    static func isLatinAlnum(_ sc: Unicode.Scalar) -> Bool {
        sc.value < 0x250 && (sc.properties.isAlphabetic || sc.properties.numericType != nil)
    }

    struct Token {
        var text: String
        var scalars: Scalars
        var start: Int
        var end: Int
    }

    static func tokenize(_ fold: Scalars) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < fold.count {
            if isLatinAlnum(fold[i]) {
                var j = i
                while j < fold.count, isLatinAlnum(fold[j]) { j += 1 }
                let sl = Array(fold[i..<j])
                tokens.append(Token(text: string(sl[...]), scalars: sl, start: i, end: j))
                i = j
            } else {
                i += 1
            }
        }
        return tokens
    }

    /// Every start offset where `needle` occurs in `hay`.
    static func findAll(_ needle: Scalars, in hay: Scalars, from: Int = 0, limit: Int? = nil) -> [Int] {
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var found: [Int] = []
        let last = (limit ?? hay.count) - needle.count
        var i = from
        let first = needle[0]
        while i <= last {
            if hay[i] == first {
                var k = 1
                while k < needle.count, hay[i + k] == needle[k] { k += 1 }
                if k == needle.count { found.append(i) }
            }
            i += 1
        }
        return found
    }

    /// Optimal string alignment distance, giving up above `maxDistance`.
    static func distance(_ a: Scalars, _ b: Scalars, maxDistance: Int) -> Int {
        if abs(a.count - b.count) > maxDistance { return maxDistance + 1 }
        let n = a.count, m = b.count
        if n == 0 { return m }
        if m == 0 { return n }
        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev = Array(0...m)
        var cur = [Int](repeating: 0, count: m + 1)
        for i in 1...n {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...m {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    v = min(v, prev2[j - 2] + 1)
                }
                cur[j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > maxDistance { return maxDistance + 1 }
            swap(&prev2, &prev)
            swap(&prev, &cur)
        }
        return prev[m]
    }
}

/// Label text prepared for matching.
struct PreparedText {
    var norm: Scalars
    var fold: Scalars
    /// Start offset of each source line in `norm`, with that line's index.
    var lineStarts: [(offset: Int, line: Int)]

    init(lines: [(text: String, index: Int)]) {
        var norm = Scalars()
        var starts: [(Int, Int)] = []
        for (text, index) in lines {
            let n = Text.normalize(text)
            guard !n.isEmpty else { continue }
            if !norm.isEmpty { norm.append(" ") }
            starts.append((norm.count, index))
            norm.append(contentsOf: n.unicodeScalars)
        }
        self.norm = norm
        self.fold = norm.map(Text.foldScalar)
        self.lineStarts = starts
    }

    func lineIndex(at offset: Int) -> Int? {
        var result: Int?
        for (o, l) in lineStarts { if o <= offset { result = l } else { break } }
        return result
    }

    /// Source lines as they appear, plus a variant with hyphenated line wraps repaired.
    static func variants(of lines: [OCRLine]) -> [PreparedText] {
        let plain = PreparedText(lines: lines.enumerated().map { ($1.text, $0) })
        var merged: [(String, Int)] = []
        var carry: (String, Int)?
        let hyphens: Set<Character> = ["-", "\u{2010}", "\u{2011}", "\u{2013}"]
        for (i, line) in lines.enumerated() {
            var text = line.text.trimmingCharacters(in: .whitespaces)
            var index = i
            if let c = carry {
                if text.first?.isLetter == true { text = c.0 + text; index = c.1 }
                else { merged.append(c) }
                carry = nil
            }
            if let last = text.last, hyphens.contains(last) {
                carry = (String(text.dropLast()), index)
            } else {
                merged.append((text, index))
            }
        }
        if let c = carry { merged.append(c) }
        let repaired = PreparedText(lines: merged)
        return repaired.norm == plain.norm ? [plain] : [plain, repaired]
    }
}
