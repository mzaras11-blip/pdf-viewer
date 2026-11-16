import Foundation

/// AdMob identifiers for PDF Viewer & Editor.
///
/// ⚠️ PLACEHOLDERS — the real AdMob app ID and ad unit IDs are created
/// in the AdMob console during the account pipeline phase (same account
/// as the other apps, mzaras11@gmail.com) and pasted here; the app ID
/// also goes into Info.plist as `GADApplicationIdentifier`.
///
/// Until then the values below are fake on purpose. With them, the ads
/// SDK cannot load real ads: the banner strip stays at zero height, the
/// timed interstitial never becomes ready, and the app remains fully
/// usable — exactly the behaviour we want before the pipeline phase.
///
/// Expected shape of the real values (same publisher account as the
/// sibling apps — see any sibling's AdManager for the account prefix):
///   app ID:          ca-app-pub-<publisher>~<app number>
///   banner unit:     ca-app-pub-<publisher>/<unit number>
///   interstitial:    ca-app-pub-<publisher>/<unit number>
enum AdMobIDs {
    static let appID = "ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY"
    static let bannerUnitID = "ca-app-pub-XXXXXXXXXXXXXXXX/AAAAAAAAAA"
    static let interstitialUnitID = "ca-app-pub-XXXXXXXXXXXXXXXX/BBBBBBBBBB"
}
