import SwiftUI
import SwiftData
import NewPipeExtractor

enum Route: Hashable {
    case channel(id: String, name: String)
    case playlist(id: String, title: String)
    case localPlaylist(PersistentIdentifier)
    case history
    case downloads
    case bookmarks
}

enum AppTab: Hashable { case feed, search, subscriptions, library, settings }

/// Navigation globale : permet au lecteur (présenté en feuille) d'ouvrir une chaîne dans l'onglet courant.
@MainActor
final class Router: ObservableObject {
    @Published var tab: AppTab = .feed
    @Published var paths: [AppTab: NavigationPath] = [:]

    func binding(for tab: AppTab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[tab] ?? NavigationPath() }, set: { self.paths[tab] = $0 })
    }

    func open(_ route: Route) {
        PlayerManager.shared.showFullPlayer = false
        paths[tab, default: NavigationPath()].append(route)
    }
}

struct RouteDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            Group {
                switch route {
                case .channel(let id, let name): ChannelView(channelId: id, initialName: name)
                case .playlist(let id, let title): PlaylistView(playlistId: id, initialTitle: title)
                case .localPlaylist(let id): LocalPlaylistView(playlistID: id)
                case .history: HistoryView()
                case .downloads: DownloadsView()
                case .bookmarks: BookmarksView()
                }
            }
            .miniPlayerInset()
        }
    }
}

extension View {
    func withRoutes() -> some View { modifier(RouteDestinations()) }

    /// Mini-lecteur flottant en bas de l'écran (à appliquer à chaque écran d'une pile de navigation).
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerAccessory() }
    }
}

private struct MiniPlayerAccessory: View {
    @EnvironmentObject private var player: PlayerManager
    var body: some View {
        MiniPlayerView().animation(.snappy, value: player.current?.id)
    }
}

// MARK: Vignettes

struct Thumbnail: View {
    let url: URL?
    var duration: Int? = nil
    var isLive = false
    var isShort = false
    var progress: Double? = nil
    var cornerRadius: CGFloat = Theme.smallCorner
    /// Ignore le réglage « Miniatures » (contenus choisis : téléchargements, playlists).
    var alwaysVisible = false

    @AppStorage(SettingsKey.thumbnailMode) private var mode = ThumbnailMode.normal.rawValue

    var body: some View {
        let style = alwaysVisible ? .normal : (ThumbnailMode(rawValue: mode) ?? .normal)
        // Le cadre 16:9 fixe la taille ; l'image le remplit sans l'agrandir (les miniatures YouTube sont en 4:3).
        Rectangle()
            .fill(Theme.fill)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if style == .hidden {
                    ZStack {
                        LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "play.fill").font(.title3).foregroundStyle(.secondary)
                    }
                } else {
                    AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .blur(radius: style == .blurred ? 18 : 0, opaque: true)
                    .overlay { if style == .blurred { Color.black.opacity(0.12) } }
                }
            }
            .clipped()
        .overlay(alignment: .bottomTrailing) {
            if isLive {
                badge(Label("EN DIRECT", systemImage: "dot.radiowaves.left.and.right"), color: .red)
            } else if isShort {
                badge(Label("SHORT", systemImage: "bolt.fill"), color: .black.opacity(0.7))
            } else if let text = Format.duration(duration) {
                badge(Text(text), color: .black.opacity(0.7))
            }
        }
        .overlay(alignment: .bottom) {
            if let progress, progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.35))
                        Rectangle().fill(Color.accentColor).frame(width: geo.size.width * min(progress, 1))
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func badge(_ content: some View, color: Color) -> some View {
        content
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(6)
    }
}

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 44
    var name: String? = nil

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else if let name, !name.isEmpty {
                Monogram(name: name, size: size)
            } else {
                Circle().fill(Theme.fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: Lignes et cartes

/// Ligne compacte : miniature à gauche, titre et métadonnées à droite.
struct StreamRow: View {
    let item: StreamItem
    var progress: Double? = nil

    @AppStorage(SettingsKey.hideCounts) private var hideCounts = false
    @AppStorage(SettingsKey.calmTitles) private var calmTitles = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(url: item.thumbnailURL, duration: item.duration, isLive: item.isLive, isShort: item.isShort, progress: progress)
                .frame(width: 160)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle(calm: calmTitles)).font(.subheadline.weight(.semibold)).lineLimit(3)
                Text(item.subtitle(hideCounts: hideCounts)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Grande carte : miniature pleine largeur, puis chaîne, titre et métadonnées.
struct VideoCard: View {
    let item: StreamItem
    var avatarURL: URL? = nil
    var progress: Double? = nil

    @AppStorage(SettingsKey.hideCounts) private var hideCounts = false
    @AppStorage(SettingsKey.calmTitles) private var calmTitles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Thumbnail(url: item.largeThumbnailURL, duration: item.duration, isLive: item.isLive, isShort: item.isShort,
                      progress: progress, cornerRadius: Theme.corner)
            HStack(alignment: .top, spacing: 10) {
                if avatarURL != nil || !(item.channelName ?? "").isEmpty {
                    Avatar(url: avatarURL, size: 36, name: item.channelName)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle(calm: calmTitles)).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(item.subtitle(hideCounts: hideCounts)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct ChannelRow: View {
    let item: ChannelItem
    @AppStorage(SettingsKey.hideCounts) private var hideCounts = false

    var body: some View {
        HStack(spacing: 14) {
            Avatar(url: item.avatarURL, size: 56, name: item.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.headline)
                if !hideCounts, let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct PlaylistRow: View {
    let item: PlaylistItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Thumbnail(url: item.thumbnailURL, alwaysVisible: true)
                .overlay(alignment: .bottomTrailing) {
                    Label(item.videoCountText ?? "Playlist", systemImage: "list.and.film")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .padding(6)
                }
                .frame(width: 160)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(3)
                if let c = item.channelName { Text(c).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Vidéo interactive : appui = lecture, appui long = menu. S'affiche en carte ou en ligne selon le réglage.
struct StreamCell: View {
    let item: StreamItem
    var queue: [StreamItem]? = nil
    var progress: Double? = nil
    var avatarURL: URL? = nil
    /// Force une disposition (sinon, celle des réglages).
    var layout: VideoLayout? = nil

    @EnvironmentObject private var player: PlayerManager
    @AppStorage(SettingsKey.videoLayout) private var storedLayout = VideoLayout.cards.rawValue

    var body: some View {
        let cards = (layout ?? VideoLayout(rawValue: storedLayout) ?? .cards) == .cards
        Button {
            player.play(item, queue: queue)
        } label: {
            if cards {
                VideoCard(item: item, avatarURL: avatarURL, progress: progress)
            } else {
                StreamRow(item: item, progress: progress)
            }
        }
        .buttonStyle(.plain)
        .streamContextMenu(item)
        .listRowSeparator(cards ? .hidden : .automatic)
    }
}

struct InfoItemCell: View {
    let item: InfoItem
    var streams: [StreamItem] = []

    var body: some View {
        switch item {
        case .stream(let s):
            StreamCell(item: s, queue: streams)
        case .channel(let c):
            NavigationLink(value: Route.channel(id: c.id, name: c.name)) { ChannelRow(item: c) }
        case .playlist(let p):
            NavigationLink(value: Route.playlist(id: p.id, title: p.title)) { PlaylistRow(item: p) }
        }
    }
}

// MARK: Menu contextuel

struct StreamContextMenu: ViewModifier {
    let item: StreamItem
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var router: Router
    @State private var showPlaylistPicker = false
    @State private var showDownload = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { player.play(item, audioOnly: true) } label: { Label("Lire en arrière-plan", systemImage: "headphones") }
                Button { player.enqueueNext(item) } label: { Label("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") }
                Button { player.enqueue(item) } label: { Label("Ajouter à la file d'attente", systemImage: "text.badge.plus") }
                Button { showPlaylistPicker = true } label: { Label("Ajouter à une playlist", systemImage: "music.note.list") }
                Button { showDownload = true } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
                if let id = item.channelId {
                    Button { router.open(.channel(id: id, name: item.channelName ?? "")) } label: { Label("Afficher la chaîne", systemImage: "person.crop.square") }
                }
                ShareLink(item: item.url) { Label("Partager", systemImage: "square.and.arrow.up") }
                Button { UIPasteboard.general.url = item.url } label: { Label("Copier le lien", systemImage: "link") }
            }
            .sheet(isPresented: $showPlaylistPicker) { PlaylistPickerSheet(item: item) }
            .sheet(isPresented: $showDownload) { DownloadSheet(videoId: item.id) }
    }
}

extension View {
    func streamContextMenu(_ item: StreamItem) -> some View { modifier(StreamContextMenu(item: item)) }
}

/// Liste paginée générique ("chargement infini").
struct LoadMoreRow: View {
    let action: () async -> Void
    var body: some View {
        HStack { Spacer(); ProgressView(); Spacer() }
            .task { await action() }
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label("Erreur", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Réessayer", action: retry).buttonStyle(.borderedProminent)
        }
    }
}
