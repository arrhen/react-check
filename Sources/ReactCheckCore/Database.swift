import Foundation

/// The allergen knowledge base. Source of truth is `allergens.json` and `phrases.json`.
public struct AllergenDatabase: Codable, Sendable {
    public struct Allergen: Codable, Sendable, Identifiable {
        public var id: String
        public var name: String
        public var inherits: [String]?
        public var exclusions: [String]?
        public var direct: [String: [String]]?
        public var derivative: [String: [String]]?
        public var ambiguous: [String: [String]]?
    }

    public struct Phrases: Codable, Sendable {
        public var advisory: [String]
        public var contains: [String]
        public var headers: [String]
        public var freePrefix: [String]
        public var freeSuffix: [String]
        public var unspecifiedSource: [String]
    }

    public var allergens: [Allergen]
    public var phrases: Phrases

    private struct File: Codable { var allergens: [Allergen] }

    public static func bundled() throws -> AllergenDatabase {
        func load(_ name: String) throws -> Data {
            guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try Data(contentsOf: url)
        }
        let dec = JSONDecoder()
        let file = try dec.decode(File.self, from: load("allergens"))
        let phrases = try dec.decode(Phrases.self, from: load("phrases"))
        return AllergenDatabase(allergens: file.allergens, phrases: phrases)
    }

    public func allergen(_ id: String) -> Allergen? { allergens.first { $0.id == id } }
}
