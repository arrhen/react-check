import SwiftUI

struct OnboardingView: View {
    var onAcknowledge: () -> Void
    @State private var agreed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("React Check")
                    .font(.largeTitle.bold())
                Text("A second pair of eyes on a food label.")
                    .font(.title3)

                VStack(alignment: .leading, spacing: 12) {
                    point("Add the people you cook for and what they react to.")
                    point("Photograph an ingredients list. React Check reads it and flags matches.")
                    point("Everything stays on this device. No account, no tracking.")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("This is an aid, not a guarantee", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text("""
                        React Check can misread a label, miss a hidden ingredient, or be out of date. Labels change, \
                        and cross-contact is not always listed. It does not replace reading the label yourself, \
                        and it is not medical advice. You remain responsible for what you or your family eat.
                        """)
                        .font(.callout)
                    }
                }

                Toggle("I understand and will always read the label myself", isOn: $agreed)
                    .toggleStyle(.switch)

                Button("Continue", action: onAcknowledge)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!agreed)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }

    private func point(_ text: String) -> some View {
        Label { Text(text) } icon: { Image(systemName: "checkmark.circle").foregroundStyle(.tint) }
    }
}
