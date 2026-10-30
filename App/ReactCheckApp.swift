import ReactCheckCore
import SwiftUI

@main
struct ReactCheckApp: App {
    @State private var store = ProfileStore()
    @AppStorage("acknowledgedVersion") private var acknowledged = 0

    static let currentAcknowledgement = 1

    var body: some Scene {
        WindowGroup {
            if acknowledged >= Self.currentAcknowledgement {
                RootView().environment(store)
            } else {
                OnboardingView { acknowledged = Self.currentAcknowledgement }
            }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ScanView()
                .tabItem { Label("Scan", systemImage: "camera.viewfinder") }
            ProfilesView()
                .tabItem { Label("People", systemImage: "person.2") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}
