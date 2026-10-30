import Foundation

struct CTerm {
    var owner: String
    var display: String
    var kind: Evidence
    var canon: Scalars
    var tokens: [String]
    var isWord: Bool
    var fuzzy: Bool
}

struct Hit {
    var term: Int
    var start: Int
    var end: Int
    var fuzzy: Bool
}

/// All terms compiled for matching.
struct TermIndex {
    var terms: [CTerm]
    private var wordIndex: [String: [Int]] = [:]
    private var substringTerms: [Int] = []
    private var fuzzyTerms: [Int] = []

    init(terms: [CTerm]) {
        self.terms = terms
        for (i, t) in terms.enumerated() {
            if t.isWord { wordIndex[t.tokens[0], default: []].append(i) } else { substringTerms.append(i) }
            if t.fuzzy { fuzzyTerms.append(i) }
        }
    }

    /// Parse the data-file syntax: "=" whole word, "!" no fuzzy.
    static func compile(owner: String, display: String? = nil, kind: Evidence, raw: String) -> CTerm? {
        var text = raw
        var word = false
        var noFuzzy = false
        while let f = text.first, f == "=" || f == "!" {
            if f == "=" { word = true } else { noFuzzy = true }
            text.removeFirst()
        }
        let canon = Text.canon(text)
        guard !canon.isEmpty else { return nil }
        let isLatin = canon.allSatisfy { Text.isLatinAlnum($0) || $0 == " " }
        let tokens = Text.tokenize(canon).map(\.text)
        if word && (!isLatin || tokens.isEmpty) { word = false }
        let single = tokens.count == 1 && !canon.contains(" ")
        return CTerm(
            owner: owner, display: display ?? text, kind: kind, canon: canon,
            tokens: tokens, isWord: word,
            fuzzy: !noFuzzy && single && isLatin && canon.count >= 6)
    }

    private static func pluralEq(_ text: String, _ term: String) -> Bool {
        text == term || text == term + "s" || text == term + "es"
    }

    func hits(in t: PreparedText) -> [Hit] {
        var out: [Hit] = []
        for ti in substringTerms {
            let n = terms[ti].canon.count
            for s in Text.findAll(terms[ti].canon, in: t.fold) {
                out.append(Hit(term: ti, start: s, end: s + n, fuzzy: false))
            }
        }
        let toks = Text.tokenize(t.fold)
        for (i, tok) in toks.enumerated() {
            var keys = [tok.text]
            if tok.text.hasSuffix("es"), tok.text.count > 3 { keys.append(String(tok.text.dropLast(2))) }
            if tok.text.hasSuffix("s"), tok.text.count > 2 { keys.append(String(tok.text.dropLast())) }
            var seen = Set<Int>()
            for key in keys {
                for ti in wordIndex[key] ?? [] where seen.insert(ti).inserted {
                    let term = terms[ti]
                    let n = term.tokens.count
                    guard i + n <= toks.count else { continue }
                    var ok = true
                    for k in 0..<n {
                        let tt = toks[i + k].text
                        let match = k == n - 1 ? Self.pluralEq(tt, term.tokens[k]) : tt == term.tokens[k]
                        if !match { ok = false; break }
                        if k > 0 {
                            let gap = t.fold[toks[i + k - 1].end..<toks[i + k].start]
                            if !gap.allSatisfy({ $0 == " " }) { ok = false; break }
                        }
                    }
                    if ok { out.append(Hit(term: ti, start: tok.start, end: toks[i + n - 1].end, fuzzy: false)) }
                }
            }
        }
        // Fuzzy: the token resembles a term but is not it, so probably an OCR misread.
        for tok in toks where tok.scalars.count >= 6 {
            for ti in fuzzyTerms {
                let term = terms[ti]
                let d = term.canon.count >= 11 ? 2 : 1
                if abs(tok.scalars.count - term.canon.count) > d { continue }
                if tok.scalars == term.canon { continue }
                if Text.distance(tok.scalars, term.canon, maxDistance: d) <= d {
                    out.append(Hit(term: ti, start: tok.start, end: tok.end, fuzzy: true))
                }
            }
        }
        return out
    }
}
