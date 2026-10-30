import AVFoundation
import PhotosUI
import ReactCheckCore
import SwiftUI
import VisionKit

/// One photo with its OCR already done, so a bad one can be flagged and retaken straight away.
struct Shot: Identifiable {
    let id = UUID()
    let image: UIImage
    let capture: Capture
    let issues: Set<ReadIssue>
    var isClear: Bool { issues.isEmpty }
}

struct ResultBox: Identifiable {
    let id = UUID()
    let result: ScanResult
}

struct ScanView: View {
    @Environment(ProfileStore.self) private var store
    @State private var shots: [Shot] = []
    @State private var excluded: Set<UUID> = []
    @State private var showCamera = false
    @State private var showDocumentScanner = false
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
                    if LiveCamera.isAvailable {
                        Button { showCamera = true } label: { Label("Scan with camera", systemImage: "camera.viewfinder") }
                    } else if DocumentScanner.isSupported {
                        Button { showDocumentScanner = true } label: { Label("Scan with camera", systemImage: "camera.viewfinder") }
                    }
                    if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: { Label("Camera is off. Open Settings to allow it.", systemImage: "gearshape") }
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
                if !shots.isEmpty {
                    Section("\(shots.count) \(shots.count == 1 ? "photo" : "photos") ready") {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(shots) { shot in ShotThumb(shot: shot) { shots.removeAll { $0.id == shot.id } } }
                            }
                            .padding(.vertical, 4)
                        }
                        if shots.contains(where: { !$0.isClear }) {
                            Label("Some photos are unclear. Remove them and retake, or the result may say it couldn't read the label.",
                                  systemImage: "exclamationmark.triangle").font(.footnote)
                        }
                        Button("Clear all photos", role: .destructive) { shots = [] }
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
            .fullScreenCover(isPresented: $showCamera) {
                LiveScannerView(onPhoto: { image in await add(image) }, onDone: { showCamera = false }, count: shots.count)
            }
            .sheet(isPresented: $showDocumentScanner) {
                DocumentScanner { images in
                    showDocumentScanner = false
                    Task { for image in images { _ = await add(image) } }
                } onCancel: { showDocumentScanner = false }
                    .ignoresSafeArea()
            }
            .sheet(item: $box) { ResultView(result: $0.result) }
            .onChange(of: pickerItems) { _, items in Task { await load(items) } }
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { _ = await add(img) }
        }
        pickerItems = []
    }

    /// Reads a photo right away and returns a short status for the camera view.
    private func add(_ image: UIImage) async -> String {
        guard let matcher else { return "Scanning is unavailable." }
        do {
            let capture = try await OCR.capture(from: image, vocabulary: matcher.ocrVocabulary)
            let shot = Shot(image: image, capture: capture, issues: matcher.readIssues(for: capture))
            shots.append(shot)
            return shot.isClear ? "Clear. Take more, or tap Done." : "Unclear. Hold steady and retake."
        } catch {
            return "Couldn't read that photo. Try again."
        }
    }

    private func check() async {
        guard let matcher else { return }
        working = true
        errorMessage = nil
        defer { working = false }
        box = ResultBox(result: matcher.check(captures: shots.map(\.capture), profiles: chosen))
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

struct ShotThumb: View {
    let shot: Shot
    var onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: shot.image).resizable().scaledToFill()
                .frame(width: 80, height: 100).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: shot.isClear ? "text.viewfinder" : "exclamationmark.triangle.fill")
                        .font(.caption).padding(4)
                        .background(shot.isClear ? Color.teal : Color.orange, in: Circle())
                        .foregroundStyle(.white).padding(4)
                }
                .accessibilityLabel(shot.isClear ? "Photo, text found" : "Photo, unclear")
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6)) }
                .accessibilityLabel("Remove photo")
                .padding(2)
        }
    }
}
