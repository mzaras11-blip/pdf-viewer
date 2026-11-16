import SwiftUI

/// Settings: Remove Ads purchase + restore, reading background, and
/// the about block. Presented as a sheet from the library and the
/// reader.
struct SettingsView: View {
    @ObservedObject private var store = StoreManager.shared
    @AppStorage("readingBackground") private var readingBackgroundRaw = ReadingBackground.white.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.removeAdsOwned {
                        Label("Ads are off — thank you!", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("The bottom banner and the timed full-screen ads are permanently disabled on this device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("This app is free with ads: a small banner at the bottom, and one full-screen ad after about every 5 minutes of reading.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button {
                                Task { await store.purchaseRemoveAds() }
                            } label: {
                                HStack {
                                    Text("Remove Ads")
                                    Spacer()
                                    if store.isPurchasing {
                                        ProgressView()
                                    } else if let product = store.product {
                                        Text(product.displayPrice)
                                            .fontWeight(.semibold)
                                    } else {
                                        Text("$4.99")
                                            .fontWeight(.semibold)
                                    }
                                }
                            }
                            .disabled(store.isPurchasing)
                            Text("One-time purchase — not a subscription. Removes the banner and the timed ads forever.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Restore Purchases") {
                            Task { await store.restorePurchases() }
                        }
                    }
                    if let message = store.lastMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Remove Ads")
                }

                Section {
                    Picker("Reading Background", selection: $readingBackgroundRaw) {
                        ForEach(ReadingBackground.allCases) { background in
                            Text(background.label).tag(background.rawValue)
                        }
                    }
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Changes the backdrop behind pages in the reader. Page colors always stay true.")
                }

                Section {
                    LabeledContent("App", value: "PDF Viewer & Editor")
                    LabeledContent("Version", value: versionString)
                    Text("Your documents are stored only on this device. Editing never changes your original files — the app works on its own imported copies, and Share exports a copy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.refresh() }
            .onChange(of: store.removeAdsOwned) { _, owned in
                if owned { AdManager.shared.disableAdsForPurchase() }
            }
        }
    }

    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
