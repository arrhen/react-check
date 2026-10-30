import ReactCheckCore
import UIKit
import Vision

enum OCR {
    private static let preferred = ["en-US", "fr-FR", "es-ES", "de-DE", "it-IT", "pt-BR", "ja-JP", "zh-Hans", "ko-KR"]

    /// Reads one image twice, with and without language correction. The matcher unions the results,
    /// so a correction that rewrites an allergen word cannot hide it.
    static func capture(from image: UIImage, vocabulary: [String]) async throws -> Capture {
        guard let cg = image.cgImage else { return Capture(lines: []) }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return try await Task.detached(priority: .userInitiated) {
            var variants: [[OCRLine]] = []
            for correction in [false, true] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = correction
                if correction { request.customWords = vocabulary }
                if let supported = try? request.supportedRecognitionLanguages() {
                    let langs = preferred.filter(supported.contains)
                    if !langs.isEmpty { request.recognitionLanguages = langs }
                }
                try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request])
                let observations = (request.results ?? []).sorted {
                    // Top to bottom, then left to right.
                    abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                        ? $0.boundingBox.midY > $1.boundingBox.midY
                        : $0.boundingBox.minX < $1.boundingBox.minX
                }
                variants.append(observations.compactMap { obs in
                    obs.topCandidates(1).first.map { OCRLine(text: $0.string, confidence: $0.confidence) }
                })
            }
            return Capture(variants: variants)
        }.value
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
