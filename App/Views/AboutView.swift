import SwiftUI

struct AboutView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("What React Check does not do") {
                    ForEach(limitations, id: \.self) { Text($0) }
                }
                Section("Where the allergen lists come from") {
                    Text("The lists cover the US FDA major food allergens and the EU's 14 allergens, plus coconut, corn, buckwheat, lactose and any word you add yourself. Ingredient names and \"may contain\" phrases were compiled from public labelling rules and common usage, so they may be incomplete. They have not been reviewed by a doctor or allergist.")
                }
                Section("How it works") {
                    Text("Your photos are read on this device. React Check looks for the allergens you set, their common alternative names, and \"may contain\" warnings in several languages. Nothing leaves your phone.")
                }
                Section("Free and open source") {
                    Link("Support React Check", destination: URL(string: "https://arrhen.me/react-check/support")!)
                    Link("Privacy", destination: URL(string: "https://arrhen.me/react-check/privacy")!)
                    Link("Source code (MIT licence)", destination: URL(string: "https://github.com/arrhen/react-check")!)
                    Text("Donations never unlock features or change how matching works.").font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("React Check is an aid, not a substitute for reading the label. It is not medical advice and comes with no warranty.")
                        .font(.footnote)
                }
            }
            .navigationTitle("About")
        }
    }

    private let limitations = [
        "It can't see cross-contact that isn't printed on the label.",
        "It can't know what is hidden in \"natural flavors\" or \"spices\".",
        "Labels change. Check every purchase, even familiar ones.",
        "A photo can be misread. If it says it couldn't read the label, believe it.",
        "Food without a printed label, such as restaurant meals, is out of scope.",
        "Names for allergens in languages other than English are a first draft.",
    ]
}
