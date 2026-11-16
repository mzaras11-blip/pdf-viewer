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
    @State private var showingTools = false
    @State private var showingUnlock = false
    @State private var placingSignature: UIImage?
    @State private var pendingText: PendingText?
    @State private var pendingCover: PendingCover?
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var pendingShareItems: [Any]?
    @State private var pendingCreated: RecentDocument?
    @State private var createdToOpen: RecentDocument?
    @State private var localError: String?
    @State private var notice: String?

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
            || tool == .redact || tool == .coverText
            || placingSignature != nil
            || showingSearch || showingThumbnails || showingOutline
            || showingBookmarks || showingSettings || showingSignaturePad
            || showingTools || showingUnlock
            || pendingText != nil || pendingCover != nil || showingShare
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

            if tool == .redact || tool == .coverText {
                rectDragCatcher
            }

            VStack {
                if tool == .text || tool == .note || tool == .erase
                    || tool == .redact || tool == .coverText {
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
        .sheet(item: $pendingCover) { pending in
            TextAnnotationEditor(
                title: "Replace Text",
                prompt: "Type the replacement text. It goes on top of a patch painted in the page's own background color, covering the words you dragged over. The original words stay in the file underneath — for secrets, use Redact instead."
            ) { text in
                controller.coverAndRetype(text: text, rect: pending.rect, on: pending.page)
                setTool(.none)
            }
        }
        .sheet(isPresented: $showingTools, onDismiss: {
            if let items = pendingShareItems {
                pendingShareItems = nil
                shareItems = items
                showingShare = true
            }
            if let created = pendingCreated {
                pendingCreated = nil
                createdToOpen = created
            }
        }) {
            DocumentToolsView(controller: controller, library: library,
                              onShareItems: { items in pendingShareItems = items },
                              onOpenCreated: { created in pendingCreated = created })
        }
        .sheet(isPresented: $showingUnlock) {
            UnlockSheet(controller: controller)
        }
        .sheet(isPresented: $showingShare) { ShareSheet(items: shareItems) }
        .navigationDestination(item: $createdToOpen) { created in
            ReaderView(entry: created, library: library)
        }
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
        .alert("PDF Viewer & Editor", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        )) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .onAppear {
            if controller.document.isLocked {
                showingUnlock = true
            }
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
                    showingTools = true
                } label: {
                    Label("PDF Tools…", systemImage: "doc.badge.gearshape")
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
            Section("Fix & Hide") {
                Button {
                    setTool(.coverText)
                } label: {
                    Label("Cover & Replace Text…", systemImage: "pencil.and.outline")
                }
                Button {
                    setTool(.redact)
                } label: {
                    Label("Redact…", systemImage: "eye.slash")
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
            if tool == .redact && controller.pendingRedactionCount > 0 {
                Button("Clear") { controller.clearRedactions() }
                    .font(.footnote)
                Button("Apply") {
                    if controller.applyRedactions() {
                        notice = "Redactions applied. The covered text is permanently removed from this document — the pages were rebuilt as pictures with the black boxes burned in."
                    }
                    setTool(.none)
                }
                .font(.footnote)
                .fontWeight(.semibold)
            }
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
        case .coverText: return "Drag over the words to cover, then type the replacement."
        case .redact:
            let count = controller.pendingRedactionCount
            return count == 0
                ? "Drag over anything sensitive to box it out."
                : "\(count) box\(count == 1 ? "" : "es") drawn — nothing is hidden until you tap Apply."
        default: return ""
        }
    }

    // MARK: - Rectangle drag tools (redact / cover & retype)

    /// Full-page drag surface for the rectangle tools. While one is
    /// armed the page underneath can't scroll or zoom (the same
    /// trade the placement tools make), so view↔page conversion is
    /// stable. For Redact it also draws the boxes already committed
    /// on the current page.
    private var rectDragCatcher: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            if tool == .redact,
               let pdfView = controller.pdfView,
               let page = controller.currentPage {
                ForEach(Array(controller.redactions(on: controller.currentPageIndex).enumerated()),
                        id: \.offset) { _, rect in
                    let viewRect = pdfView.convert(rect, from: page)
                    Rectangle()
                        .fill(Color.black.opacity(0.85))
                        .frame(width: viewRect.width, height: viewRect.height)
                        .position(x: viewRect.midX, y: viewRect.midY)
                }
            }

            if let start = dragStart, let current = dragCurrent {
                let rect = CGRect(x: min(start.x, current.x),
                                  y: min(start.y, current.y),
                                  width: abs(start.x - current.x),
                                  height: abs(start.y - current.y))
                Rectangle()
                    .fill(tool == .redact ? Color.black.opacity(0.55)
                          : Color.white.opacity(0.65))
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStart == nil { dragStart = value.startLocation }
                    dragCurrent = value.location
                }
                .onEnded { value in
                    let start = dragStart
                    dragStart = nil
                    dragCurrent = nil
                    if let start {
                        finishRectDrag(from: start, to: value.location)
                    }
                }
        )
    }

    /// Turns a finished drag into a page-space rectangle and routes
    /// it: a pending redaction box, or the cover & retype editor.
    private func finishRectDrag(from start: CGPoint, to end: CGPoint) {
        guard let pdfView = controller.pdfView,
              let page = pdfView.page(for: start, nearest: true) else { return }
        let a = pdfView.convert(start, to: page)
        let b = pdfView.convert(end, to: page)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(a.x - b.x), height: abs(a.y - b.y))
        guard rect.width >= 8, rect.height >= 8 else { return }
        switch tool {
        case .redact:
            controller.addRedactionBox(rect, pageIndex: controller.document.index(for: page))
        case .coverText:
            pendingCover = PendingCover(rect: rect, page: page)
        default:
            break
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
        if tool == .redact, newTool == .none, controller.pendingRedactionCount > 0 {
            // Leaving Redact without Apply throws the boxes away —
            // say so, because on screen they looked like redactions.
            controller.clearRedactions()
            notice = "Redaction boxes discarded — nothing was hidden. Boxes only become permanent when you tap Apply."
        }
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

/// Identifiable payload for the cover & retype editor sheet.
private struct PendingCover: Identifiable {
    let id = UUID()
    let rect: CGRect
    let page: PDFPage
}

/// Small editor sheet for the contents of a text box or sticky note.
private struct TextAnnotationEditor: View {
    var isNote: Bool = false
    var title: String?
    var prompt: String?
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var resolvedTitle: String {
        title ?? (isNote ? "Sticky Note" : "Text Box")
    }

    private var resolvedPrompt: String {
        prompt ?? (isNote ? "Write your note:" : "Write the text for the box:")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(resolvedPrompt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.35)))
                Spacer()
            }
            .padding()
            .navigationTitle(resolvedTitle)
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

/// Password prompt shown when a locked document is opened.
/// Unlocking is for this reading session only; the PDF Tools sheet
/// can save a permanently unlocked copy.
private struct UnlockSheet: View {
    @ObservedObject var controller: ReaderController
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Label("This document is password-protected.", systemImage: "lock.doc")
                    .font(.headline)
                Text("Enter its password to read it. Unlocking lasts for this visit — the file in your library keeps its password. (PDF Tools can save an unlocked copy.)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { attempt() }
                if failed {
                    Text("That password didn't unlock this document.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Unlock Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock") { attempt() }
                        .fontWeight(.semibold)
                        .disabled(password.isEmpty)
                }
            }
        }
    }

    private func attempt() {
        if controller.unlock(password: password) {
            dismiss()
        } else {
            failed = true
        }
    }
}
