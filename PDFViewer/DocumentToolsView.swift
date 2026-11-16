import PDFKit
import SwiftUI

/// The PDF Tools sheet: the Acrobat-style operations on the open
/// document — Make Searchable (OCR), Compress, Split, Export Pages
/// as Images, and Password (protect / remove). Every tool works on
/// a fresh copy of the library file and saves its result as a NEW
/// library document; the document being read is never changed by a
/// tool. (Redact and Cover & Replace Text live in the reader's Edit
/// menu instead, because they are drawn on the page.)
struct DocumentToolsView: View {
    @ObservedObject var controller: ReaderController
    let library: LibraryStore
    /// Hand share-sheet items (exported PNG files) to the reader,
    /// which presents the share sheet once this sheet has dismissed.
    var onShareItems: ([Any]) -> Void
    /// Open a tool-produced library document in a new reader.
    var onOpenCreated: (RecentDocument) -> Void

    @Environment(\.dismiss) private var dismiss

    // Job state
    @State private var sink: ProgressSink?
    @State private var busyLabel: String?
    @State private var progressDone = 0
    @State private var progressTotal = 1
    @State private var resultEntry: RecentDocument?
    @State private var resultNote: String?
    @State private var errorText: String?

    // Tool inputs
    @State private var compressQuality: PDFTools.CompressQuality = .balanced
    @State private var splitFrom = 1
    @State private var splitTo = 1
    @State private var exportFrom = 1
    @State private var exportTo = 1
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var currentPassword = ""

    private var isBusy: Bool { busyLabel != nil }
    private var isLocked: Bool { controller.document.isLocked }
    private var isEncrypted: Bool { controller.document.isEncrypted }
    private var pageCount: Int { max(controller.pageCount, 1) }

    var body: some View {
        NavigationStack {
            Form {
                if isBusy {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(busyLabel ?? "")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            ProgressView(value: Double(progressDone),
                                         total: Double(progressTotal))
                            HStack {
                                Text("Page \(min(progressDone + 1, progressTotal)) of \(progressTotal)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Cancel", role: .destructive) {
                                    sink?.cancel()
                                }
                                .font(.caption)
                                .fontWeight(.semibold)
                            }
                        }
                    }
                }

                if let entry = resultEntry {
                    Section("Saved to Your Library") {
                        Text(entry.name)
                            .fontWeight(.medium)
                        if let note = resultNote {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("Open the Copy") {
                            onOpenCreated(entry)
                            dismiss()
                        }
                    }
                } else if let note = resultNote {
                    Section {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = errorText {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if isLocked {
                    Section {
                        Text("This document is locked with a password. Unlock it to read it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    protectSection
                } else if isEncrypted {
                    Section {
                        Text("This document is password-protected, and the tools work on the saved file — which is still locked even while you read the unlocked copy here. Save an unlocked copy below, then run the tools on that copy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    protectSection
                } else {
                    ocrSection
                    compressSection
                    splitSection
                    exportSection
                    protectSection
                }
            }
            .navigationTitle("PDF Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(isBusy)
                }
            }
            .onAppear {
                if splitTo == 1 { splitTo = pageCount }
                if exportTo == 1 { exportTo = pageCount }
            }
        }
    }

    // MARK: - Sections

    private var ocrSection: some View {
        Section {
            Button {
                runOCR()
            } label: {
                Label("Make Searchable (OCR)", systemImage: "text.viewfinder")
            }
            .disabled(isBusy)
        } header: {
            Text("Searchable Text")
        } footer: {
            Text("For scans and image-only PDFs: recognizes the words on each page, on this device, and saves a copy with an invisible text layer — so search, text selection, and copy work. Pages that already have text are left as they are.")
        }
    }

    private var compressSection: some View {
        Section {
            Picker("Quality", selection: $compressQuality) {
                ForEach(PDFTools.CompressQuality.allCases) { quality in
                    Text(quality.label).tag(quality)
                }
            }
            Button {
                runCompress()
            } label: {
                Label("Compress a Copy", systemImage: "rectangle.compress.vertical")
            }
            .disabled(isBusy)
        } header: {
            Text("Compress")
        } footer: {
            Text("Rebuilds the document with each page as an image at the chosen quality — the classic way to shrink a scan-heavy PDF for email. Text in the copy is no longer selectable, and a document that is already lean text can come out bigger; you'll see the before and after sizes either way.")
        }
    }

    private var splitSection: some View {
        Section {
            Stepper("From page \(splitFrom)", value: $splitFrom, in: 1...pageCount)
                .onChange(of: splitFrom) { _, newValue in
                    if splitTo < newValue { splitTo = newValue }
                }
            Stepper("To page \(splitTo)", value: $splitTo, in: 1...pageCount)
                .onChange(of: splitTo) { _, newValue in
                    if splitFrom > newValue { splitFrom = newValue }
                }
            Button {
                runSplit()
            } label: {
                Label("Extract Pages as New PDF", systemImage: "scissors")
            }
            .disabled(isBusy)
        } header: {
            Text("Split")
        } footer: {
            Text("Saves the chosen page range as its own document in your library. This document keeps all its pages.")
        }
    }

    private var exportSection: some View {
        Section {
            Stepper("From page \(exportFrom)", value: $exportFrom, in: 1...pageCount)
                .onChange(of: exportFrom) { _, newValue in
                    if exportTo < newValue { exportTo = newValue }
                }
            Stepper("To page \(exportTo)", value: $exportTo, in: 1...pageCount)
                .onChange(of: exportTo) { _, newValue in
                    if exportFrom > newValue { exportFrom = newValue }
                }
            Button {
                runExportImages()
            } label: {
                Label("Export Pages as PNG Images", systemImage: "photo.on.rectangle")
            }
            .disabled(isBusy)
        } header: {
            Text("Convert")
        } footer: {
            Text("Renders the chosen pages as PNG images and opens the share sheet — save them to Photos, send them, or drop them into another app. To turn photos into a PDF instead, use Photos to PDF in the library's + menu.")
        }
    }

    @ViewBuilder
    private var protectSection: some View {
        Section {
            if isLocked {
                SecureField("Document password", text: $currentPassword)
                    .textContentType(.password)
                Button {
                    unlockForReading()
                } label: {
                    Label("Unlock to Read", systemImage: "lock.open")
                }
                .disabled(currentPassword.isEmpty || isBusy)
            } else if isEncrypted {
                SecureField("Document password", text: $currentPassword)
                    .textContentType(.password)
                Button {
                    runUnlockCopy()
                } label: {
                    Label("Save Unlocked Copy", systemImage: "lock.open")
                }
                .disabled(currentPassword.isEmpty || isBusy)
            } else {
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("Type it again", text: $confirmPassword)
                    .textContentType(.newPassword)
                if !confirmPassword.isEmpty && confirmPassword != newPassword {
                    Text("The two passwords don't match.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Button {
                    runProtect()
                } label: {
                    Label("Save Password-Protected Copy", systemImage: "lock.doc")
                }
                .disabled(newPassword.isEmpty || newPassword != confirmPassword || isBusy)
            }
        } header: {
            Text("Password")
        } footer: {
            Text(protectFooter)
        }
    }

    private var protectFooter: String {
        if isLocked {
            return "Unlocking lasts for this reading session — the file in your library keeps its password. To keep an unlocked copy, unlock first, then use Save Unlocked Copy."
        }
        if isEncrypted {
            return "Saves a copy of this document with no password at all. The document you're reading keeps its password."
        }
        return "Saves a copy that asks for this password before it will open. This document stays unprotected. Keep the password somewhere safe — it can't be recovered from the file."
    }

    // MARK: - Job plumbing

    /// The tools always start from the saved library file (with any
    /// pending reader edits flushed first), never the live document.
    private func freshDocument() -> PDFDocument? {
        controller.persistEdits()
        return library.openDocument(controller.entry)
    }

    private func beginJob(_ label: String, total: Int) -> ProgressSink {
        let sink = ProgressSink()
        sink.onProgress = { done, total in
            DispatchQueue.main.async {
                progressDone = done
                progressTotal = max(total, 1)
            }
        }
        self.sink = sink
        busyLabel = label
        progressDone = 0
        progressTotal = max(total, 1)
        resultEntry = nil
        resultNote = nil
        errorText = nil
        return sink
    }

    private func jobSucceeded(entry: RecentDocument, note: String?) {
        busyLabel = nil
        sink = nil
        resultEntry = entry
        resultNote = note
        errorText = nil
    }

    private func jobFailed(_ message: String) {
        busyLabel = nil
        sink = nil
        errorText = message
    }

    private func fileSize(of entry: RecentDocument) -> Int {
        let url = library.fileURL(for: entry)
        return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Actions

    private func runOCR() {
        guard let source = freshDocument() else {
            jobFailed("Couldn't open this document.")
            return
        }
        let sink = beginJob("Making searchable…", total: source.pageCount)
        let name = controller.entry.name + " (Searchable)"
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                PDFTools.ocrDocument(source, sink: sink)
            }.value
            if sink.cancelled {
                jobFailed("Cancelled — no copy was saved.")
            } else if let output,
                      let entry = library.registerDocument(output, name: name) {
                jobSucceeded(entry: entry,
                             note: "Search, text selection, and copy now work on the copy.")
            } else {
                jobFailed("OCR didn't work on this document.")
            }
        }
    }

    private func runCompress() {
        guard let source = freshDocument() else {
            jobFailed("Couldn't open this document.")
            return
        }
        let before = fileSize(of: controller.entry)
        let quality = compressQuality
        let sink = beginJob("Compressing…", total: source.pageCount)
        let name = controller.entry.name + " (Compressed)"
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                PDFTools.compressedDocument(source, quality: quality, sink: sink)
            }.value
            if sink.cancelled {
                jobFailed("Cancelled — no copy was saved.")
            } else if let output,
                      let entry = library.registerDocument(output, name: name) {
                let after = fileSize(of: entry)
                jobSucceeded(entry: entry,
                             note: "Size: \(formatBytes(before)) → \(formatBytes(after)).")
            } else {
                jobFailed("Compressing didn't work on this document.")
            }
        }
    }

    private func runSplit() {
        guard let source = freshDocument() else {
            jobFailed("Couldn't open this document.")
            return
        }
        let indexes = Array((splitFrom - 1)...(splitTo - 1))
        guard let output = PDFTools.extractedDocument(source, pageIndexes: indexes) else {
            jobFailed("Those pages couldn't be extracted.")
            return
        }
        let name = "\(controller.entry.name) pages \(splitFrom)–\(splitTo)"
        if let entry = library.registerDocument(output, name: name) {
            jobSucceeded(entry: entry, note: nil)
        } else {
            jobFailed("The extracted copy couldn't be saved.")
        }
    }

    private func runExportImages() {
        guard let source = freshDocument() else {
            jobFailed("Couldn't open this document.")
            return
        }
        let indexes = Array((exportFrom - 1)...(exportTo - 1))
        let sink = beginJob("Exporting pages…", total: indexes.count)
        Task {
            let rendered = await Task.detached(priority: .userInitiated) {
                PDFTools.pageImages(source, pageIndexes: indexes, sink: sink)
            }.value
            busyLabel = nil
            self.sink = nil
            if sink.cancelled {
                jobFailed("Cancelled.")
                return
            }
            var urls: [URL] = []
            for (pageIndex, image) in rendered {
                guard let data = image.pngData() else { continue }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(controller.entry.name) page \(pageIndex + 1).png")
                if (try? data.write(to: url)) != nil {
                    urls.append(url)
                }
            }
            if urls.isEmpty {
                jobFailed("No pages could be exported.")
            } else {
                onShareItems(urls.map { $0 as Any })
                dismiss()
            }
        }
    }

    private func runProtect() {
        let password = newPassword
        guard !password.isEmpty, password == confirmPassword else { return }
        guard let source = freshDocument() else {
            jobFailed("Couldn't open this document.")
            return
        }
        let name = controller.entry.name + " (Protected)"
        let options: [PDFDocumentWriteOption: Any] = [
            .userPasswordOption: password,
            .ownerPasswordOption: password,
        ]
        if let entry = library.registerDocument(source, name: name, writeOptions: options) {
            newPassword = ""
            confirmPassword = ""
            jobSucceeded(entry: entry,
                         note: "The copy asks for this password before it opens.")
        } else {
            jobFailed("The protected copy couldn't be saved.")
        }
    }

    private func unlockForReading() {
        if controller.unlock(password: currentPassword) {
            currentPassword = ""
            resultEntry = nil
            resultNote = "Unlocked for this reading session. The file in your library still has its password."
            errorText = nil
        } else {
            jobFailed("That password didn't unlock this document.")
        }
    }

    private func runUnlockCopy() {
        let password = currentPassword
        guard !password.isEmpty else { return }
        guard let source = library.openDocument(controller.entry) else {
            jobFailed("Couldn't open this document.")
            return
        }
        if source.isLocked && !source.unlock(withPassword: password) {
            jobFailed("That password didn't unlock this document.")
            return
        }
        // Rebuild into a fresh document: writing the document that
        // came from the encrypted file would keep its encryption.
        let rebuilt = PDFTools.rebuiltDocument(from: source)
        let name = controller.entry.name + " (Unlocked)"
        if let entry = library.registerDocument(rebuilt, name: name) {
            currentPassword = ""
            jobSucceeded(entry: entry,
                         note: "The copy opens with no password. This document keeps its password.")
        } else {
            jobFailed("The unlocked copy couldn't be saved.")
        }
    }
}
