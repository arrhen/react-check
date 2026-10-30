import Foundation

/// How strongly a person reacts. Drives the alert level.
public enum Sensitivity: String, Codable, CaseIterable, Sendable {
    case severe, moderate, mild, intolerance
}

/// One allergen or intolerance on a profile. `allergenId` is a key in `allergens.json`
/// or `custom:<text>` for a free-text entry.
public struct AllergenEntry: Codable, Hashable, Sendable, Identifiable {
    public var allergenId: String
    public var sensitivity: Sensitivity
    /// Treat "may contain" and facility statements exactly like a direct hit.
    public var strictAdvisory: Bool

    public var id: String { allergenId }

    public init(allergenId: String, sensitivity: Sensitivity, strictAdvisory: Bool = false) {
        self.allergenId = allergenId
        self.sensitivity = sensitivity
        self.strictAdvisory = strictAdvisory
    }
}

public struct Profile: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var entries: [AllergenEntry]

    public init(id: UUID = UUID(), name: String, entries: [AllergenEntry]) {
        self.id = id
        self.name = name
        self.entries = entries
    }
}

/// What kind of text produced a match, strongest first.
public enum Evidence: Int, Comparable, Codable, Sendable {
    case freeClaim = 0
    case advisory
    case ambiguous
    case derivative
    case direct

    public static func < (a: Evidence, b: Evidence) -> Bool { a.rawValue < b.rawValue }
}

public enum AlertLevel: Int, Comparable, Codable, Sendable {
    case notice = 0, caution, warning, critical

    public static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }

    /// The SPEC section 4 table.
    public static func level(for sensitivity: Sensitivity, evidence: Evidence, strictAdvisory: Bool) -> AlertLevel {
        let ev = (evidence == .advisory && strictAdvisory) ? Evidence.direct : evidence
        if ev == .freeClaim { return .notice }
        switch sensitivity {
        case .severe:
            return .critical
        case .moderate:
            return ev == .advisory ? .caution : .warning
        case .mild, .intolerance:
            return (ev == .direct || ev == .derivative) ? .caution : .notice
        }
    }
}

public struct OCRLine: Hashable, Sendable {
    public var text: String
    /// 0...1, as reported by the OCR engine.
    public var confidence: Float

    public init(text: String, confidence: Float = 1) {
        self.text = text
        self.confidence = confidence
    }
}

/// One photo or document page. `variants` are alternative OCR passes over the same image
/// (for example language correction on and off). Their matches are unioned.
public struct Capture: Sendable {
    public var variants: [[OCRLine]]

    public init(variants: [[OCRLine]]) { self.variants = variants }
    public init(lines: [OCRLine]) { self.variants = [lines] }
    public init(texts: [String], confidence: Float = 1) {
        self.variants = [texts.map { OCRLine(text: $0, confidence: confidence) }]
    }
}

public struct Match: Hashable, Sendable {
    /// The allergen that owns the matched term, for example `milk` for "casein".
    public var allergenId: String
    public var allergenName: String
    /// Normalised text as found on the label.
    public var matchedText: String
    public var evidence: Evidence
    /// True when the label text only resembles the term (probable OCR misread).
    public var isFuzzy: Bool
    /// Index into the OCR lines of the variant it came from, when known.
    public var lineIndex: Int?
}

public struct EntryAlert: Hashable, Sendable {
    public var entry: AllergenEntry
    public var level: AlertLevel
    /// Strongest evidence first.
    public var matches: [Match]
}

public enum ProfileVerdict: Hashable, Sendable {
    case matchesFound(AlertLevel)
    /// Nothing matched but the read was not good enough to say so.
    case cannotVerify
    /// A good read of a full list found nothing. Never "safe".
    case noMatchesFound

    /// Higher is worse. Used to order profiles and pick the banner.
    public var rank: Int {
        switch self {
        case .matchesFound(let l):
            switch l {
            case .critical: return 6
            case .warning: return 5
            case .caution: return 3
            case .notice: return 2
            }
        case .cannotVerify: return 4
        case .noMatchesFound: return 1
        }
    }
}

public struct ProfileResult: Hashable, Sendable, Identifiable {
    public var profile: Profile
    public var verdict: ProfileVerdict
    public var alerts: [EntryAlert]
    /// The read was unreliable, so there may be matches the scan could not see.
    public var mayBeMore: Bool

    public var id: UUID { profile.id }
}

public struct ScanNote: Hashable, Sendable {
    /// For example "natural flavors" or "spices": the source is not always listed.
    public var text: String
}

public struct ScanResult: Sendable {
    /// Worst first.
    public var profiles: [ProfileResult]
    public var readQuality: ReadQuality
    public var notes: [ScanNote]

    public var overall: ProfileVerdict {
        profiles.map(\.verdict).max { $0.rank < $1.rank } ?? (readQuality.isReliable ? .noMatchesFound : .cannotVerify)
    }
}

extension EntryAlert {
    /// Headline in the style: "CRITICAL - SEVERE ALLERGEN FOR NAME".
    public func headline(for profileName: String) -> String {
        let kind: String
        switch entry.sensitivity {
        case .severe: kind = "severe allergen"
        case .moderate: kind = "moderate allergen"
        case .mild: kind = "mild allergen"
        case .intolerance: kind = "intolerance"
        }
        switch level {
        case .critical: return "CRITICAL - SEVERE ALLERGEN FOR \(profileName.uppercased())"
        case .warning: return "Warning - \(kind) for \(profileName)"
        case .caution: return "Caution - \(kind) for \(profileName)"
        case .notice: return "Notice - possible \(kind) for \(profileName)"
        }
    }
}
