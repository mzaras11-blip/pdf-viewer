# PDF Viewer & Editor — Build Notes

Working title **"PDF Viewer & Editor"** (owner may rename; the name lives
in `PDFViewer/Info.plist` → `CFBundleDisplayName`/`CFBundleName`, the
root navigation title in `LibraryView.swift`, and `app-store-listing.md`).
Bundle ID **com.swishgame.pdfviewer**. iOS **17.0** floor.
`ITSAppUsesNonExemptEncryption=false`.

Unlike the sibling apps (S.W.I.S.H, ARCADE, GTA6 News, Santa Countdown
Timer — all web-bridge shells), this app is **fully native Swift**:
SwiftUI for UI, **PDFKit** for rendering/editing, **PencilKit** for ink
and the signature pad, **StoreKit 2** for Remove Ads, and the Google
Mobile Ads SDK (SPM, same package/version rule as Santa) for ads.

## Structure

```
PDFViewer.xcodeproj/            target "PDFViewer", one shared scheme
PDFViewer/
  PDFViewerApp.swift            @main; RootView = library + banner strip;
                                scene-phase + onOpenURL wiring; ATT kickoff
  ADMOB-IDS.swift               ⚠️ placeholder AdMob IDs (see below)
  AdManager.swift               banner + timed-interstitial coordinator;
                                AdBannerStrip / BannerAdView
  StoreManager.swift            StoreKit 2: Remove Ads entitlement,
                                purchase, restore, transaction listener
  LibraryStore.swift            recents + page bookmarks (JSON in App
                                Support); PDF files in Documents/Imports
  LibraryView.swift             home: recents, favorites, open, merge mode
  ReaderView.swift              reader screen: toolbars, tool modes,
                                sheets, ad session/block/page-guard wiring
  PDFKitView.swift              UIViewRepresentable PDFView + page-change
                                coordinator; ReadingBackground enum
  ReaderController.swift        the editing hub: navigation, markup,
                                text/note, eraser, ink commit, signature
                                burn-in, page ops, search, outline, save
  DrawingViews.swift            freehand overlay (PencilKit), signature
                                pad, signature store, placement overlay
  ThumbnailsView.swift          page grid: jump, drag-reorder, rotate,
                                delete (context menu)
  SearchView.swift              search sheet + outline sheet + bookmarks
  SettingsView.swift            Remove Ads / restore, reading background,
                                about
  SystemSheets.swift            UIDocumentPicker + share sheet wrappers
  Info.plist                    display name, GADApplicationIdentifier
                                (placeholder), ATT string, SKAdNetwork
                                list (same 50 as Santa), document type
                                for "Open in…" (com.adobe.pdf)
  PrivacyInfo.xcprivacy         same as siblings (UserDefaults CA92.1)
  Assets.xcassets               AppIcon (original PIL-drawn) + AccentColor
codemagic.yaml                  sibling pipeline, PDFViewer names/IDs
app-store-listing.md            store copy (Utilities / Productivity)
tools/check_project.py          structural verification (see below)
```

## Document model

- The picker imports PDFs **as copies** into `Documents/Imports`. All
  editing happens on the copy; **the user's original file is never
  modified**. Share exports a fresh copy from the share sheet.
- Re-importing the same file (name + page count + size match) refreshes
  the existing library entry instead of duplicating it.
- Last-read page is stored per document and restored on open.
- Saving: annotation edits mark the document dirty and are written when
  a tool closes, when leaving the reader, or via "Save Changes".
  Structural edits (page delete/rotate/reorder, signature) write
  immediately. Writes go through `PDFDocument.write(to:)`, which also
  persists form-field values.
- Form fields need no special code: PDFView edits widget annotations
  natively; values persist on save.

## Editing specifics & honest limitations

- **Highlight/underline** apply to the current text selection, split by
  line (`selectionsByLine()`), in 4 colors (highlight) / red (underline).
- **Freehand ink**: PencilKit canvas over the current page; strokes are
  converted view→page coordinates (`PDFView.convert(_:to:)`) and stored
  as true vector ink annotations. Ink paths use the page media box as
  the annotation bounds so path space == page space. Drawing is a
  current-page activity: enter Draw mode on the page you want to mark.
- **Sticky notes** are pale-yellow free-text annotations (visible in any
  reader), tagged `userName = "PVNote"`; plain text boxes are tagged
  `PVText`. The eraser removes markup/ink/text/note annotations but
  **never form widgets**.
- **Signature**: drawn once with PencilKit, saved as a transparent PNG
  on-device. Placement is drag + pinch over the page. Stamping **burns
  the image into the page content** (the page is re-rendered at vector
  quality with `UIGraphicsPDFRenderer` + `PDFPage.draw`) so it shows in
  every PDF reader. Existing non-widget annotations on that page are
  copied across; **form widgets on the stamped page are not carried
  over** — fill that page's form after stamping, or stamp last.
  Rotated/cropped pages are the riskiest case here — verify on device.
- **Page reorder** rebuilds the document from its pages (annotations
  ride along with each page). Delete keeps at least one page.
- **Search** uses `PDFDocument.findString` on a background task; huge
  scanned documents may be slow, and image-only PDFs have no text to
  find (no OCR in v1).
- Device family is iPhone-only (`TARGETED_DEVICE_FAMILY = "1"`,
  portrait), matching the sibling pipeline. Widening to iPad/landscape
  is a project-setting change plus layout checks, deliberately left for
  a later pass.

## Ads — the owner's exact model

`AdManager` (mirrors the sibling AdManager pattern: ATT first, then SDK
start; banner strip is zero-height until a real ad loads; 45s retry
after a failed banner load).

1. **Banner** — pinned under the app content at the bottom of the
   screen, on both the library and the reader.
2. **Timed interstitial** — after every **300 seconds of active use**
   (`AdManager.interstitialInterval`), one full-screen ad, then the
   reader returns to the exact same page:
   - A 1-second timer counts only while the app is in the foreground,
     a document session is open (ReaderView sets `sessionActive`), the
     reader is not mid-interaction (`uiBlocked`: drawing, placing a
     signature, or any sheet/picker up), and Remove Ads is not owned.
   - If the interval elapses while blocked, the ad stays **pending**
     and fires at the next natural break: the moment the block clears
     (tool close / sheet dismiss) or on the next page change.
   - Before presenting, the current page is recorded via the page
     guard ReaderView registers; on dismissal it is restored verbatim.
   - The next interstitial is preloaded after each dismissal; if no ad
     is loaded when one comes due, it waits for the load and then uses
     the next natural break.
3. **Remove Ads** (StoreKit non-consumable
   `com.swishgame.pdfviewer.remove_ads`, $4.99 set in App Store
   Connect) is the master switch: entitlement is checked at launch,
   on purchase/restore, on every timer tick, and before every banner
   load and interstitial presentation. Once owned, the banner never
   loads, the timer stops, and any pending interstitial is dropped.

### ⚠️ Placeholder AdMob IDs — replace in the pipeline phase

Real IDs are created in the AdMob console during account setup. Until
then these obvious fakes are in place (ads simply never load; the app
is fully usable):

| What | Where | Placeholder |
|---|---|---|
| AdMob app ID | `PDFViewer/Info.plist` → `GADApplicationIdentifier` | `ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY` |
| Banner unit | `PDFViewer/ADMOB-IDS.swift` → `AdMobIDs.bannerUnitID` | `ca-app-pub-XXXXXXXXXXXXXXXX/AAAAAAAAAA` |
| Interstitial unit | `PDFViewer/ADMOB-IDS.swift` → `AdMobIDs.interstitialUnitID` | `ca-app-pub-XXXXXXXXXXXXXXXX/BBBBBBBBBB` |

The app ID is duplicated as `AdMobIDs.appID` for reference. When the
real app is created, its ID follows the sibling shape
(`ca-app-pub-9461680459080238~…`). Also create the Remove Ads product
in App Store Connect before the first TestFlight build that should
sell it; the code degrades gracefully (shows the $4.99 label) while
the product is missing.

## Pipeline status (2026-11-16)

- **GitHub:** repo created and pushed — https://github.com/mzaras11-blip/pdf-viewer
  (public; project at root, sibling layout; push helper `~/workspace/pdf-viewer/push_to_github.py`).
  Pre-push audit: no secrets in the tree (placeholders only); checker 95/95.
  Note: the GitHub API token CAN create repos now (verified firsthand this
  run — `POST /user/repos` succeeded), contrary to the older pipeline notes.
- **Codemagic:** app registered via API — app ID `6afb39047f6c11bd3902822e`
  ("pdf-viewer", settingsSource: file, codemagic.yaml picked up).
  `CERTIFICATE_PRIVATE_KEY` set in group `certificate_credentials` from
  `cert_private_key_v2.pem` (if the signed build rejects the cert, swap to
  `cert_private_key.pem` and rebuild). First compile = `ios-unsigned`
  workflow, build `6afb392cb72d83c1457c74eb` (build index 2; an identical
  build #1 was queued by the helper's first POST — same commit 7e31a4ac).
- **Pages (live):** landing https://mzaras11-blip.github.io/pdf-viewer/ ·
  support https://mzaras11-blip.github.io/pdf-viewer/support.html ·
  privacy https://mzaras11-blip.github.io/pdf-viewer/privacy.html
  (sources in `~/workspace/pdf-viewer/pages/`).
- **Still blocked on browser/owner steps (as of this note):** App Store
  Connect app record creation (the ASC API cannot create apps — web UI
  only), AdMob app + banner/interstitial unit creation (AdMob console),
  then the signed `ios-workflow` build to TestFlight, the Remove Ads IAP
  (API-able once the app record exists), listing metadata, and
  screenshots + the pre-submission device recording (owner's iPhone).

## Verification

- `tools/check_project.py` — run it. It parses both plists, validates
  the asset catalogs and the icon (1024×1024, RGB, no alpha), confirms
  every file referenced by `project.pbxproj` exists (and every Swift
  file on disk is referenced), checks the bundle ID / deployment
  target / Info.plist path in build settings, confirms the scheme
  points at the target, scans Swift sources for balanced delimiters
  and expected cross-file type references, and confirms the
  placeholder AdMob IDs are the ones in place.
- **There is no Swift toolchain or Xcode on this VM**, so no file here
  has been compiled. The first real compile is the Codemagic
  `ios-unsigned` workflow (or the signed `ios-workflow`).
- Device-only checks for the first TestFlight build: annotation commit
  positions (especially ink on zoomed/rotated pages), signature
  burn-in on rotated pages, form-field saving, the interstitial's
  5-minute timing + page restoration, ATT prompt ordering, and the
  Remove Ads purchase/restore round-trip.
