import AVFoundation
import SwiftUI
import UIKit

/// The home screen: the reader's library. Recents sorted by last
/// opened, favorites pinned by a star, plus the ways in — open from
/// Files, scan paper with the document camera, merge several PDFs
/// into one, and Settings.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var showingPicker = false
    @State private var showingMergePicker = false
    @State private var showingSettings = false
    @State private var showingScanner = false
    @State private var showingPhotoPicker = false
    @State private var scanNotice: ScanNotice?
    @State private var mergeSelection: Set<UUID> = []
    @State private var mergeMode = false
    @State private var importError: String?
    @State private var autoOpen: RecentDocument?
    @State private var pendingOCREntry: RecentDocument?
    @State private var showOCROffer = false
    @State private var ocrSink: ProgressSink?
    @State private var ocrRunning = false
    @State private var ocrDone = 0
    @State private var ocrTotal = 1

    var body: some View {
        Group {
            if library.recents.isEmpty && !mergeMode {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle("PDF Viewer & Editor")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        scanTapped()
                    } label: {
                        Label("Scan Document", systemImage: "doc.viewfinder")
                    }
                    Button {
                        showingPicker = true
                    } label: {
                        Label("Open PDF…", systemImage: "folder")
                    }
                    Button {
                        showingPhotoPicker = true
                    } label: {
                        Label("Photos to PDF…", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        mergeMode = true
                        mergeSelection = []
                    } label: {
                        Label("Merge PDFs…", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .sheet(isPresented: $showingPicker) {
            DocumentPicker { urls in
                importPicked(urls)
            }
        }
        .sheet(isPresented: $showingPhotoPicker) {
            PhotoPicker { images in
                finishPhotos(images)
            }
        }
        .confirmationDialog("Saved to Your Library",
                            isPresented: $showOCROffer,
                            presenting: pendingOCREntry) { entry in
            Button("Make Searchable (OCR)") {
                runLibraryOCR(entry)
            }
            Button("Open It") {
                autoOpen = entry
            }
            Button("Later", role: .cancel) {}
        } message: { _ in
            Text("This document is pictures of pages, so its words can't be searched or copied yet. Make Searchable (OCR) recognizes the text on this device and saves a searchable copy.")
        }
        .sheet(isPresented: $ocrRunning) {
            NavigationStack {
                VStack(spacing: 14) {
                    ProgressView(value: Double(ocrDone), total: Double(max(ocrTotal, 1)))
                    Text("Recognizing text — page \(min(ocrDone + 1, max(ocrTotal, 1))) of \(max(ocrTotal, 1))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Cancel", role: .destructive) {
                        ocrSink?.cancel()
                    }
                }
                .padding()
                .navigationTitle("Make Searchable (OCR)")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .fullScreenCover(isPresented: $showingScanner) {
            DocumentScanner { images in
                finishScan(images)
            } onCancel: {
                // Back to the library; no document is created.
            } onError: { error in
                scanNotice = ScanNotice(
                    title: "Scanning Didn't Work",
                    message: error.localizedDescription,
                    offerSettings: false)
            }
            .ignoresSafeArea()
        }
        .alert(scanNotice?.title ?? "", isPresented: Binding(
            get: { scanNotice != nil },
            set: { if !$0 { scanNotice = nil } }
        )) {
            if scanNotice?.offerSettings == true {
                Button("Open Settings") {
                    scanNotice = nil
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Not Now", role: .cancel) { scanNotice = nil }
            } else {
                Button("OK", role: .cancel) { scanNotice = nil }
            }
        } message: {
            Text(scanNotice?.message ?? "")
        }
        .alert("Couldn't Open That File", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .navigationDestination(item: $autoOpen) { entry in
            ReaderView(entry: entry, library: library)
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No PDFs Yet", systemImage: "doc.richtext")
        } description: {
            Text("Open a PDF from Files or iCloud Drive and it will live here, ready to read and edit.")
        } actions: {
            Button("Scan Document") { scanTapped() }
                .buttonStyle(.borderedProminent)
            Button("Open PDF…") { showingPicker = true }
                .buttonStyle(.bordered)
        }
    }

    private var list: some View {
        List {
            if mergeMode {
                Section {
                    Text("Tap two or more PDFs, then Merge. A new combined document is created — the originals stay as they are.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Merge \(mergeSelection.count) Selected") {
                        finishMerge()
                    }
                    .disabled(mergeSelection.count < 2)
                    Button("Cancel", role: .cancel) {
                        mergeMode = false
                        mergeSelection = []
                    }
                }
            }

            Section {
                ForEach(library.recents) { entry in
                    row(for: entry)
                }
                .onDelete { offsets in
                    for offset in offsets { library.delete(library.recents[offset]) }
                }
            } header: {
                Text(mergeMode ? "Choose PDFs to Merge" : "Recent")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func row(for entry: RecentDocument) -> some View {
        if mergeMode {
            Button {
                if mergeSelection.contains(entry.id) {
                    mergeSelection.remove(entry.id)
                } else {
                    mergeSelection.insert(entry.id)
                }
            } label: {
                HStack {
                    rowContent(for: entry)
                    Spacer()
                    Image(systemName: mergeSelection.contains(entry.id)
                          ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                ReaderView(entry: entry, library: library)
            } label: {
                rowContent(for: entry)
            }
            .swipeActions(edge: .leading) {
                Button {
                    library.toggleFavorite(entry)
                } label: {
                    Label(entry.isFavorite ? "Unfavorite" : "Favorite",
                          systemImage: entry.isFavorite ? "star.slash" : "star")
                }
                .tint(.yellow)
            }
        }
    }

    private func rowContent(for entry: RecentDocument) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.richtext")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if entry.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                    }
                }
                Text("\(entry.pageCount) pages · Last opened \(entry.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func importPicked(_ urls: [URL]) {
        for url in urls {
            do {
                _ = try library.importPDF(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func finishMerge() {
        let chosen = library.recents.filter { mergeSelection.contains($0.id) }
        // Keep the library's recency order for the merge sequence.
        guard chosen.count >= 2, let merged = library.merge(documents: chosen) else {
            importError = "Those PDFs couldn't be merged."
            return
        }
        mergeMode = false
        mergeSelection = []
        autoOpen = merged
    }

    // MARK: - Scanning

    /// The Scan action: explains itself instead of dead-ending when
    /// the hardware can't scan or camera access is off, and otherwise
    /// presents Apple's document camera.
    private func scanTapped() {
        guard DocumentScanner.isSupported else {
            scanNotice = ScanNotice(
                title: "Scanning Isn't Available",
                message: "The document scanner needs a camera, so it isn't available on this device. You can still open PDFs from Files.",
                offerSettings: false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            scanNotice = ScanNotice(
                title: "Camera Access Is Off",
                message: "PDF Viewer & Editor needs the camera to scan documents. Turn on Camera for the app in Settings, then try again.",
                offerSettings: true)
        default:
            showingScanner = true
        }
    }

    /// A finished scan becomes a library document, then offers OCR.
    /// An empty scan (no pages) creates nothing.
    private func finishScan(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        if let entry = library.importScan(images: images, name: Self.scanName()) {
            offerOCR(for: entry)
        } else {
            importError = "That scan couldn't be saved as a PDF."
        }
    }

    /// Picked photos become a library document (one image per page)
    /// through the same offer-OCR landing as a scan.
    private func finishPhotos(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        if let entry = library.importImages(images: images, name: Self.photoName()) {
            offerOCR(for: entry)
        } else {
            importError = "Those photos couldn't be saved as a PDF."
        }
    }

    /// Image-built PDFs are pictures of pages until a text layer is
    /// added, so every scan / photos import lands here first.
    private func offerOCR(for entry: RecentDocument) {
        pendingOCREntry = entry
        showOCROffer = true
    }

    /// Runs OCR on a just-imported image-built document, with
    /// progress and cancellation. Success opens the searchable
    /// copy; cancelling or failing opens the original document —
    /// the import itself is never lost.
    private func runLibraryOCR(_ entry: RecentDocument) {
        guard let document = library.openDocument(entry) else {
            autoOpen = entry
            return
        }
        let sink = ProgressSink()
        sink.onProgress = { done, total in
            DispatchQueue.main.async {
                ocrDone = done
                ocrTotal = max(total, 1)
            }
        }
        ocrSink = sink
        ocrDone = 0
        ocrTotal = document.pageCount
        ocrRunning = true
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                PDFTools.ocrDocument(document, sink: sink)
            }.value
            ocrRunning = false
            ocrSink = nil
            if !sink.cancelled, let output,
               let created = library.registerDocument(output,
                                                      name: entry.name + " (Searchable)") {
                autoOpen = created
            } else {
                autoOpen = entry
            }
        }
    }

    /// Default name for a scanned document, e.g. "Scan 2026-11-16 17:45".
    private static func scanName() -> String {
        "Scan " + Self.timestamp()
    }

    /// Default name for a photos-built document.
    private static func photoName() -> String {
        "Photos " + Self.timestamp()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date())
    }
}

/// A short message about scanning — unavailable hardware, camera
/// permission off, or a scanner error — optionally with a shortcut
/// to the app's page in Settings.
private struct ScanNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let offerSettings: Bool
}
