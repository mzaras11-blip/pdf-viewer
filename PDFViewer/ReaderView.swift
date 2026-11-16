import SwiftUI
import PDFKit

/// The reader screen: the native PDFView, the reading/editing
/// toolbars, and every editing flow (markup, drawing, text, notes,
/// signature, erase) plus search / thumbnails / outline / bookmarks.
///
/// Ad wiring lives here too: while this screen is up it registers a
/// document session with AdManager (so the 5-minute usage timer runs),
/// blocks the timer whenever an interaction is in progress, and
/// registers the page guard that restores the reader's exact page
/// after a timed interstitial.
struct ReaderView: View {
    let entry: RecentDocument
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var controller: ReaderController

    @AppStorage("readingBackground") private var readingBackgroundRaw = ReadingBackground.white.rawValue
    @AppStorage("singlePageMode") private var singlePageMode = false

    @State private var tool: ReaderTool = .none
    @State private var showingSearch = false
    @State private var showingThumbnails = false
    @State private var showingOutline = false
    @State private var showingBookmarks = false
    @State private var showingSettings = false
    @State private var showingSignaturePad = false
    @State private var placingSignature: UIImage?
    @State private var pendingText: PendingText?
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var localError: String?

    init(entry: RecentDocument, library: LibraryStore) {
        self.entry = entry
        _controller = StateObject(wrappedValue: ReaderController(entry: entry, library: library))
    }

    private var readingBackground: ReadingBackground {
        ReadingBackground(rawValue: readingBackgroundRaw) ?? .white
    }

    /// Anything that should pause the ad usage timer / defer a due
    /// interstitial: an editing mode, a placement in progress, or any
    /// sheet or picker on screen.
    private var adsBlocked: Bool {
        tool == .draw || tool == .text || tool == .note || tool == .erase
            || placingSignature != nil
            || showingSearch || showingThumbnails || showingOutline
            || showingBookmarks || showingSettings || showingSignaturePad
            || pendingText != nil || showingShare
    }

    var body: some View {
        ZStack {
            PDFKitView(controller: controller,
                       readingBackground: readingBackground,
                       singlePageMode: singlePageMode)

            if tool == .draw {
                DrawingOverlayView(controller: controller) { setTool(.none) }
            }

            if let image = placingSignature {
                SignaturePlacementView(image: image) { rect in
                    controller.stampSignature(image: image, viewRect: rect)
                    placingSignature = nil
                    setTool(.none)
                } onCancel: {
                    placingSignature = nil
                    setTool(.none)
                }
            }

            if tool == .text || tool == .note || tool == .erase {
                placementTapCatcher
            }

            VStack {
                if tool == .text || tool == .note || tool == .erase {
                    modeHintBar
                }
                Spacer()
                pageIndicator
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { readerToolbar }
        .toolbar(.visible, for: .bottomBar)
        .sheet(isPresented: $showingSearch) { SearchView(controller: controller) }
        .sheet(isPresented: $showingThumbnails) { ThumbnailsView(controller: controller) }
        .sheet(isPresented: $showingOutline) { OutlineView(controller: controller) }
        .sheet(isPresented: $showingBookmarks) { BookmarksView(controller: controller, library: library) }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingSignaturePad) {
            SignaturePadView { image in
                placingSignature = image
            }
        }
        .sheet(item: $pendingText) { pending in
            TextAnnotationEditor(isNote: pending.isNote) { text in
                if pending.isNote {
                    controller.addNote(text: text, at: pending.point, on: pending.page)
                } else {
                    controller.addTextBox(text: text, at: pending.point, on: pending.page)
                }
            }
        }
        .sheet(isPresented: $showingShare) { ShareSheet(items: shareItems) }
        .alert("PDF Viewer & Editor", isPresented: Binding(
            get: { controller.lastError != nil || localError != nil },
            set: { if !$0 { controller.lastError = nil; localError = nil } }
        )) {
            Button("OK", role: .cancel) {
                controller.lastError = nil
                localError = nil
            }
        } message: {
            Text(controller.lastError ?? localError ?? "")
        }
        .onAppear {
            AdManager.shared.sessionActive = true
            AdManager.shared.pageGuard = (
                read: { controller.currentPageIndex },
                restore: { page in controller.goToPage(page) }
            )
            AdManager.shared.uiBlocked = adsBlocked
        }
        .onDisappear {
            controller.persistEdits()
            library.touch(entry, page: controller.currentPageIndex)
            AdManager.shared.sessionActive = false
            AdManager.shared.uiBlocked = false
            AdManager.shared.pageGuard = nil
        }
        .onChange(of: adsBlocked) { _, blocked in
            AdManager.shared.uiBlocked = blocked
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button {
                showingThumbnails = true
            } label: {
                Label("Pages", systemImage: "square.grid.2x2")
            }
            Spacer()
            Button {
                showingSearch = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            Spacer()
            Button {
                library.toggleBookmark(documentID: entry.id,
                                       pageIndex: controller.currentPageIndex,
                                       documentName: entry.name)
            } label: {
                Label("Bookmark", systemImage: library.isBookmarked(documentID: entry.id,
                                                                     pageIndex: controller.currentPageIndex)
                      ? "bookmark.fill" : "bookmark")
            }
            Spacer()
            editMenu
            Spacer()
            Button {
                if let url = controller.exportURL() {
                    shareItems = [url]
                    showingShare = true
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if controller.hasOutline {
                    Button {
                        showingOutline = true
                    } label: {
                        Label("Contents", systemImage: "list.bullet")
                    }
                }
                Button {
                    showingBookmarks = true
                } label: {
                    Label("Bookmarks", systemImage: "bookmarks")
                }
                Button {
                    singlePageMode.toggle()
                } label: {
                    Label(singlePageMode ? "Continuous Scrolling" : "One Page at a Time",
                          systemImage: singlePageMode ? "doc.on.doc" : "doc")
                }
                if controller.isDirty {
                    Button {
                        controller.persistEdits()
                    } label: {
                        Label("Save Changes", systemImage: "square.and.arrow.down")
                    }
                }
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var editMenu: some View {
        Menu {
            Section("Mark Up Selection") {
                ForEach(highlightColors) { choice in
                    Button {
                        if !controller.applyMarkup(type: .highlight, color: choice.color) {
                            localError = "Select some text first, then choose Highlight."
                        }
                    } label: {
                        Label("Highlight in \(choice.name)", systemImage: "highlighter")
                    }
                }
                Button {
                    if !controller.applyMarkup(type: .underline, color: .systemRed) {
                        localError = "Select some text first, then choose Underline."
                    }
                } label: {
                    Label("Underline", systemImage: "underline")
                }
            }
            Section("Add") {
                Button {
                    setTool(.draw)
                } label: {
                    Label("Draw", systemImage: "scribble.variable")
                }
                Button {
                    setTool(.text)
                } label: {
                    Label("Text Box", systemImage: "textbox")
                }
                Button {
                    setTool(.note)
                } label: {
                    Label("Sticky Note", systemImage: "note.text")
                }
                Button {
                    beginSignature()
                } label: {
                    Label("Signature", systemImage: "signature")
                }
                if SignatureStore.load() != nil {
                    Button {
                        showingSignaturePad = true
                    } label: {
                        Label("Redraw Signature", systemImage: "pencil.line")
                    }
                }
            }
            Section {
                Button(role: .destructive) {
                    setTool(.erase)
                } label: {
                    Label("Erase Annotations", systemImage: "eraser")
                }
            }
        } label: {
            Label("Edit", systemImage: "pencil.tip.crop.circle")
        }
    }

    private struct HighlightChoice: Identifiable {
        let name: String
        let color: UIColor
        var id: String { name }
    }

    private var highlightColors: [HighlightChoice] {
        [HighlightChoice(name: "Yellow", color: UIColor.systemYellow.withAlphaComponent(0.45)),
         HighlightChoice(name: "Green", color: UIColor.systemGreen.withAlphaComponent(0.40)),
         HighlightChoice(name: "Pink", color: UIColor.systemPink.withAlphaComponent(0.35)),
         HighlightChoice(name: "Blue", color: UIColor.systemBlue.withAlphaComponent(0.35))]
    }

    // MARK: - Overlays

    private var pageIndicator: some View {
        Text("Page \(controller.currentPageIndex + 1) of \(max(controller.pageCount, 1))")
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 6)
    }

    private var modeHintBar: some View {
        HStack(spacing: 10) {
            Text(hintText)
                .font(.footnote)
                .fontWeight(.medium)
            Spacer()
            Button("Done") { setTool(.none) }
                .font(.footnote)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.top, 6)
    }

    private var hintText: String {
        switch tool {
        case .text: return "Tap the page to place a text box."
        case .note: return "Tap the page to drop a sticky note."
        case .erase: return "Tap an annotation to erase it."
        default: return ""
        }
    }

    /// Transparent layer that turns taps into page-space placements
    /// while a placement tool is armed.
    private var placementTapCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onEnded { value in
                    handlePlacementTap(at: value.location)
                }
            )
    }

    private func handlePlacementTap(at viewPoint: CGPoint) {
        guard let pdfView = controller.pdfView,
              let page = pdfView.page(for: viewPoint, nearest: true) else { return }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        switch tool {
        case .erase:
            if !controller.eraseAnnotation(at: pagePoint, on: page) {
                localError = "No annotation there — tap directly on a highlight, drawing, note or text box."
            }
        case .text:
            pendingText = PendingText(isNote: false, point: pagePoint, page: page)
        case .note:
            pendingText = PendingText(isNote: true, point: pagePoint, page: page)
        default:
            break
        }
    }

    // MARK: - Helpers

    private func setTool(_ newTool: ReaderTool) {
        let wasEditing = tool == .draw || tool == .text || tool == .note || tool == .erase
        tool = newTool
        if wasEditing, newTool == .none {
            controller.persistEdits()
        }
    }

    private func beginSignature() {
        if let saved = SignatureStore.load() {
            placingSignature = saved
        } else {
            showingSignaturePad = true
        }
    }
}

/// Identifiable payload for the text/note editor sheet.
private struct PendingText: Identifiable {
    let id = UUID()
    let isNote: Bool
    let point: CGPoint
    let page: PDFPage
}

/// Small editor sheet for the contents of a text box or sticky note.
private struct TextAnnotationEditor: View {
    var isNote: Bool
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(isNote ? "Write your note:" : "Write the text for the box:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.35)))
                Spacer()
            }
            .padding()
            .navigationTitle(isNote ? "Sticky Note" : "Text Box")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { onSave(trimmed) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
