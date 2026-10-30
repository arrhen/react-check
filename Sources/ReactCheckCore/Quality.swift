import Foundation

public enum ReadIssue: String, Hashable, Codable, Sendable {
    case tooLittleText
    case lowConfidence
    case garbled
    case noIngredientList
}

/// First-guess thresholds. They must be calibrated on real photos.
public struct ReadQualityConfig: Sendable {
    public var minLetters = 15
    public var minMeanConfidence: Float = 0.6
    public var lowConfidenceLine: Float = 0.5
    public var maxLowConfidenceFraction: Float = 0.3
    public var minAlphanumericRatio: Float = 0.5

    public init() {}
}

public struct ReadQuality: Hashable, Sendable {
    public var issues: Set<ReadIssue>
    public var isReliable: Bool { issues.isEmpty }
}

enum Quality {
    struct CaptureAssessment {
        var issues: Set<ReadIssue> = []
        var hasHeader = false
    }

    /// Assess one capture by its best variant.
    static func assess(
        _ capture: Capture,
        config: ReadQualityConfig,
        hasHeader: (String) -> Bool
    ) -> CaptureAssessment {
        var best: CaptureAssessment?
        var bestScore: Float = -1
        for variant in capture.variants {
            var a = CaptureAssessment()
            var letters = 0
            var weighted: Float = 0
            var lowChars = 0
            var allChars = 0
            var alnum = 0
            var nonSpace = 0
            for line in variant {
                let n = line.text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
                letters += n
                weighted += line.confidence * Float(n)
                allChars += n
                if line.confidence < config.lowConfidenceLine { lowChars += n }
                for sc in line.text.unicodeScalars where !sc.properties.isWhitespace {
                    nonSpace += 1
                    if sc.properties.isAlphabetic || sc.properties.numericType != nil { alnum += 1 }
                }
            }
            let mean = letters > 0 ? weighted / Float(letters) : 0
            if letters < config.minLetters {
                a.issues.insert(.tooLittleText)
            } else {
                if mean < config.minMeanConfidence
                    || Float(lowChars) / Float(max(allChars, 1)) > config.maxLowConfidenceFraction {
                    a.issues.insert(.lowConfidence)
                }
                if Float(alnum) / Float(max(nonSpace, 1)) < config.minAlphanumericRatio {
                    a.issues.insert(.garbled)
                }
            }
            a.hasHeader = hasHeader(variant.map(\.text).joined(separator: " "))
            // Best variant = most readable one; ties keep the first.
            let score = mean + (a.issues.isEmpty ? 1 : 0)
            if score > bestScore { best = a; bestScore = score }
        }
        var result = best ?? CaptureAssessment(issues: [.tooLittleText])
        // A header found in any variant counts, even if another variant scored better.
        if !result.hasHeader {
            result.hasHeader = capture.variants.contains { hasHeader($0.map(\.text).joined(separator: " ")) }
        }
        return result
    }

    static func combine(_ assessments: [CaptureAssessment]) -> ReadQuality {
        var issues = Set<ReadIssue>()
        if assessments.isEmpty { return ReadQuality(issues: [.tooLittleText]) }
        for a in assessments { issues.formUnion(a.issues) }
        if !assessments.contains(where: \.hasHeader) { issues.insert(.noIngredientList) }
        return ReadQuality(issues: issues)
    }
}
