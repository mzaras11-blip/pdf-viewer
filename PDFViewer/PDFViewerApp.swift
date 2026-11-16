import SwiftUI

/// Root layout: the library fills the screen, and the AdMob banner
/// strip is pinned underneath it. The strip takes zero height until a
/// real ad has loaded, so the library never hides behind an empty
/// slot — and it vanishes for good once Remove Ads is owned.
struct RootView: View {
    @StateObject private var library = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                LibraryView()
            }
            AdBannerStrip()
        }
        .environmentObject(library)
        .onChange(of: scenePhase) { _, phase in
            AdManager.shared.appInForeground = (phase == .active)
        }
        .onOpenURL { url in
            // "Open in PDF Viewer & Editor" from Files/Mail/etc.
            _ = try? library.importPDF(from: url)
        }
    }
}

@main
struct PDFViewerApp: App {
    init() {
        // Ads start only after the App Tracking Transparency decision
        // (Guideline 5.1.2(i)): AdManager presents the ATT request
        // first, then starts the Google Mobile Ads SDK and loads the
        // first ads. StoreManager resolves the Remove Ads entitlement
        // the first time anything touches it (the banner strip and
        // AdManager both do, at launch); if it is owned, AdManager
        // loads nothing.
        AdManager.shared.beginAdFlow()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
