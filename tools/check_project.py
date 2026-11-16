#!/usr/bin/env python3
"""Structural verification for the PDFViewer Xcode project.

There is no Xcode / Swift toolchain on this VM, so this checks
everything that can be checked statically:

  1. Info.plist + PrivacyInfo.xcprivacy parse and carry the expected
     keys (placeholder AdMob app ID, export-compliance flag, the
     50-item SKAdNetwork list copied from the Santa build).
  2. Asset catalogs parse; the app icon is exactly 1024x1024, RGB,
     with no alpha channel.
  3. project.pbxproj: every object ID referenced is defined; every
     file reference resolves to a file on disk; every Swift file on
     disk is referenced and in the Sources phase; bundle ID,
     deployment target and Info.plist path are correct in both
     configurations; the Google Mobile Ads SPM package is wired.
  4. The shared scheme points at the project's target.
  5. Swift sources: balanced delimiters (comments/strings stripped),
     expected imports, and the cross-file type references the app is
     built around (AdManager, StoreManager, ReaderController, ...).
  6. The placeholder AdMob IDs are exactly where BUILD-NOTES.md says.

Exit code 0 = all checks passed.
"""
import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent.parent
SRC_DIR = APP_DIR / "PDFViewer"
PBXPROJ = APP_DIR / "PDFViewer.xcodeproj" / "project.pbxproj"
SCHEME = APP_DIR / "PDFViewer.xcodeproj" / "xcshareddata" / "xcschemes" / "PDFViewer.xcscheme"

failures = []
passes = 0


def check(ok, label, detail=""):
    global passes
    if ok:
        passes += 1
        print(f"  PASS  {label}")
    else:
        failures.append(label)
        print(f"  FAIL  {label}  {detail}")


print("== Plists ==")
with open(SRC_DIR / "Info.plist", "rb") as f:
    info = plistlib.load(f)
check(info.get("CFBundleDisplayName") == "PDF Viewer & Editor", "Info.plist display name")
check(info.get("GADApplicationIdentifier") == "ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY",
      "Info.plist carries the placeholder AdMob app ID")
check(info.get("ITSAppUsesNonExemptEncryption") is False, "ITSAppUsesNonExemptEncryption = false")
check(len(info.get("SKAdNetworkItems", [])) == 50, "SKAdNetworkItems has 50 entries (Santa parity)",
      f"got {len(info.get('SKAdNetworkItems', []))}")
check("NSUserTrackingUsageDescription" in info, "ATT usage string present")
doc_types = info.get("CFBundleDocumentTypes", [])
check(any("com.adobe.pdf" in dt.get("LSItemContentTypes", []) for dt in doc_types),
      "PDF document type registered for Open in…")

with open(SRC_DIR / "PrivacyInfo.xcprivacy", "rb") as f:
    privacy = plistlib.load(f)
check(isinstance(privacy, dict) and "NSPrivacyAccessedAPITypes" in privacy,
      "PrivacyInfo.xcprivacy parses with accessed-API section")

print("== Asset catalogs & icon ==")
for rel in ["Assets.xcassets/Contents.json",
            "Assets.xcassets/AppIcon.appiconset/Contents.json",
            "Assets.xcassets/AccentColor.colorset/Contents.json"]:
    try:
        json.loads((SRC_DIR / rel).read_text())
        check(True, f"{rel} is valid JSON")
    except Exception as exc:  # noqa: BLE001
        check(False, f"{rel} is valid JSON", str(exc))

from PIL import Image  # noqa: E402

icon_path = SRC_DIR / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-1024.png"
icon = Image.open(icon_path)
check(icon.size == (1024, 1024), "icon is 1024x1024", f"got {icon.size}")
check(icon.mode == "RGB", "icon is RGB with no alpha", f"mode={icon.mode}")

print("== project.pbxproj ==")
pbx = PBXPROJ.read_text()
id_re = re.compile(r"\bPV01[A-Z0-9]{20}\b")
defined = set(re.findall(r"^\t\t(PV01[A-Z0-9]{20}) (?:/\* [^*]+ \*/ )?= \{", pbx, flags=re.M))
referenced = set(id_re.findall(pbx))
check(referenced <= defined, "every referenced object ID is defined",
      f"missing: {sorted(referenced - defined)}")
root = re.search(r"rootObject = (PV01[A-Z0-9]{20})", pbx)
check(bool(root) and root.group(1) in defined, "rootObject resolves")

fileref_re = re.compile(
    r"(PV01[A-Z0-9]{20}) /\* ([^*]+) \*/ = \{isa = PBXFileReference; [^}]*?"
    r"path = (\"[^\"]+\"|[^;]+); sourceTree = (\"[^\"]+\"|[^;]+); \};")
missing_files = []
ref_paths = {}
for fid, _name, raw_path, raw_tree in fileref_re.findall(pbx):
    path = raw_path.strip().strip('"')
    tree = raw_tree.strip().strip('"')
    ref_paths[fid] = path
    if tree == "BUILT_PRODUCTS_DIR":
        continue
    resolved = SRC_DIR / path
    if not resolved.exists():
        missing_files.append(f"{path} -> {resolved}")
check(not missing_files, "every file reference exists on disk", "; ".join(missing_files))

swift_on_disk = sorted(p.name for p in SRC_DIR.glob("*.swift"))
swift_referenced = sorted(p for p in ref_paths.values() if p.endswith(".swift"))
check(swift_on_disk == swift_referenced, "Swift files on disk == Swift files referenced",
      f"disk={swift_on_disk} refs={swift_referenced}")

sources_block = re.search(r"isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);", pbx, flags=re.S)
buildfile_to_ref = dict(re.findall(
    r"(PV01[A-Z0-9]{20}) /\* [^*]+ in Sources \*/ = \{isa = PBXBuildFile; fileRef = (PV01[A-Z0-9]{20})", pbx))
in_sources = sorted(ref_paths[buildfile_to_ref[bid]]
                    for bid in re.findall(r"(PV01[A-Z0-9]{20}) /\*", sources_block.group(1))
                    if bid in buildfile_to_ref)
check(in_sources == swift_on_disk, "Sources phase contains exactly the Swift files on disk",
      f"sources={in_sources}")

check(pbx.count("PRODUCT_BUNDLE_IDENTIFIER = com.swishgame.pdfviewer;") == 2,
      "bundle ID com.swishgame.pdfviewer in Debug+Release")
check(pbx.count("IPHONEOS_DEPLOYMENT_TARGET = 17.0;") == 2,
      "deployment target 17.0 in Debug+Release")
check(pbx.count("INFOPLIST_FILE = PDFViewer/Info.plist;") == 2,
      "INFOPLIST_FILE path in Debug+Release")
check("swift-package-manager-google-mobile-ads" in pbx, "Google Mobile Ads SPM package referenced")
check("minimumVersion = 11.0.0" in pbx, "SPM version rule matches Santa (11.0.0 upToNextMajor)")

print("== Scheme ==")
scheme_root = ET.parse(SCHEME).getroot()
refs = scheme_root.findall(".//BuildableReference")
target_match = re.search(r"(PV01[A-Z0-9]{20}) /\* PDFViewer \*/ = \{\s*isa = PBXNativeTarget;", pbx)
check(len(refs) >= 1 and all(r.get("BlueprintIdentifier") == target_match.group(1) for r in refs),
      "scheme BlueprintIdentifier == PBXNativeTarget id")
check(all(r.get("BuildableName") == "PDFViewer.app" for r in refs), "scheme builds PDFViewer.app")

print("== Swift sources ==")


def strip_comments_and_strings(text: str) -> str:
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            i = n if j == -1 else j + 3
            out.append('""')
        elif text[i] == '"':
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    break
                j += 1
            i = j + 1
            out.append('""')
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


swift_texts = {}
for name in swift_on_disk:
    raw = (SRC_DIR / name).read_text()
    swift_texts[name] = raw
    stripped = strip_comments_and_strings(raw)
    balance_ok = all(stripped.count(a) == stripped.count(b)
                     for a, b in [("(", ")"), ("{", "}"), ("[", "]")])
    check(balance_ok, f"{name}: balanced delimiters")
    check("TODO" not in raw and "FIXME" not in raw, f"{name}: no TODO/FIXME leftovers")

expected_imports = {
    "PDFViewerApp.swift": ["import SwiftUI"],
    "AdManager.swift": ["import SwiftUI", "import AppTrackingTransparency", "GoogleMobileAds"],
    "StoreManager.swift": ["import StoreKit"],
    "LibraryStore.swift": ["import PDFKit"],
    "ReaderController.swift": ["import PDFKit", "import UIKit"],
    "PDFKitView.swift": ["import PDFKit", "UIViewRepresentable"],
    "DrawingViews.swift": ["import PencilKit", "import PDFKit"],
    "ThumbnailsView.swift": ["import PDFKit"],
    "SystemSheets.swift": ["import UniformTypeIdentifiers"],
}
for name, needles in expected_imports.items():
    for needle in needles:
        check(needle in swift_texts[name], f"{name}: contains '{needle}'")

# Cross-file references: a type used in file B must be defined in file A.
definitions = {
    "AdManager": "AdManager.swift",
    "StoreManager": "StoreManager.swift",
    "LibraryStore": "LibraryStore.swift",
    "ReaderController": "ReaderController.swift",
    "RecentDocument": "LibraryStore.swift",
    "PageBookmark": "LibraryStore.swift",
    "AdMobIDs": "ADMOB-IDS.swift",
    "ReadingBackground": "PDFKitView.swift",
    "SignatureStore": "DrawingViews.swift",
}
for type_name, defining_file in definitions.items():
    pattern = rf"(?:final class|class|struct|enum)\s+{type_name}\b"
    check(re.search(pattern, swift_texts[defining_file]) is not None,
          f"{type_name} is defined in {defining_file}")

uses = [
    ("AdManager", "PDFViewerApp.swift"), ("AdManager", "ReaderView.swift"),
    ("AdManager", "SettingsView.swift"), ("StoreManager", "AdManager.swift"),
    ("StoreManager", "SettingsView.swift"), ("AdMobIDs", "AdManager.swift"),
    ("ReaderController", "ReaderView.swift"), ("ReaderController", "PDFKitView.swift"),
    ("ReaderController", "ThumbnailsView.swift"), ("ReaderController", "SearchView.swift"),
    ("LibraryStore", "ReaderView.swift"), ("LibraryStore", "LibraryView.swift"),
    ("SignatureStore", "ReaderView.swift"), ("ReadingBackground", "SettingsView.swift"),
]
for type_name, using_file in uses:
    check(re.search(rf"\b{type_name}\b", swift_texts[using_file]) is not None,
          f"{type_name} is referenced in {using_file}")

check("com.swishgame.pdfviewer.remove_ads" in swift_texts["StoreManager.swift"],
      "Remove Ads product ID in StoreManager")
check("interstitialInterval: TimeInterval = 300" in swift_texts["AdManager.swift"],
      "interstitial interval is 300s (owner's ~5 minutes)")

print("== Placeholder AdMob IDs ==")
adm = swift_texts["ADMOB-IDS.swift"]
check("ca-app-pub-XXXXXXXXXXXXXXXX~YYYYYYYYYY" in adm, "ADMOB-IDS.swift app ID placeholder")
check("ca-app-pub-XXXXXXXXXXXXXXXX/AAAAAAAAAA" in adm, "ADMOB-IDS.swift banner placeholder")
check("ca-app-pub-XXXXXXXXXXXXXXXX/BBBBBBBBBB" in adm, "ADMOB-IDS.swift interstitial placeholder")
check("9461680459080238" not in adm and "9461680459080238" not in json.dumps(info),
      "no real publisher IDs leaked into placeholders")

print()
print(f"{passes} passed, {len(failures)} failed")
if failures:
    print("FAILURES:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print("ALL CHECKS PASSED")
