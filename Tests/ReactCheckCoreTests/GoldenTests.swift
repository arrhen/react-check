import XCTest
@testable import ReactCheckCore

struct GoldenFile: Decodable {
    struct Capture: Decodable { var lines: [String]; var confidence: Float }
    struct ProfileSpec: Decodable { var name: String; var entries: [[String]] }
    struct Expect: Decodable {
        var verdict: String?
        var entries: [String: String]?
        var fuzzy: [String]?
        var mayBeMore: Bool?
    }
    struct Case: Decodable {
        var name: String
        var captures: [Capture]
        var profiles: [ProfileSpec]
        var expect: [String: Expect?]
        var notes: [String]?
    }
    var cases: [Case]
}

func loadGolden() throws -> [GoldenFile.Case] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "Golden"))
    // "_notes" lives beside the profile keys in "expect"; pull it out before decoding.
    var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var cases = try XCTUnwrap(raw["cases"] as? [[String: Any]])
    var notes: [Int: [String]] = [:]
    for i in cases.indices {
        var expect = cases[i]["expect"] as? [String: Any] ?? [:]
        if let n = expect.removeValue(forKey: "_notes") as? [String] { notes[i] = n }
        cases[i]["expect"] = expect
    }
    raw["cases"] = cases
    var decoded = try JSONDecoder().decode(GoldenFile.self, from: JSONSerialization.data(withJSONObject: raw)).cases
    for (i, n) in notes { decoded[i].notes = n }
    return decoded
}

func makeProfiles(_ specs: [GoldenFile.ProfileSpec]) -> [Profile] {
    specs.map { spec in
        Profile(name: spec.name, entries: spec.entries.map {
            AllergenEntry(allergenId: $0[0], sensitivity: Sensitivity(rawValue: $0[1])!, strictAdvisory: $0.contains("strict"))
        })
    }
}

func describe(_ v: ProfileVerdict) -> String {
    switch v {
    case .matchesFound(let l): return "match:\(l)"
    case .cannotVerify: return "cannotVerify"
    case .noMatchesFound: return "noMatches"
    }
}

func evidenceName(_ e: Evidence) -> String {
    switch e {
    case .direct: return "direct"
    case .derivative: return "derivative"
    case .ambiguous: return "ambiguous"
    case .advisory: return "advisory"
    case .freeClaim: return "freeClaim"
    }
}

final class GoldenTests: XCTestCase {
    let matcher = try! AllergenMatcher.bundled()

    func run(_ c: GoldenFile.Case, captureSubset: [GoldenFile.Capture]? = nil) -> ScanResult {
        let captures = (captureSubset ?? c.captures).map { Capture(texts: $0.lines, confidence: $0.confidence) }
        return matcher.check(captures: captures, profiles: makeProfiles(c.profiles))
    }

    func testGoldenCases() throws {
        let cases = try loadGolden()
        XCTAssertGreaterThan(cases.count, 50)
        var failures: [String] = []
        for c in cases {
            let result = run(c)
            for (name, maybeExpect) in c.expect {
                guard let expect = maybeExpect, let pr = result.profiles.first(where: { $0.profile.name == name }) else {
                    failures.append("[\(c.name)] no result for profile \(name)"); continue
                }
                if let v = expect.verdict, describe(pr.verdict) != v {
                    failures.append("[\(c.name)] \(name): verdict \(describe(pr.verdict)), expected \(v)")
                }
                if let mb = expect.mayBeMore, pr.mayBeMore != mb {
                    failures.append("[\(c.name)] \(name): mayBeMore \(pr.mayBeMore), expected \(mb)")
                }
                for (id, ev) in expect.entries ?? [:] {
                    guard let alert = pr.alerts.first(where: { $0.entry.allergenId == id }) else {
                        failures.append("[\(c.name)] \(name): no alert for \(id)"); continue
                    }
                    let top = evidenceName(alert.matches[0].evidence)
                    if top != ev { failures.append("[\(c.name)] \(name): \(id) evidence \(top), expected \(ev)") }
                }
                for id in expect.fuzzy ?? [] {
                    if pr.alerts.first(where: { $0.entry.allergenId == id })?.matches.first?.isFuzzy != true {
                        failures.append("[\(c.name)] \(name): \(id) expected a fuzzy top match")
                    }
                }
            }
            for n in c.notes ?? [] where !result.notes.contains(where: { $0.text == n }) {
                failures.append("[\(c.name)] missing note \(n)")
            }
            // Profiles must come back worst first.
            let ranks = result.profiles.map(\.verdict.rank)
            if ranks != ranks.sorted(by: >) { failures.append("[\(c.name)] profiles not ordered worst first") }
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }

    /// SPEC principle 3: more input never lowers the result for any profile.
    func testUnionNeverSubtracts() throws {
        var failures: [String] = []
        for c in try loadGolden() {
            let profiles = makeProfiles(c.profiles)
            // Split every capture's lines into two captures, then compare against each half and the whole.
            var halves: [[GoldenFile.Capture]] = [[], []]
            for cap in c.captures {
                let mid = max(1, cap.lines.count / 2)
                halves[0].append(.init(lines: Array(cap.lines.prefix(mid)), confidence: cap.confidence))
                if cap.lines.count > mid {
                    halves[1].append(.init(lines: Array(cap.lines.dropFirst(mid)), confidence: cap.confidence))
                }
            }
            let whole = run(c)
            for half in halves where !half.isEmpty {
                let part = run(c, captureSubset: half)
                for p in profiles {
                    func level(_ r: ScanResult) -> Int {
                        guard let pr = r.profiles.first(where: { $0.profile.id == p.id }),
                              case .matchesFound(let l) = pr.verdict else { return -1 }
                        return l.rawValue
                    }
                    if level(whole) < level(part) {
                        failures.append("[\(c.name)] \(p.name): combined level \(level(whole)) < part \(level(part))")
                    }
                }
            }
            // Adding an unrelated extra capture must not change any matched level either.
            let extra = GoldenFile.Capture(lines: ["Ingredients: Rice, Water, Salt, Sugar, Vinegar"], confidence: 0.95)
            let plus = run(c, captureSubset: c.captures + [extra])
            for p in profiles {
                func level(_ r: ScanResult) -> Int {
                    guard let pr = r.profiles.first(where: { $0.profile.id == p.id }),
                          case .matchesFound(let l) = pr.verdict else { return -1 }
                    return l.rawValue
                }
                if level(plus) < level(whole) { failures.append("[\(c.name)] \(p.name): extra capture lowered the level") }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\n" + failures.joined(separator: "\n"))
    }
}

final class UnitTests: XCTestCase {
    func testLevelTable() {
        typealias L = AlertLevel
        let table: [(Sensitivity, Evidence, L)] = [
            (.severe, .direct, .critical), (.severe, .advisory, .critical), (.severe, .ambiguous, .critical),
            (.moderate, .direct, .warning), (.moderate, .derivative, .warning), (.moderate, .ambiguous, .warning),
            (.moderate, .advisory, .caution),
            (.mild, .direct, .caution), (.mild, .derivative, .caution), (.mild, .ambiguous, .notice), (.mild, .advisory, .notice),
            (.intolerance, .direct, .caution), (.intolerance, .advisory, .notice),
        ]
        for (s, e, expected) in table {
            XCTAssertEqual(L.level(for: s, evidence: e, strictAdvisory: false), expected, "\(s) \(e)")
        }
        for s in Sensitivity.allCases {
            XCTAssertEqual(L.level(for: s, evidence: .freeClaim, strictAdvisory: false), .notice)
        }
    }

    func testHeadlines() throws {
        let m = try AllergenMatcher.bundled()
        let kid = Profile(name: "Mia", entries: [.init(allergenId: "peanut", sensitivity: .severe)])
        let r = m.check(texts: ["Ingredients: sugar, peanuts, water, salt"], profiles: [kid])
        XCTAssertEqual(r.profiles[0].alerts[0].headline(for: "Mia"), "CRITICAL - SEVERE ALLERGEN FOR MIA")
    }

    func testEveryDatabaseTermCompilesAndInheritsResolve() throws {
        let db = try AllergenDatabase.bundled()
        let ids = Set(db.allergens.map(\.id))
        XCTAssertEqual(ids.count, db.allergens.count, "duplicate allergen ids")
        for a in db.allergens {
            for parent in a.inherits ?? [] { XCTAssertTrue(ids.contains(parent), "\(a.id) inherits unknown \(parent)") }
            for table in [a.direct, a.derivative, a.ambiguous] {
                for (_, list) in table ?? [:] {
                    for raw in list {
                        XCTAssertNotNil(TermIndex.compile(owner: a.id, kind: .direct, raw: raw), "\(a.id): \(raw)")
                    }
                }
            }
        }
    }

    /// Every direct English name must hit its own allergen, so a typo in the data cannot silently disable a term.
    func testEveryEnglishDirectTermMatchesItself() throws {
        let m = try AllergenMatcher.bundled()
        var failures: [String] = []
        for a in m.database.allergens {
            for raw in a.direct?["en"] ?? [] {
                let word = raw.trimmingCharacters(in: CharacterSet(charactersIn: "=!~"))
                let r = m.check(
                    texts: ["Ingredients: sugar, \(word), water, salt"],
                    profiles: [Profile(name: "T", entries: [.init(allergenId: a.id, sensitivity: .severe)])])
                if case .matchesFound = r.profiles[0].verdict { continue }
                // Excluded-on-purpose phrases such as "soy milk" are not in the direct lists, so any miss is a bug.
                failures.append("\(a.id): \(word)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testEmptyInputIsNeverAllClear() throws {
        let m = try AllergenMatcher.bundled()
        let p = Profile(name: "T", entries: [.init(allergenId: "milk", sensitivity: .severe)])
        XCTAssertEqual(m.check(captures: [], profiles: [p]).profiles[0].verdict, .cannotVerify)
        XCTAssertEqual(m.check(texts: [], profiles: [p]).profiles[0].verdict, .cannotVerify)
    }
}
