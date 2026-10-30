import Foundation

/// Checks OCR text from food labels against profiles. All safety logic lives here.
public struct AllergenMatcher: Sendable {
    public let database: AllergenDatabase
    public var config: ReadQualityConfig

    /// Single Latin words from the database, used to prime OCR language correction.
    public let ocrVocabulary: [String]
    private let index: TermIndex
    private let resolved: [String: Set<String>]
    private let exclusions: [String: [Scalars]]
    private let advisory: [Scalars]
    private let contains: [Scalars]
    private let headers: [Scalars]
    private let freePrefix: [Scalars]
    private let freeSuffix: Set<String>
    private let unspecified: [(display: String, canon: Scalars)]

    private static let advisoryReach = 160
    private static let freePrefixReach = 50

    public init(database: AllergenDatabase, config: ReadQualityConfig = ReadQualityConfig()) {
        self.database = database
        self.config = config

        var terms: [CTerm] = []
        var closure: [String: Set<String>] = [:]
        let byId = Dictionary(uniqueKeysWithValues: database.allergens.map { ($0.id, $0) })
        func resolve(_ id: String, _ seen: inout Set<String>) {
            guard seen.insert(id).inserted, let a = byId[id] else { return }
            for parent in a.inherits ?? [] { resolve(parent, &seen) }
        }
        var excl: [String: [Scalars]] = [:]
        var vocab = Set<String>()
        for a in database.allergens {
            var seen = Set<String>()
            resolve(a.id, &seen)
            closure[a.id] = seen
            excl[a.id] = (a.exclusions ?? []).map(Text.canon)
            for (kind, table) in [(Evidence.direct, a.direct), (.derivative, a.derivative), (.ambiguous, a.ambiguous)] {
                for (_, list) in table ?? [:] {
                    for raw in list {
                        if let t = TermIndex.compile(owner: a.id, display: nil, kind: kind, raw: raw) {
                            terms.append(t)
                            if t.tokens.count == 1, t.display.unicodeScalars.allSatisfy({ $0.isASCII }) { vocab.insert(t.display) }
                        }
                    }
                }
            }
        }
        self.index = TermIndex(terms: terms)
        self.ocrVocabulary = vocab.sorted()
        self.resolved = closure
        self.exclusions = excl
        let p = database.phrases
        self.advisory = p.advisory.map(Text.canon)
        self.contains = p.contains.map(Text.canon)
        self.headers = p.headers.map(Text.canon)
        self.freePrefix = p.freePrefix.map(Text.canon)
        self.freeSuffix = Set(p.freeSuffix.map { Text.fold(Text.normalize($0)) })
        self.unspecified = p.unspecifiedSource.map { ($0, Text.canon($0)) }
    }

    public static func bundled(config: ReadQualityConfig = ReadQualityConfig()) throws -> AllergenMatcher {
        AllergenMatcher(database: try AllergenDatabase.bundled(), config: config)
    }

    // MARK: - Public API

    public func check(captures: [Capture], profiles: [Profile]) -> ScanResult {
        // Free-text entries get their own small index.
        var custom: [CTerm] = []
        for p in profiles {
            for e in p.entries where database.allergen(e.allergenId) == nil {
                let text = e.allergenId.hasPrefix("custom:") ? String(e.allergenId.dropFirst(7)) : e.allergenId
                if let t = TermIndex.compile(owner: e.allergenId, display: text, kind: .direct, raw: "=" + text) {
                    custom.append(t)
                }
            }
        }
        let customIndex = TermIndex(terms: custom)

        var matches: [Match] = []
        var notes: [ScanNote] = []
        var assessments: [Quality.CaptureAssessment] = []
        for capture in captures {
            assessments.append(Quality.assess(capture, config: config, hasHeader: hasHeader))
            for variant in capture.variants {
                for text in PreparedText.variants(of: variant) {
                    matches += scan(text, with: index)
                    if !custom.isEmpty { matches += scan(text, with: customIndex) }
                    for n in unspecified where !Text.findAll(n.canon, in: text.fold).isEmpty {
                        let note = ScanNote(text: n.display)
                        if !notes.contains(note) { notes.append(note) }
                    }
                }
            }
        }
        let quality = Quality.combine(assessments)

        var results: [ProfileResult] = profiles.map { profile in
            var alerts: [EntryAlert] = []
            for entry in profile.entries {
                let owners = resolved[entry.allergenId] ?? [entry.allergenId]
                var ms = matches.filter { owners.contains($0.allergenId) }
                guard !ms.isEmpty else { continue }
                ms = Self.dedupe(ms)
                let level = ms.map {
                    AlertLevel.level(for: entry.sensitivity, evidence: $0.evidence, strictAdvisory: entry.strictAdvisory)
                }.max() ?? .notice
                alerts.append(EntryAlert(entry: entry, level: level, matches: ms))
            }
            alerts.sort { $0.level > $1.level }
            let verdict: ProfileVerdict
            if let top = alerts.first {
                verdict = .matchesFound(top.level)
            } else {
                verdict = quality.isReliable ? .noMatchesFound : .cannotVerify
            }
            return ProfileResult(
                profile: profile, verdict: verdict, alerts: alerts,
                mayBeMore: !alerts.isEmpty && !quality.isReliable)
        }
        results.sort {
            $0.verdict.rank != $1.verdict.rank
                ? $0.verdict.rank > $1.verdict.rank
                : $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending
        }
        return ScanResult(profiles: results, readQuality: quality, notes: notes)
    }

    /// Why one capture may be unreliable, for immediate "retake" feedback.
    /// A missing ingredients header is not reported: panels without a list are normal.
    public func readIssues(for capture: Capture) -> Set<ReadIssue> {
        Quality.assess(capture, config: config, hasHeader: hasHeader).issues
    }

    public func check(texts: [String], profiles: [Profile], confidence: Float = 1) -> ScanResult {
        check(captures: [Capture(texts: texts, confidence: confidence)], profiles: profiles)
    }

    // MARK: - Scanning one prepared text

    private func hasHeader(_ s: String) -> Bool {
        let fold = Array(Text.fold(Text.normalize(s)).unicodeScalars)
        return headers.contains { !Text.findAll($0, in: fold).isEmpty }
    }

    private func scan(_ t: PreparedText, with idx: TermIndex) -> [Match] {
        let raw = idx.hits(in: t)
        guard !raw.isEmpty else { return [] }

        let exact = raw.filter { !$0.fuzzy }
        // A fuzzy hit that overlaps an exact hit for the same allergen adds nothing.
        let hits = raw.filter { h in
            !h.fuzzy || !exact.contains {
                idx.terms[$0.term].owner == idx.terms[h.term].owner && $0.start < h.end && h.start < $0.end
            }
        }

        let ctx = Context(text: t, matcher: self)
        var out: [Match] = []
        for h in hits {
            let term = idx.terms[h.term]
            if ctx.isExcluded(owner: term.owner, start: h.start, end: h.end) { continue }
            var ev = term.kind
            let inAdvisory = ctx.inAdvisory(h.start)
            if ctx.isFreeClaim(start: h.start, end: h.end) {
                // The more cautious reading wins if both apply.
                ev = inAdvisory ? .advisory : .freeClaim
            } else if inAdvisory {
                ev = .advisory
            }
            out.append(Match(
                allergenId: term.owner,
                allergenName: database.allergen(term.owner)?.name ?? term.display,
                matchedText: Text.string(t.norm[h.start..<h.end]),
                evidence: ev,
                isFuzzy: h.fuzzy,
                lineIndex: t.lineIndex(at: h.start)))
        }
        return out
    }

    private static func dedupe(_ ms: [Match]) -> [Match] {
        var seen = Set<String>()
        var out: [Match] = []
        let sorted = ms.sorted {
            if $0.evidence != $1.evidence { return $0.evidence > $1.evidence }
            if $0.isFuzzy != $1.isFuzzy { return !$0.isFuzzy }
            return $0.matchedText < $1.matchedText
        }
        for m in sorted where seen.insert("\(m.allergenId)|\(m.matchedText)|\(m.evidence.rawValue)|\(m.isFuzzy)").inserted {
            out.append(m)
        }
        return out
    }

    // MARK: - Context

    private struct Context {
        let t: PreparedText
        var advisoryRanges: [Range<Int>] = []
        var exclusionRanges: [String: [Range<Int>]] = [:]
        let freePrefix: [Scalars]
        let freeSuffix: Set<String>

        init(text: PreparedText, matcher m: AllergenMatcher) {
            t = text
            freePrefix = m.freePrefix
            freeSuffix = m.freeSuffix
            let f = text.fold
            for phrase in m.advisory {
                for s in Text.findAll(phrase, in: f) {
                    let e = s + phrase.count
                    var end = min(e + AllergenMatcher.advisoryReach, f.count)
                    // Stop at the end of the sentence, a "contains" statement or an ingredients header.
                    if let stop = f[e..<end].firstIndex(where: { $0 == "." || $0 == ";" }) { end = min(end, stop) }
                    for boundary in m.contains + m.headers {
                        for b in Text.findAll(boundary, in: f, from: e, limit: end) where Self.wordStart(f, b) {
                            end = min(end, b)
                        }
                    }
                    if end > e { advisoryRanges.append(e..<end) }
                }
            }
            for (owner, list) in m.exclusions {
                for phrase in list {
                    for s in Text.findAll(phrase, in: f) {
                        exclusionRanges[owner, default: []].append(s..<(s + phrase.count))
                    }
                }
            }
        }

        static func wordStart(_ f: Scalars, _ i: Int) -> Bool {
            i == 0 || !Text.isLatinAlnum(f[i - 1])
        }

        func inAdvisory(_ offset: Int) -> Bool { advisoryRanges.contains { $0.contains(offset) } }

        func isExcluded(owner: String, start: Int, end: Int) -> Bool {
            (exclusionRanges[owner] ?? []).contains { $0.lowerBound <= start && end <= $0.upperBound }
        }

        /// "X free" directly after the term, or "free from X, Y and Z" directly before it.
        func isFreeClaim(start: Int, end: Int) -> Bool {
            let f = t.fold
            var i = end
            while i < f.count, f[i] == " " { i += 1 }
            var j = i
            while j < f.count, Text.isLatinAlnum(f[j]) { j += 1 }
            if j > i, freeSuffix.contains(Text.string(f[i..<j])) { return true }

            // Prefix: nearest "free from"-style phrase before the term, in the same sentence.
            var segStart = start
            while segStart > 0, f[segStart - 1] != ".", f[segStart - 1] != ";" { segStart -= 1 }
            var best: Int?
            for phrase in freePrefix {
                for s in Text.findAll(phrase, in: f, from: segStart, limit: start) {
                    let e = s + phrase.count
                    guard Self.wordStart(f, s), e <= start, e == f.count || !Text.isLatinAlnum(f[e]) else { continue }
                    if best == nil || e > best! { best = e }
                }
            }
            guard let e = best, start - e <= AllergenMatcher.freePrefixReach else { return false }
            let gap = f[e..<start]
            // Only a plain list of words may sit between the phrase and the term.
            guard gap.allSatisfy({ Text.isLatinAlnum($0) && !$0.properties.numericType.isSome || $0 == " " || $0 == "," }) else {
                return false
            }
            let gapText = Text.string(gap)
            return !["contaln", "may", "lngredlent"].contains { gapText.contains($0) }
        }
    }
}

private extension Optional {
    var isSome: Bool { self != nil }
}
