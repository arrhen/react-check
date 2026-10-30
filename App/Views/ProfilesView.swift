import ReactCheckCore
import SwiftUI

struct ProfilesView: View {
    @Environment(ProfileStore.self) private var store
    @State private var editing: Profile?

    var body: some View {
        NavigationStack {
            List {
                if let error = store.loadError {
                    Text(error).foregroundStyle(.red)
                }
                if store.profiles.isEmpty {
                    ContentUnavailableView(
                        "No one added yet", systemImage: "person.badge.plus",
                        description: Text("Add each person you check labels for, with their allergies and intolerances."))
                }
                ForEach(store.profiles) { profile in
                    Button { editing = profile } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).font(.headline)
                            Text(summary(profile)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete(perform: store.delete)
            }
            .navigationTitle("People")
            .toolbar {
                Button { editing = Profile(name: "", entries: []) } label: { Label("Add person", systemImage: "plus") }
            }
            .sheet(item: $editing) { profile in
                EditProfileView(profile: profile) { store.upsert($0) }
            }
        }
    }

    private func summary(_ p: Profile) -> String {
        p.entries.isEmpty ? "Nothing set yet" : p.entries.map { AllergenCatalog.name(for: $0.allergenId) }.joined(separator: ", ")
    }
}

enum AllergenCatalog {
    static let database = try? AllergenDatabase.bundled()

    static var all: [(id: String, name: String)] {
        (database?.allergens ?? []).map { ($0.id, $0.name) }.sorted { $0.name < $1.name }
    }

    static func name(for id: String) -> String {
        if id.hasPrefix("custom:") { return String(id.dropFirst(7)) }
        return database?.allergen(id)?.name ?? id
    }
}

extension Sensitivity {
    var label: String {
        switch self {
        case .severe: return "Severe allergy"
        case .moderate: return "Moderate allergy"
        case .mild: return "Mild allergy"
        case .intolerance: return "Intolerance"
        }
    }
}

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    var onSave: (Profile) -> Void

    @State private var addingId = ""
    @State private var customText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $profile.name).textContentType(.givenName)
                }
                Section("Allergies and intolerances") {
                    ForEach($profile.entries) { $entry in
                        VStack(alignment: .leading) {
                            Text(AllergenCatalog.name(for: entry.allergenId)).font(.headline)
                            Picker("Reaction", selection: $entry.sensitivity) {
                                ForEach(Sensitivity.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu)
                            Toggle("Treat \"may contain\" like a direct match", isOn: $entry.strictAdvisory)
                                .font(.subheadline)
                        }
                    }
                    .onDelete { profile.entries.remove(atOffsets: $0) }

                    Picker("Add", selection: $addingId) {
                        Text("Choose…").tag("")
                        ForEach(AllergenCatalog.all.filter { a in !profile.entries.contains { $0.allergenId == a.id } }, id: \.id) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    .onChange(of: addingId) { _, id in
                        guard !id.isEmpty else { return }
                        profile.entries.append(.init(allergenId: id, sensitivity: .severe))
                        addingId = ""
                    }
                    HStack {
                        TextField("Something else (for example kiwi)", text: $customText)
                        Button("Add") {
                            let t = customText.trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            profile.entries.append(.init(allergenId: "custom:\(t.lowercased())", sensitivity: .severe))
                            customText = ""
                        }
                        .disabled(customText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section {
                    Text("Dairy intolerance: choose Lactose (milk sugar) with Intolerance. It also flags milk, cheese, whey and similar.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(profile.name.isEmpty ? "New person" : profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        profile.name = profile.name.trimmingCharacters(in: .whitespaces)
                        onSave(profile)
                        dismiss()
                    }
                    .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
