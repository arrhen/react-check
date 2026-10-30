import PhotosUI
import ReactCheckCore
import SwiftUI
import VisionKit

struct ResultBox: Identifiable {
    let id = UUID()
    let result: ScanResult
}

struct ScanView: View {
    @Environment(ProfileStore.self) private var store
    @State private var images: [UIImage] = []
    @State private var excluded: Set<UUID> = []
    @State private var showCamera = false
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var working = false
    @State private var box: ResultBox?
    @State private var errorMessage: String?

    private let matcher = try? AllergenMatcher.bundled()

    private var chosen: [Profile] { store.profiles.filter { !excluded.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Form {
                if matcher == nil {
                    Section {
                        Label("The allergen list could not be loaded. Scanning is turned off. Read the label yourself.",
                              systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                Section("Who is this for?") {
                    if store.profiles.isEmpty {
                        Text("Add people on the People tab first.").foregroundStyle(.secondary)
                    }
                    ForEach(store.profiles) { p in
                        Toggle(p.name, isOn: Binding(
                            get: { !excluded.contains(p.id) },
                            set: { on in if on { excluded.remove(p.id) } else { excluded.insert(p.id) } }))
                    }
                }
                Section {
                    if DocumentScanner.isSupported {
                        Button { showCamera = true } label: { Label("Scan with camera", systemImage: "camera.viewfinder") }
                    }
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 8, matching: .images) {
                        Label("Choose photos", systemImage: "photo.on.rectangle")
                    }
                    #if DEBUG
                    Button { runSample() } label: { Label("Try a sample label", systemImage: "testtube.2") }
                    #endif
                } header: {
                    Text("Ingredients label")
                } footer: {
                    Text("Scan every part of the pack that has writing: the ingredients list, any \"contains\" or \"may contain\" line, and stickers. Hold steady, avoid glare.")
                }
                if !images.isEmpty {
                    Section("\(images.count) \(images.count == 1 ? "photo" : "photos") ready") {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                                    Image(uiImage: img).resizable().scaledToFill()
                                        .frame(width: 80, height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        Button("Clear photos", role: .destructive) { images = [] }
                    }
                    Section {
                        Button {
                            Task { await check() }
                        } label: {
                            HStack { Spacer(); if working { ProgressView() } else { Text("Check label").bold() }; Spacer() }
                        }
                        .disabled(working || chosen.isEmpty || matcher == nil)
                    }
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "questionmark.diamond.fill").foregroundStyle(.purple) }
                }
            }
            .navigationTitle("React Check")
            .sheet(isPresented: $showCamera) {
                DocumentScanner { images += $0; showCamera = false } onCancel: { showCamera = false }
                    .ignoresSafeArea()
            }
            .sheet(item: $box) { ResultView(result: $0.result) }
            .onChange(of: pickerItems) { _, items in Task { await load(items) } }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        var loaded: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { loaded.append(img) }
        }
        images += loaded
        pickerItems = []
    }

    private func check() async {
        guard let matcher else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            var captures: [Capture] = []
            for image in images { captures.append(try await OCR.capture(from: image, vocabulary: matcher.ocrVocabulary)) }
            box = ResultBox(result: matcher.check(captures: captures, profiles: chosen))
        } catch {
            // Fail safe: a failed read is never shown as a result.
            errorMessage = "Couldn't read the photos. Please check the label yourself."
        }
    }

    #if DEBUG
    private func runSample() {
        guard let matcher else { return }
        box = ResultBox(result: matcher.check(
            texts: ["INGREDIENTS: Sugar, Wheat Flour, Whole Milk, Soy Lecithin, Salt.", "May contain traces of peanuts. Made in a facility that also processes tree nuts."],
            profiles: chosen, confidence: 0.95))
    }
    #endif
}
