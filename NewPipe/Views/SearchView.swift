import SwiftUI
import SwiftData
import NewPipeExtractor

struct SearchView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var router: Router
    @Environment(\.modelContext) private var context
    @Query(sort: \SearchHistoryEntry.date, order: .reverse) private var history: [SearchHistoryEntry]
    @AppStorage(SettingsKey.searchHistoryEnabled) private var historyEnabled = true
    @AppStorage(SettingsKey.searchSuggestions) private var suggestionsEnabled = true
    @AppStorage(SettingsKey.hideShorts) private var hideShorts = true

    @State private var text = ""
    @State private var submitted = ""
    @State private var filter: YouTubeService.SearchFilter = .all
    @State private var items: [InfoItem] = []
    @State private var continuation: String?
    @State private var suggestions: [String] = []
    @State private var isLoading = false
    @State private var error: String?

    /// Résultats affichés (sans les Shorts si le réglage le demande).
    private var visibleItems: [InfoItem] {
        guard hideShorts else { return items }
        return items.filter { if case .stream(let s) = $0 { !s.isShort } else { true } }
    }
    private var streams: [StreamItem] { visibleItems.compactMap { if case .stream(let s) = $0 { s } else { nil } } }

    var body: some View {
        List {
            if submitted.isEmpty || text != submitted {
                suggestionsSection
            } else if let error {
                ErrorView(message: error) { Task { await search() } }
            } else {
                filterChips
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

                ForEach(visibleItems) { InfoItemCell(item: $0, streams: streams) }
                if isLoading && items.isEmpty {
                    SkeletonList()
                } else if continuation != nil {
                    LoadMoreRow { await loadMore() }
                } else if items.isEmpty && !isLoading {
                    ContentUnavailableView.search(text: submitted)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Recherche")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher ou coller un lien YouTube")
        .onSubmit(of: .search) { submit(text) }
        .task(id: text) {
            guard suggestionsEnabled, !text.isEmpty, text != submitted else { suggestions = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            suggestions = (try? await Services.youtube.suggestions(text)) ?? []
        }
        .onChange(of: filter) { Task { await search() } }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Tout", .all)
                chip("Vidéos", .videos)
                chip("Chaînes", .channels)
                chip("Playlists", .playlists)
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ title: String, _ value: YouTubeService.SearchFilter) -> some View {
        Button(title) { filter = value }
            .buttonStyle(PillButtonStyle(prominent: filter == value))
            .sensoryFeedback(.selection, trigger: filter)
    }

    @ViewBuilder private var suggestionsSection: some View {
        let past = history.filter { text.isEmpty || $0.query.localizedCaseInsensitiveContains(text) }.prefix(text.isEmpty ? 20 : 4)
        if text.isEmpty && !past.isEmpty {
            Text("Recherches récentes").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        }
        ForEach(Array(past)) { entry in
            suggestionRow(entry.query, icon: "clock.arrow.circlepath")
                .swipeActions { Button("Supprimer", role: .destructive) { context.delete(entry) } }
        }
        ForEach(suggestions, id: \.self) { s in
            suggestionRow(s, icon: "magnifyingglass")
        }
        if text.isEmpty && past.isEmpty {
            ContentUnavailableView("Rechercher sur YouTube", systemImage: "magnifyingglass",
                                   description: Text("Vidéos, chaînes, playlists, ou collez directement un lien YouTube."))
                .listRowSeparator(.hidden)
        }
    }

    private func suggestionRow(_ query: String, icon: String) -> some View {
        Button { submit(query) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
                Text(query).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.left").font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }

    private func submit(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        text = q
        submitted = q
        Task {
            // Un lien collé ouvre directement la vidéo, la chaîne ou la playlist.
            if let link = try? await Services.youtube.resolve(q) {
                // Un lien n'est pas une recherche : on vide le champ au lieu d'afficher « Aucun résultat ».
                text = ""
                submitted = ""
                switch link {
                case .stream(let id): player.play(StreamItem(id: id, title: ""))
                case .channel(let id): router.open(.channel(id: id, name: ""))
                case .playlist(let id): router.open(.playlist(id: id, title: ""))
                }
                return
            }
            if historyEnabled {
                if let existing = history.first(where: { $0.query == q }) { existing.date = .now }
                else { context.insert(SearchHistoryEntry(query: q)) }
            }
            await search()
        }
    }

    private func search() async {
        isLoading = true
        error = nil
        items = []
        continuation = nil
        defer { isLoading = false }
        do {
            let page = try await Services.youtube.search(submitted, filter: filter)
            items = page.items
            continuation = page.continuation
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let token = continuation else { return }
        continuation = nil
        if let page = try? await Services.youtube.searchContinuation(token) {
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            continuation = page.continuation
        }
    }
}
