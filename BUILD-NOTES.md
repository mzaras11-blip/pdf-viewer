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
  ADMOB-IDS.swift               real AdMob IDs (see below)
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
  ScannerView.swift             VisionKit document camera wrapper
                                (VNDocumentCameraViewController); the
                                scan-to-PDF assembly is
                                LibraryStore.importScan
  Info.plist                    display name, GADApplicationIdentifier
                                (real AdMob app ID), ATT string, SKAdNetwork
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

## Scanning (added in build 2, 2026-11-16)

Owner request: "Can you incorporate a scanning function." The library
gained a **Scan Document** action — first item in the "+" menu, and
the prominent button on the empty-library screen (Open PDF moved to
the secondary style there).

- The scanner itself is Apple's stock **VisionKit document camera**
  (`VNDocumentCameraViewController`, wrapped by `ScannerView.swift`) —
  the same UI as the Notes app: automatic edge detection, perspective
  correction, multi-page capture, color/grayscale/B&W filters, flash.
  We add no capture UI of our own; capture quality is Apple's.
- On save, `LibraryStore.importScan` assembles the page images into
  one PDF in Documents/Imports and registers it like any import — it
  appears in recents, opens in the reader, and annotate / sign /
  merge / reorder / share all work on it. Each page keeps the image's
  aspect ratio fitted inside a US Letter box (612×792 pt); images are
  capped at a 2048-pt long edge so multi-page scans stay a sane size.
- Default name: **"Scan yyyy-MM-dd HH:mm"** (e.g. "Scan 2026-11-16
  17:45"). The app has no rename mechanism for any document, so scans
  don't get one either.
- Edges, handled in `LibraryView.scanTapped` / the scanner delegate:
  camera permission previously denied or restricted → plain alert
  explaining, with an "Open Settings" shortcut; scanner unsupported
  (no camera / Simulator — `VNDocumentCameraViewController.isSupported`
  is false) → alert explaining, Files import still offered; user
  cancels → back to the library, nothing created; a zero-page finish
  creates nothing; a scanner error surfaces its own message.
- Permission string (`Info.plist` → `NSCameraUsageDescription`):
  "PDF Viewer & Editor uses the camera to scan documents into PDFs."
  Scanned images never leave the device (same document model as
  imports). No PrivacyInfo change: camera use is not a required-reason
  API, and no data is collected from scans.

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

### AdMob IDs — REAL (swapped in 2026-11-16)

Created in the AdMob console and swapped into the code (commit
`ade3e689`); `tools/check_project.py` now validates these exact values
and that no placeholders remain (95/95):

| What | Where | Value |
|---|---|---|
| AdMob app ID | `PDFViewer/Info.plist` → `GADApplicationIdentifier` (duplicated as `AdMobIDs.appID`) | `ca-app-pub-9461680459080238~8969876020` |
| Banner unit | `PDFViewer/ADMOB-IDS.swift` → `AdMobIDs.bannerUnitID` | `ca-app-pub-9461680459080238/7587677446` |
| Interstitial unit | `PDFViewer/ADMOB-IDS.swift` → `AdMobIDs.interstitialUnitID` | `ca-app-pub-9461680459080238/8796992346` |

The AdMob app is not yet linked to the App Store listing (the app is
not live), so ad serving may be limited until the store link is made
after launch — same as the sibling launches. The Remove Ads product
still needs creating in App Store Connect (browser-bound, see pipeline
status); the code degrades gracefully (shows the $4.99 label) while
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
  `cert_private_key_v2.pem` (per MEMORY, v2 is the live key; v1 is
  superseded). **FIRST REAL COMPILE PASSED 2026-11-16**: `ios-unsigned`
  build `6afb5617e76223ec282af8a2` finished with every step successful.
  Compile fixes it took (each found from the build log, one or two
  errors at a time): (1) AdManager read the MainActor-isolated
  `StoreManager.removeAdsOwned` from non-isolated contexts → StoreManager
  now mirrors ownership into a `nonisolated(unsafe)` static snapshot
  (`removeAdsOwnedSnapshot`); (2) DrawingViews tried to mutate a
  PKInkingTool cast copy (value type) → rebuild the tool on change;
  (3) ReaderController built ink paths as CGMutablePath → UIBezierPath,
  and `PDFAnnotation.paths` needed optional unwrapping.
- **Pages (live):** landing https://mzaras11-blip.github.io/pdf-viewer/ ·
  support https://mzaras11-blip.github.io/pdf-viewer/support.html ·
  privacy https://mzaras11-blip.github.io/pdf-viewer/privacy.html
  (sources in `~/workspace/pdf-viewer/pages/`).
- **App Store Connect record (created via web UI 2026-11-16):**
  "PDF Viewer & Editor", Apple ID **6835581432**, bundle
  com.swishgame.pdfviewer, SKU pdfviewer001, version 1.0 in
  "Prepare for Submission".
- **AdMob (created 2026-11-16):** app
  `ca-app-pub-9461680459080238~8969876020`, banner
  `ca-app-pub-9461680459080238/7587677446`, interstitial
  `ca-app-pub-9461680459080238/8796992346` — real IDs swapped into the
  code and pushed (commit `ade3e689`, checker 95/95).
- **Signed build → TestFlight (2026-11-16):** Codemagic `ios-workflow`
  build `6afb5c90ca40c6ef3d1d7cc7` finished with every step successful
  (signing files created at runtime, no `ios_signing` block). IPA =
  version **1.0, build 1**, uploaded to App Store Connect and
  **processing completed** (ASC build
  `97d77280-39cf-45fa-a2cb-b3e53ac49301`). The Codemagic distribution
  task then stopped at the final step — submitting build 1 to
  TestFlight **beta review (external testing)** — because the app has
  no Beta App Information (feedback email) or Beta App Review
  Information (contact name / phone / email) yet. The build itself is
  in TestFlight (internal testing unaffected); external submission
  just needs that test-info form filled:
  https://appstoreconnect.apple.com/apps/6835581432/testflight/test-info
- **Browser-bound — could NOT be done via API (2026-11-16):** the ASC
  API needs the team Issuer ID to mint a JWT; it is **not stored
  anywhere on this VM** (re-verified this run: secrets dir holds only
  the .p8 keys; dated memory notes 2026-10-19 and 2026-10-21 record it
  lives only in Codemagic's environment, and Codemagic's API returns
  the values masked). So the following remain for a browser session in
  App Store Connect:
  1. **Remove Ads IAP** — create non-consumable
     `com.swishgame.pdfviewer.remove_ads`, $4.99 USD base price,
     description from `app-store-listing.md`, and attach it to the
     1.0 version.
  2. **Listing metadata** — name/subtitle/description/keywords/
     categories (Utilities / Productivity) and support + privacy URLs
     from `app-store-listing.md`.
  3. **Privacy label + age rating** questionnaires.
  4. **TestFlight test info** (feedback email + beta review contact)
     so build 1 can go to external beta review.
  5. **Screenshots + the pre-submission device recording** (owner's
     iPhone) — then, and only then, submit for review. **Nothing has
     been submitted for review.**

## Verification

- `tools/check_project.py` — run it. It parses both plists, validates
  the asset catalogs and the icon (1024×1024, RGB, no alpha), confirms
  every file referenced by `project.pbxproj` exists (and every Swift
  file on disk is referenced), checks the bundle ID / deployment
  target / Info.plist path in build settings, confirms the scheme
  points at the target, scans Swift sources for balanced delimiters
  and expected cross-file type references, and confirms the
  real AdMob IDs are the ones in place.
- **There is no Swift toolchain or Xcode on this VM**, so nothing is
  compiled locally — but the code has compiled for real in Codemagic:
  the `ios-unsigned` workflow passed 2026-11-16, and the signed
  `ios-workflow` build 1.0 (1) passed and reached TestFlight the same
  day (see Pipeline status).
- Device-only checks for the first TestFlight build: annotation commit
  positions (especially ink on zoomed/rotated pages), signature
  burn-in on rotated pages, form-field saving, the interstitial's
  5-minute timing + page restoration, ATT prompt ordering, and the
  Remove Ads purchase/restore round-trip.
- Device-only checks for build 2 (scanner): the document camera is
  Apple's stock component and cannot run in the Simulator — verify on
  the owner's iPhone: scan capture quality and edge detection, the
  multi-page flow, the permission prompt on first use and the
  denied-permission alert + Settings shortcut, cancel creating no
  document, and a saved scan opening/annotating like any import.
