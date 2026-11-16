import SwiftUI

/// Full-text search sheet: type a query, get every match with its
/// page number and the line it sits on; tapping a result jumps the
/// reader to that match and highlights it.
struct SearchView: View {
    @ObservedObject var controller: ReaderController
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView(
                        hasSearched ? "No Matches" : "Search This Document",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(hasSearched
                            ? "Nothing in this PDF matches that text."
                            : "Search every page for a word or phrase.")
                    )
                } else {
                    List(results) { result in
                        Button {
                            controller.goToSelection(result.selection)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Page \(result.pageIndex + 1)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                                Text(result.snippet)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Word or phrase")
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty {
                    results = []
                    hasSearched = false
                }
            }
        }
    }

    private func runSearch() {
        let query = query
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        Task {
            let found = await controller.search(for: query)
            results = found
            hasSearched = true
            isSearching = false
        }
    }
}

/// Document outline sheet (table of contents), shown when the PDF
/// carries one. Tapping an entry jumps to its page.
struct OutlineView: View {
    @ObservedObject var controller: ReaderController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(controller.outlineItems()) { item in
                Button {
                    controller.goToPage(item.pageIndex)
                    dismiss()
                } label: {
                    HStack {
                        Text(item.label)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer()
                        Text("\(item.pageIndex + 1)")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                    .padding(.leading, CGFloat(item.depth) * 16)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Page bookmarks for the open document.
struct BookmarksView: View {
    @ObservedObject var controller: ReaderController
    @ObservedObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                let documentBookmarks = library.bookmarks(for: controller.entry.id)
                if documentBookmarks.isEmpty {
                    ContentUnavailableView(
                        "No Bookmarks Yet",
                        systemImage: "bookmark",
                        description: Text("Tap the bookmark button in the reader to mark a page.")
                    )
                } else {
                    List {
                        ForEach(documentBookmarks) { bookmark in
                            Button {
                                controller.goToPage(bookmark.pageIndex)
                                dismiss()
                            } label: {
                                Label("Page \(bookmark.pageIndex + 1)", systemImage: "bookmark.fill")
                                    .foregroundStyle(.primary)
                            }
                        }
                        .onDelete { offsets in
                            for offset in offsets {
                                library.removeBookmark(documentBookmarks[offset])
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
