import Foundation
import SwiftUI
import Combine
import AppTrackingTransparency
import AdSupport
#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

/// Returns the top-most view controller for presenting ads.
func topViewController() -> UIViewController? {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let root = scene.windows.first?.rootViewController else { return nil }
    var vc = root
    while let presented = vc.presentedViewController { vc = presented }
    return vc
}

/// Central ad coordinator for PDF Viewer & Editor.
///
/// Two formats, exactly the owner's model:
///   * a banner pinned to the bottom of the screen, present in the
///     layout at ZERO height until a real ad has loaded, and
///   * a TIMED interstitial: after every ~5 minutes of ACTIVE use it
///     shows one full-screen ad, then hands the reader back to the
///     exact page they were on.
///
/// "Active use" is counted by a 1-second timer that only advances
/// while ALL of these are true:
///   - the app is in the foreground,
///   - a document session is open (the reader is on screen),
///   - the reader is not mid-interaction (drawing, placing a
///     signature, or a sheet/picker is up) — `uiBlocked`,
///   - Remove Ads is not owned.
///
/// When the timer comes due while the reader is blocked, the ad stays
/// pending and fires at the next natural break: the moment the block
/// clears (tool closed, sheet dismissed) or the page changes.
///
/// Ads come from Google AdMob via the swift-package-manager-google-
/// mobile-ads SPM package, same as the sibling apps. The ATT request
/// always comes first (Guideline 5.1.2(i)). Ad unit IDs are
/// placeholders in ADMOB-IDS.swift until the pipeline phase.
final class AdManager: NSObject, ObservableObject {
    static let shared = AdManager()

    /// Seconds of active use between interstitials (~5 minutes).
    static let interstitialInterval: TimeInterval = 300

    /// True only once a real banner ad has actually loaded. The banner
    /// strip exists on screen only while this is true.
    @Published var bannerLoaded = false
    private var bannerHasLoaded = false

    /// Set by ReaderView: a document session is on screen.
    var sessionActive = false
    /// Set by ReaderView: the reader is mid-interaction (drawing,
    /// placing a signature, a sheet/picker is presented). While true,
    /// the usage timer pauses and a due interstitial waits.
    var uiBlocked = false {
        didSet {
            if oldValue, !uiBlocked { presentInterstitialIfDue() }
        }
    }
    /// Set by the app on scene-phase changes.
    var appInForeground = true

    /// Page guard, registered by ReaderView: reads the reader's
    /// current page before an interstitial and restores it after, so
    /// the reader always lands back exactly where they were.
    var pageGuard: (read: () -> Int, restore: (Int) -> Void)?

    private var activeUseSeconds: TimeInterval = 0
    private var interstitialDue = false
    private var usageTimer: Timer?
    private var adFlowStarted = false

    #if canImport(GoogleMobileAds)
    private var interstitialAd: GADInterstitialAd?
    private var interstitialLoading = false
    private var pageBeforeInterstitial: Int?
    #endif

    var adsAreReal: Bool {
        #if canImport(GoogleMobileAds)
        return true
        #else
        return false
        #endif
    }

    /// Remove Ads ownership is the master switch for every ad path.
    private var removeAdsOwned: Bool { StoreManager.shared.removeAdsOwned }

    private override init() {
        super.init()
        // Ads are NOT loaded here. The ATT request must come first —
        // see beginAdFlow().
    }

    /// Entry point for the ad flow, called once from the app's init.
    /// Presents the ATT permission request (after a short settle delay
    /// so the first screen is on display); only after the user decides
    /// does the ads SDK start and the first ads load. A "no" still gets
    /// ads — they are simply not personalized. If Remove Ads is already
    /// owned, nothing loads at all.
    func beginAdFlow() {
        guard !adFlowStarted else { return }
        adFlowStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if #available(iOS 14, *) {
                ATTrackingManager.requestTrackingAuthorization { _ in
                    DispatchQueue.main.async { AdManager.shared.startAds() }
                }
            } else {
                AdManager.shared.startAds()
            }
        }
    }

    private func startAds() {
        guard !removeAdsOwned else { return }
        #if canImport(GoogleMobileAds)
        GADMobileAds.sharedInstance().start(completionHandler: nil)
        #endif
        loadInterstitial()
        startUsageTimer()
    }

    /// Called when Remove Ads becomes owned mid-session: stops the
    /// usage timer, drops any loaded/pending interstitial, and hides
    /// the banner for good.
    func disableAdsForPurchase() {
        usageTimer?.invalidate()
        usageTimer = nil
        interstitialDue = false
        activeUseSeconds = 0
        bannerLoaded = false
        bannerHasLoaded = false
        #if canImport(GoogleMobileAds)
        interstitialAd = nil
        #endif
    }

    // MARK: - Timed interstitial

    private func startUsageTimer() {
        usageTimer?.invalidate()
        usageTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard !removeAdsOwned else {
            if bannerLoaded || interstitialDue { disableAdsForPurchase() }
            return
        }
        guard appInForeground, sessionActive, !uiBlocked else { return }
        activeUseSeconds += 1
        if activeUseSeconds >= Self.interstitialInterval {
            interstitialDue = true
            presentInterstitialIfDue()
        }
    }

    /// Called by ReaderView on every page change — a page change is
    /// one of the natural breaks a pending interstitial may use.
    func notePageChanged() {
        presentInterstitialIfDue()
    }

    /// Presents the timed interstitial if one is due, an ad is loaded,
    /// and the reader is at a natural break. The reader's page is
    /// recorded first and restored on dismissal.
    func presentInterstitialIfDue() {
        guard interstitialDue, !removeAdsOwned else { return }
        guard appInForeground, sessionActive, !uiBlocked else { return }
        #if canImport(GoogleMobileAds)
        guard let ad = interstitialAd, let root = topViewController() else {
            loadInterstitial()
            return
        }
        interstitialDue = false
        activeUseSeconds = 0
        interstitialAd = nil
        pageBeforeInterstitial = pageGuard?.read()
        ad.fullScreenContentDelegate = self
        ad.present(fromRootViewController: root)
        #else
        // No SDK linked: nothing to show; reset so the timer restarts.
        interstitialDue = false
        activeUseSeconds = 0
        #endif
    }

    private func loadInterstitial() {
        guard !removeAdsOwned else { return }
        #if canImport(GoogleMobileAds)
        guard !interstitialLoading, interstitialAd == nil else { return }
        interstitialLoading = true
        GADInterstitialAd.load(withAdUnitID: AdMobIDs.interstitialUnitID,
                               request: GADRequest()) { [weak self] ad, _ in
            DispatchQueue.main.async {
                self?.interstitialLoading = false
                self?.interstitialAd = ad
                // An ad that was already due can fire at the next
                // natural break once it exists.
                if ad != nil { self?.presentInterstitialIfDue() }
            }
        }
        #endif
    }

    // MARK: - Banner

    #if canImport(GoogleMobileAds)
    private weak var bannerView: GADBannerView?

    func makeBanner(delegate: GADBannerViewDelegate?) -> GADBannerView {
        let banner = GADBannerView(adSize: GADAdSizeBanner)
        banner.adUnitID = AdMobIDs.bannerUnitID
        banner.delegate = delegate
        bannerView = banner
        if !removeAdsOwned { banner.load(GADRequest()) }
        return banner
    }

    /// A real banner ad arrived — the strip may show (unless Remove
    /// Ads was bought in the meantime).
    func noteBannerLoaded() {
        guard !removeAdsOwned else { return }
        bannerHasLoaded = true
        bannerLoaded = true
    }

    /// A banner load failed. Before the first success the strip stays
    /// hidden; afterwards the on-screen ad is kept. Either way, retry
    /// later so one empty moment does not disable banners all session.
    func noteBannerFailed() {
        if !bannerHasLoaded { bannerLoaded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, !self.removeAdsOwned else { return }
            self.bannerView?.load(GADRequest())
        }
    }
    #endif
}

#if canImport(GoogleMobileAds)
extension AdManager: GADFullScreenContentDelegate {
    func adDidDismissFullScreenContent(_ ad: GADFullScreenPresentingAd) {
        // Hand the reader back to the exact page they left.
        if let page = pageBeforeInterstitial {
            pageGuard?.restore(page)
            pageBeforeInterstitial = nil
        }
        loadInterstitial()
    }

    func ad(_ ad: GADFullScreenPresentingAd,
            didFailToPresentFullScreenContentWithError error: Error) {
        pageBeforeInterstitial = nil
        loadInterstitial()
    }
}

/// SwiftUI wrapper for an AdMob banner.
struct BannerAdView: UIViewRepresentable {
    func makeUIView(context: Context) -> GADBannerView {
        let banner = AdManager.shared.makeBanner(delegate: context.coordinator)
        banner.rootViewController = topViewController()
        return banner
    }
    func updateUIView(_ uiView: GADBannerView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, GADBannerViewDelegate {
        func bannerViewDidReceiveAd(_ bannerView: GADBannerView) {
            AdManager.shared.noteBannerLoaded()
        }
        func bannerView(_ bannerView: GADBannerView, didFailToReceiveAdWithError error: Error) {
            AdManager.shared.noteBannerFailed()
        }
    }
}
#endif

/// The banner strip pinned to the bottom of the screen. It is always
/// in the layout but takes zero height (and ignores touches) until a
/// real ad has loaded, and it disappears permanently once Remove Ads
/// is owned.
#if canImport(GoogleMobileAds)
struct AdBannerStrip: View {
    @ObservedObject private var adManager = AdManager.shared
    @ObservedObject private var store = StoreManager.shared

    private var visible: Bool { adManager.bannerLoaded && !store.removeAdsOwned }

    var body: some View {
        BannerAdView()
            .frame(height: visible ? 50 : 0)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .clipped()
    }
}
#else
struct AdBannerStrip: View {
    var body: some View { EmptyView() }
}
#endif
