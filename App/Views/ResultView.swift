import ReactCheckCore
import SwiftUI
import UIKit

struct ResultView: View {
    let result: ScanResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(result.profiles) { ProfileCard(result: $0) }
                    if result.profiles.isEmpty {
                        Text("No one was selected.").foregroundStyle(.secondary)
                    }
                    if !result.readQuality.isReliable { ReadQualityNote(quality: result.readQuality) }
                    if !result.notes.isEmpty {
                        Label {
                            Text("The label lists \(result.notes.map { "\"\($0.text)\"" }.joined(separator: ", ")). The source of these is not always listed.")
                        } icon: { Image(systemName: "questionmark.circle") }
                        .font(.callout)
                    }
                    Text("React Check is an aid, not a guarantee. It can misread a label or miss ingredients. Always read the label yourself.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { haptic() }
        }
    }

    private func haptic() {
        let g = UINotificationFeedbackGenerator()
        switch result.overall {
        case .matchesFound(.critical): g.notificationOccurred(.error)
        case .matchesFound(.warning), .cannotVerify: g.notificationOccurred(.warning)
        default: break
        }
    }
}

struct Look {
    var symbol: String
    var color: Color
    var onColor: Color = .white

    static func of(_ level: AlertLevel) -> Look {
        switch level {
        case .critical: Look(symbol: "exclamationmark.octagon.fill", color: .red)
        case .warning: Look(symbol: "exclamationmark.triangle.fill", color: .orange, onColor: .black)
        case .caution: Look(symbol: "exclamationmark.circle.fill", color: .yellow, onColor: .black)
        case .notice: Look(symbol: "info.circle.fill", color: .blue)
        }
    }
    static let cannotVerify = Look(symbol: "questionmark.diamond.fill", color: .purple)
    /// Deliberately neutral: this must never look like an all-clear.
    static let noMatches = Look(symbol: "doc.text.magnifyingglass", color: .gray)
}

struct ProfileCard: View {
    let result: ProfileResult

    private var name: String { result.profile.name }

    var body: some View {
        switch result.verdict {
        case .matchesFound:
            VStack(alignment: .leading, spacing: 10) {
                ForEach(result.alerts, id: \.entry.allergenId) { AlertBanner(alert: $0, name: name) }
                if result.mayBeMore {
                    Label("This scan wasn't clear, so there may be more matches than shown for \(name).",
                          systemImage: "questionmark.diamond.fill")
                        .font(.callout.bold()).foregroundStyle(.purple)
                }
            }
        case .cannotVerify:
            Banner(look: .cannotVerify,
                   title: "Couldn't read this reliably for \(name)",
                   detail: "Nothing was found, but the photo wasn't clear enough to say. Check the label yourself.")
        case .noMatchesFound:
            Banner(look: .noMatches,
                   title: result.profile.entries.isEmpty ? "No allergens set for \(name)" : "No matches found for \(name)",
                   detail: "This is not a safety guarantee. Please read the label yourself and use normal precautions.")
        }
    }
}

struct Banner: View {
    let look: Look
    let title: String
    let detail: String?
    var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text(title).font(.headline) } icon: { Image(systemName: look.symbol) }
            if let detail { Text(detail).font(.callout) }
            ForEach(lines, id: \.self) { Text($0).font(.footnote.monospaced()) }
        }
        .foregroundStyle(look.onColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(look.color, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct AlertBanner: View {
    let alert: EntryAlert
    let name: String

    var body: some View {
        let look = Look.of(alert.level)
        Banner(
            look: look,
            title: alert.headline(for: name),
            detail: "\(AllergenCatalog.name(for: alert.entry.allergenId)): \(explain(alert.matches[0]))",
            lines: alert.matches.prefix(4).map { "\"\($0.matchedText)\" · \(evidence($0))" })
    }

    private func explain(_ m: Match) -> String {
        switch m.evidence {
        case .direct: return "named on the label"
        case .derivative: return "an ingredient made from it"
        case .ambiguous: return "may be made from it"
        case .advisory: return "cross-contact warning (\"may contain\")"
        case .freeClaim: return "the label says it is free from this, which can't be verified"
        }
    }

    private func evidence(_ m: Match) -> String {
        (m.isFuzzy ? "possible misread · " : "") + {
            switch m.evidence {
            case .direct: "direct"
            case .derivative: "derived"
            case .ambiguous: "unclear source"
            case .advisory: "may contain"
            case .freeClaim: "free-from claim"
            }
        }()
    }
}

struct ReadQualityNote: View {
    let quality: ReadQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("About this photo", systemImage: "camera").font(.headline)
            ForEach(Array(quality.issues).sorted { $0.rawValue < $1.rawValue }, id: \.self) { Text("• " + text($0)).font(.callout) }
            Text("Try again in good light, hold steady, and scan the whole ingredients list.").font(.callout)
        }
    }

    private func text(_ i: ReadIssue) -> String {
        switch i {
        case .tooLittleText: "Very little text was found."
        case .lowConfidence: "The text was blurry or hard to read."
        case .garbled: "The text looked garbled."
        case .noIngredientList: "No ingredients list was found."
        }
    }
}
