import SwiftUI
import SwiftData
import NewPipeExtractor

struct ChannelView: View {
    let channelId: String
    let initialName: String

    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var feed: FeedModel
    @Environment(\.modelContext) private var context
    @Query private var subscriptions: [Subscription]

    @State private var info: ChannelInfo?
    @State private var videos: [StreamItem] = []
    @State private var continuation: String?
    @State private var error: String?
    @State private var showDescription = false
    @AppStorage(SettingsKey.hideCounts) private var hideCounts = false
    @AppStorage(SettingsKey.hideShorts) private var hideShorts = true

    init(channelId: String, initialName: String) {
        self.channelId = channelId
        self.initialName = initialName
        _subscriptions = Query(filter: #Predicate<Subscription> { $0.channelId == channelId })
    }

    private var isSubscribed: Bool { !subscriptions.isEmpty }

    var body: some View {
        List {
            if let info {
                header(info)
                let shown = videos.filteringShorts(hideShorts)
                ForEach(shown) { StreamCell(item: $0, queue: shown, avatarURL: info.avatarURL) }
                if continuation != nil { LoadMoreRow { await loadMore() } }
            } else if let error {
                ErrorView(message: error) { Task { await load() } }
            } else {
                SkeletonList(count: 3)
            }
        }
        .listStyle(.plain)
        .navigationTitle(info?.name ?? initialName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { if !videos.isEmpty { player.play(videos[0], queue: videos) } } label: { Label("Tout lire", systemImage: "play") }
                    Button { if !videos.isEmpty { player.play(videos[0], queue: videos, audioOnly: true) } } label: { Label("Tout lire en arrière-plan", systemImage: "headphones") }
                    ShareLink(item: URL(string: "https://www.youtube.com/channel/\(channelId)")!) { Label("Partager", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task { if info == nil { await load() } }
        .refreshable { await load() }
    }

    @ViewBuilder private func header(_ info: ChannelInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                // Cadre fixe rempli par la bannière : l'image (très large) ne doit pas imposer sa taille.
                Rectangle()
                    .fill(LinearGradient(colors: [Color.accentColor.opacity(0.5), Color.accentColor.opacity(0.15)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(maxWidth: .infinity)
                    .frame(height: 110)
                    .overlay {
                        if let banner = info.bannerURL {
                            AsyncImage(url: banner) { $0.resizable().scaledToFill() } placeholder: { Theme.fill }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
                .padding(.bottom, 34)

                Avatar(url: info.avatarURL, size: 76, name: info.name)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 4))
                    .padding(.leading, 14)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(info.name).font(.title2.bold())
                if !hideCounts, let s = info.subscriberText { Text(s).font(.subheadline).foregroundStyle(.secondary) }
            }

            HStack(spacing: 8) {
                SubscribeButton(isSubscribed: isSubscribed, expanded: true, action: toggleSubscription)
                Button { if !videos.isEmpty { player.play(videos[0], queue: videos) } } label: {
                    Label("Tout lire", systemImage: "play.fill")
                }
                .buttonStyle(.pill)
                .disabled(videos.isEmpty)
            }

            if let d = info.description, !d.isEmpty {
                Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(showDescription ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy) { showDescription.toggle() } }
            }

            SectionTitle(title: "Vidéos").padding(.top, 6)
        }
        .listRowSeparator(.hidden)
    }

    private func toggleSubscription() {
        if let sub = subscriptions.first {
            context.delete(sub)
            feed.removeChannel(channelId)
        } else if let info {
            context.insert(Subscription(channelId: info.id, name: info.name, avatarURL: info.avatarURL))
        }
        try? context.save()
    }

    private func load() async {
        error = nil
        do {
            let i = try await Services.youtube.channel(id: channelId)
            info = i
            videos = i.videos.items
            continuation = i.videos.continuation
            // Met à jour le nom et l'avatar de l'abonnement (utile après un import).
            if let sub = subscriptions.first {
                sub.name = i.name
                sub.avatarURL = i.avatarURL
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let token = continuation, let info else { return }
        continuation = nil
        if let page = try? await Services.youtube.channelContinuation(token, channelId: info.id, channelName: info.name) {
            let known = Set(videos.map(\.id))
            videos += page.items.filter { !known.contains($0.id) }
            continuation = page.continuation
        }
    }
}
