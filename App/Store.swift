import Foundation
import Observation
import ReactCheckCore

/// Profiles live in a single JSON file on this device. Nothing is sent anywhere.
@Observable
@MainActor
final class ProfileStore {
    private(set) var profiles: [Profile] = []
    var loadError: String?

    private let url: URL

    init(url: URL? = nil) {
        let base = url ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))?
            .appendingPathComponent("profiles.json")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("profiles.json")
        self.url = base
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            profiles = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: url))
        } catch {
            // Never silently replace data we could not read.
            loadError = "Saved people could not be read. They have not been deleted."
        }
    }

    private func save() {
        guard loadError == nil else { return }
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            loadError = "Could not save changes: \(error.localizedDescription)"
        }
    }

    func upsert(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[i] = profile } else { profiles.append(profile) }
        save()
    }

    func delete(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    func delete(at offsets: IndexSet) {
        profiles.remove(atOffsets: offsets)
        save()
    }
}
