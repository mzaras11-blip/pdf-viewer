import SwiftUI

/// The home screen: the reader's library. Recents sorted by last
/// opened, favorites pinned by a star, plus the three ways in —
/// open from Files, merge several PDFs into one, and Settings.
struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    @State private var showingPicker = false
    @State private var showingMergePicker = false
    @State private var showingSettings = false
    @State private var mergeSelection: Set<UUID> = []
    @State private var mergeMode = false
    @State private var importError: String?
    @State private var openAfterMerge: RecentDocument?

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
                        showingPicker = true
                    } label: {
                        Label("Open PDF…", systemImage: "folder")
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
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .alert("Couldn't Open That File", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .navigationDestination(item: $openAfterMerge) { entry in
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
            Button("Open PDF…") { showingPicker = true }
                .buttonStyle(.borderedProminent)
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
        openAfterMerge = merged
    }
}
