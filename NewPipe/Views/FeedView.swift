import SwiftUI
import SwiftData
import NewPipeExtractor

/// Onglet "Nouveautés" : dernières vidéos de tous les abonnements, regroupées par jour.
struct FeedView: View {
    @EnvironmentObject private var feed: FeedModel
    @EnvironmentObject private var router: Router
    @Query(sort: \Subscription.name) private var subscriptions: [Subscription]
    @Query private var history: [HistoryEntry]
    @AppStorage(SettingsKey.feedHideWatched) private var hideWatched = false
    @AppStorage(SettingsKey.hideShorts) private var hideShorts = true
    @AppStorage(SettingsKey.focusMode) private var focusMode = false
    @AppStorage(SettingsKey.feedSinceSubscription) private var sinceSubscription = true

    private var items: [StreamItem] {
        var result = feed.items.filteringShorts(hideShorts)
        if sinceSubscription {
            // Uniquement les vidéos publiées après l'abonnement à leur chaîne.
            let since = Dictionary(subscriptions.map { ($0.channelId, $0.subscribedAt) }, uniquingKeysWith: min)
            result = result.filter { item in
                guard let date = item.publishedDate, let id = item.channelId, let start = since[id] else { return false }
                return date >= start
            }
        }
        if hideWatched {
            let watched = Set(history.map(\.videoId))
            result = result.filter { !watched.contains($0.id) }
        }
        return result
    }

    /// Sections « Aujourd'hui », « Hier », « Cette semaine », « Plus ancien ».
    private func sections(_ items: [StreamItem]) -> [(title: String, items: [StreamItem])] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: .now)!
        let groups = Dictionary(grouping: items) { item -> Int in
            guard let date = item.publishedDate else { return 3 }
            if calendar.isDateInToday(date) { return 0 }
            if calendar.isDateInYesterday(date) { return 1 }
            return date > weekAgo ? 2 : 3
        }
        let titles = ["Aujourd'hui", "Hier", "Cette semaine", "Plus ancien"]
        return groups.keys.sorted().map { (titles[$0], groups[$0]!) }
    }

    var body: some View {
        let avatars = Dictionary(subscriptions.map { ($0.channelId, $0.avatarURL) }, uniquingKeysWith: { a, _ in a })
        let all = items
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
            if focusMode {
                Label("Mode concentration activé", systemImage: "leaf.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.focus)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.focus.opacity(0.12), in: Capsule())
                    .listRowSeparator(.hidden)
            }
            if feed.isLoading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(feed.progress.done), total: Double(max(feed.progress.total, 1)))
                    Text("Actualisation des abonnements… \(feed.progress.done)/\(feed.progress.total)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
                if all.isEmpty { SkeletonList() }
            } else if let date = feed.lastUpdate {
                Text("Mis à jour \(Format.relative(date) ?? "")" + (feed.failedChannels.isEmpty ? "" : " • \(feed.failedChannels.count) chaîne(s) en échec"))
                    .font(.caption).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(sections(all), id: \.title) { section in
                SectionTitle(title: section.title, trailing: "\(section.items.count)")
                    .padding(.top, 10)
                    .listRowSeparator(.hidden)
                ForEach(section.items) { item in
                    StreamCell(item: item, queue: all, avatarURL: item.channelId.flatMap { avatars[$0] ?? nil })
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if subscriptions.isEmpty {
                ContentUnavailableView {
                    Label("Aucun abonnement", systemImage: "rectangle.stack.badge.person.crop")
                } description: {
                    Text("Abonnez-vous à des chaînes depuis la recherche, ou importez vos abonnements NewPipe/YouTube dans l'onglet Abonnements.")
                } actions: {
                    Button("Rechercher une chaîne") { router.tab = .search }.buttonStyle(.prominentPill)
                }
            } else if all.isEmpty && !feed.isLoading {
                ContentUnavailableView("Rien de nouveau", systemImage: "checkmark.circle", description: Text(sinceSubscription
                    ? "Les vidéos publiées après vos abonnements apparaîtront ici. Tirez vers le bas pour actualiser."
                    : "Vous êtes à jour. Tirez vers le bas pour actualiser."))
            }
        }
        .navigationTitle("Nouveautés")
        // Titre maison : aligné sur la même ligne que le bouton de filtres.
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await refresh() }
        .task {
            // Actualisation automatique si le cache a plus de 30 minutes.
            if !subscriptions.isEmpty, (feed.lastUpdate ?? .distantPast).timeIntervalSinceNow < -1800 { await refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("Nouveautés")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Menu {
                Toggle("Seulement depuis mes abonnements", isOn: $sinceSubscription)
                Toggle("Masquer les vidéos vues", isOn: $hideWatched)
                Toggle("Masquer les Shorts", isOn: $hideShorts)
                Button { Task { await refresh() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Theme.fill, in: Circle())
            }
            .accessibilityLabel("Filtres")
        }
    }

    private func refresh() async {
        await feed.refresh(subscriptions: subscriptions.map { ($0.channelId, $0.name) })
    }
}
