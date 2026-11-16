import Foundation

/// AdMob identifiers for PDF Viewer & Editor.
///
/// REAL IDs — created in the AdMob console on 2026-11-16 (same publisher
/// account as the sibling apps, mzaras11@gmail.com) and swapped in here;
/// the app ID is also in Info.plist as `GADApplicationIdentifier`.
///
/// The AdMob app is not yet linked to the App Store listing (the app is
/// not live), so ad serving may be limited until the store link is made
/// after launch — same as the sibling launches.
enum AdMobIDs {
    static let appID = "ca-app-pub-9461680459080238~8969876020"
    static let bannerUnitID = "ca-app-pub-9461680459080238/7587677446"
    static let interstitialUnitID = "ca-app-pub-9461680459080238/8796992346"
}
