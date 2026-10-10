import SwiftUI
import SwiftData
import NewPipeExtractor

/// Playlist YouTube distante.
struct PlaylistView: View {
    let playlistId: String
    let initialTitle: String

    @EnvironmentObject private var player: PlayerManager
    @Environment(\.modelContext) private var context
    @Query private var bookmarks: [BookmarkedPlaylist]

    @State private var info: PlaylistInfo?
    @State private var items: [StreamItem] = []
    @State private var continuation: String?
    @State private var error: String?

    init(playlistId: String, initialTitle: String) {
        self.playlistId = playlistId
        self.initialTitle = initialTitle
        _bookmarks = Query(filter: #Predicate<BookmarkedPlaylist> { $0.playlistId == playlistId })
    }

    var body: some View {
        List {
            if let info {
                VStack(alignment: .leading, spacing: 12) {
                    if let first = items.first {
                        Thumbnail(url: first.largeThumbnailURL, cornerRadius: Theme.corner, alwaysVisible: true)
                    }
                    Text(info.title).font(.title2.bold())
                    if let c = info.channelName { Text(c).font(.subheadline).foregroundStyle(.secondary) }
                    PlayButtons(items: items)
                }
                .padding(.bottom, 6)
                .listRowSeparator(.hidden)
                ForEach(items) { StreamCell(item: $0, queue: items) }
                if continuation != nil { LoadMoreRow { await loadMore() } }
            } else if let error {
                ErrorView(message: error) { Task { await load() } }
            } else {
                SkeletonList(count: 3)
            }
        }
        .listStyle(.plain)
        .navigationTitle(info?.title ?? initialTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                if let b = bookmarks.first { context.delete(b) }
                else if let info {
                    context.insert(BookmarkedPlaylist(PlaylistItem(id: info.id, title: info.title, channelName: info.channelName,
                                                                   thumbnailURL: items.first?.thumbnailURL)))
                }
            } label: { Image(systemName: bookmarks.isEmpty ? "star" : "star.fill") }
        }
        .task { if info == nil { await load() } }
    }

    private func load() async {
        error = nil
        do {
            let i = try await Services.youtube.playlist(id: playlistId)
            info = i
            items = i.items.items
            continuation = i.items.continuation
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let token = continuation else { return }
        continuation = nil
        if let page = try? await Services.youtube.playlistContinuation(token) {
            items += page.items
            continuation = page.continuation
        }
    }
}

/// Boutons "Tout lire" / "Arrière-plan" / "Aléatoire" comme dans NewPipe.
struct PlayButtons: View {
    let items: [StreamItem]
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        HStack(spacing: 8) {
            button("Lire", "play.fill", prominent: true) { player.play(items[0], queue: items) }
            button("Arrière-plan", "headphones") { player.play(items[0], queue: items, audioOnly: true) }
            button("Aléatoire", "shuffle") {
                let shuffled = items.shuffled()
                player.play(shuffled[0], queue: shuffled)
            }
        }
        .disabled(items.isEmpty)
    }

    private func button(_ title: String, _ icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).frame(maxWidth: .infinity).lineLimit(1).minimumScaleFactor(0.8)
        }
        .buttonStyle(PillButtonStyle(prominent: prominent))
    }
}
