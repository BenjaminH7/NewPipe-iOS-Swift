import SwiftUI
import AVKit
import SwiftData
import NewPipeExtractor

/// AVPlayerViewController natif : contrôles iOS, plein écran, vitesse, AirPlay, PiP.
struct VideoPlayerController: UIViewControllerRepresentable {
    @EnvironmentObject private var manager: PlayerManager
    @AppStorage(SettingsKey.autoPiP) private var autoPiP = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = manager.player
        c.delegate = manager
        c.allowsPictureInPicturePlayback = true
        c.canStartPictureInPictureAutomaticallyFromInline = autoPiP
        c.updatesNowPlayingInfoCenter = false
        c.speeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map { AVPlaybackSpeed(rate: $0, localizedName: "×\($0.formatted())") }
        manager.playerController = c
        return c
    }

    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {
        c.canStartPictureInPictureAutomaticallyFromInline = autoPiP
        if manager.playerController !== c { manager.playerController = c }
    }
}

/// Simple calque vidéo pour le mini-lecteur.
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var player: AVPlayer?

        func attach(_ player: AVPlayer) {
            self.player = player
            playerLayer.player = player
            // Un calque vidéo attaché met la lecture en pause en arrière-plan : on le détache.
            NotificationCenter.default.addObserver(self, selector: #selector(detach), name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(reattach), name: UIApplication.willEnterForegroundNotification, object: nil)
        }
        @objc private func detach() {
            if UserDefaults.standard.bool(forKey: SettingsKey.backgroundPlayback) { playerLayer.player = nil }
        }
        @objc private func reattach() { playerLayer.player = player }
    }
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.attach(player)
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: LayerView, context: Context) {}
}

struct PlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var router: Router
    @Environment(\.modelContext) private var context
    @Query private var subscriptions: [Subscription]
    @State private var showDescription = false
    @State private var showQueue = false
    @State private var showPlaylistPicker = false
    @State private var showDownload = false
    @State private var showComments = false
    @State private var revealSuggestions = false
    @State private var commentPreview: Comment?

    @AppStorage(SettingsKey.hideCounts) private var hideCounts = false
    @AppStorage(SettingsKey.calmTitles) private var calmTitles = false
    @AppStorage(SettingsKey.hideShorts) private var hideShorts = true
    @AppStorage(SettingsKey.commentsMode) private var commentsMode = RevealMode.onDemand.rawValue
    @AppStorage(SettingsKey.suggestionsMode) private var suggestionsMode = RevealMode.visible.rawValue

    var body: some View {
        VStack(spacing: 0) {
            video
            transport
            Divider().opacity(0.5)
            ScrollView {
                details
                    .padding(.horizontal)
                    .padding(.top, 14)
                    .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(isPresented: $showPlaylistPicker) { if let c = player.current { PlaylistPickerSheet(item: c) } }
        .sheet(isPresented: $showDownload) { if let c = player.current { DownloadSheet(videoId: c.id, preloaded: player.info) } }
        .sheet(isPresented: $showComments) {
            if let token = player.info?.commentsContinuation { CommentsView(token: token, countText: player.info?.commentCountText) }
        }
        .breakReminder()
        .onChange(of: player.current?.id) {
            revealSuggestions = false
            commentPreview = nil
        }
        .task(id: player.info?.id) { await loadCommentPreview() }
    }

    // MARK: Vidéo et commandes

    private var video: some View {
        ZStack {
            Color.black
            if player.audioOnly {
                AsyncImage(url: player.current?.largeThumbnailURL) { $0.resizable().scaledToFit() } placeholder: { Color.black }
                    .overlay(alignment: .bottomTrailing) {
                        Label("Audio seul", systemImage: "headphones").font(.caption.bold()).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule()).padding(10)
                    }
            } else {
                VideoPlayerController()
            }
            if player.isLoading { ProgressView().tint(.white).controlSize(.large) }
            if let error = player.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title)
                    Text(error).font(.callout).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white).padding()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
    }

    private var transport: some View {
        HStack {
            transportButton("backward.end.fill", "Précédente") { player.previous() }
            Spacer()
            transportButton("gobackward.10", "Reculer de 10 secondes") { player.skip(-10) }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Color.accentColor.gradient, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
            Spacer()
            transportButton("goforward.10", "Avancer de 10 secondes") { player.skip(10) }
            Spacer()
            transportButton("forward.end.fill", "Suivante") { player.next() }
                .disabled(!player.hasNext && !UserDefaults.standard.bool(forKey: SettingsKey.autoplayNext))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func transportButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 44, height: 44)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    // MARK: Détails

    @ViewBuilder private var details: some View {
        let item = player.current
        let info = player.info
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(calmTitles ? CalmTitle.apply(info?.title ?? item?.title ?? "") : (info?.title ?? item?.title ?? ""))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !hideCounts, let v = info?.viewCount { Text("\(Format.count(v) ?? "") vues") }
                    if !hideCounts, info?.viewCount != nil, info?.dateText != nil { Text("•") }
                    if let d = info?.dateText { Text(d) }
                    if player.isPlayingOffline {
                        Label("Hors ligne", systemImage: "arrow.down.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }

            if let channelId = info?.channelId ?? item?.channelId {
                channelRow(channelId: channelId, info: info, item: item)
            }

            actions(item: item, info: info)

            if let desc = info?.description, !desc.isEmpty { descriptionCard(desc) }

            comments(info: info)

            suggestions(info: info)
        }
    }

    private func channelRow(channelId: String, info: StreamInfo?, item: StreamItem?) -> some View {
        let name = info?.channelName ?? item?.channelName ?? ""
        let sub = subscriptions.first { $0.channelId == channelId }
        return HStack(spacing: 12) {
            Button { router.open(.channel(id: channelId, name: name)) } label: {
                HStack(spacing: 12) {
                    Avatar(url: info?.channelAvatarURL ?? sub?.avatarURL, size: 42, name: name)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if !hideCounts, let s = info?.channelSubscriberText { Text(s).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            SubscribeButton(isSubscribed: sub != nil) {
                if let sub { context.delete(sub) }
                else { context.insert(Subscription(channelId: channelId, name: name, avatarURL: info?.channelAvatarURL)) }
                try? context.save()
            }
        }
    }

    private func actions(item: StreamItem?, info: StreamInfo?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !hideCounts, let likes = info?.likeCountText {
                    Label(likes, systemImage: "hand.thumbsup")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.fill, in: Capsule())
                }
                if !player.audioOnly {
                    Button { player.enterFullscreen() } label: {
                        Label("Plein écran", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                }
                Button { player.setAudioOnly(!player.audioOnly) } label: {
                    Label(player.audioOnly ? "Vidéo" : "Audio", systemImage: player.audioOnly ? "play.rectangle" : "headphones")
                }
                Button { showPlaylistPicker = true } label: { Label("Enregistrer", systemImage: "text.badge.plus") }
                Button { showDownload = true } label: { Label("Télécharger", systemImage: "arrow.down.circle") }
                Button { showQueue = true } label: {
                    Label(player.queue.count > 1 ? "File (\(player.queue.count))" : "File d'attente", systemImage: "list.bullet")
                }
                if let url = item?.url {
                    ShareLink(item: url) { Label("Partager", systemImage: "square.and.arrow.up") }
                }
            }
            .buttonStyle(.pill)
        }
        .scrollClipDisabled()
    }

    private func descriptionCard(_ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(.init(linkified(desc)))
                .font(.subheadline)
                .lineLimit(showDescription ? nil : 3)
                .tint(.blue)
            Text(showDescription ? "Afficher moins" : "Afficher plus")
                .font(.footnote.weight(.semibold))
        }
        .cardStyle(padding: 12)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { showDescription.toggle() } }
    }

    // MARK: Commentaires

    @ViewBuilder private func comments(info: StreamInfo?) -> some View {
        let mode = RevealMode(rawValue: commentsMode) ?? .onDemand
        if mode != .hidden, let info, info.commentsContinuation != nil {
            Button { showComments = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Commentaires").font(.subheadline.weight(.semibold))
                        if !hideCounts, let count = info.commentCountText { Text(count).font(.subheadline).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                    }
                    if mode == .visible, let c = commentPreview {
                        HStack(alignment: .top, spacing: 8) {
                            Avatar(url: c.authorAvatarURL, size: 24, name: c.author)
                            Text(c.text).font(.footnote).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    } else if mode == .onDemand {
                        Label("Masqués pour rester concentré · touchez pour afficher", systemImage: "eye.slash")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .cardStyle(padding: 12)
            }
            .buttonStyle(.plain)
        } else if info != nil, info?.commentsContinuation == nil, mode != .hidden {
            Label("Commentaires désactivés", systemImage: "text.bubble")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func loadCommentPreview() async {
        guard RevealMode(rawValue: commentsMode) == .visible, let token = player.info?.commentsContinuation else { return }
        commentPreview = try? await Services.youtube.comments(token).comments.first
    }

    // MARK: Suggestions

    @ViewBuilder private func suggestions(info: StreamInfo?) -> some View {
        let mode = RevealMode(rawValue: suggestionsMode) ?? .visible
        let related = (info?.related ?? []).filteringShorts(hideShorts)
        if mode != .hidden, !related.isEmpty {
            if mode == .visible || revealSuggestions {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(title: "À suivre")
                    LazyVStack(spacing: 14) {
                        ForEach(related) { r in
                            Button { player.play(r) } label: { StreamRow(item: r) }
                                .buttonStyle(.plain)
                                .streamContextMenu(r)
                        }
                    }
                }
            } else {
                Button { withAnimation(.snappy) { revealSuggestions = true } } label: {
                    Label("Afficher les suggestions (\(related.count))", systemImage: "rectangle.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill)
            }
        }
    }

    /// Rend les URL de la description cliquables (Markdown).
    private func linkified(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "_", with: "\\_")
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return escaped }
        var result = escaped
        for match in detector.matches(in: escaped, range: NSRange(escaped.startIndex..., in: escaped)).reversed() {
            guard let range = Range(match.range, in: escaped), let url = match.url else { continue }
            result.replaceSubrange(range, with: "[\(escaped[range])](\(url.absoluteString))")
        }
        return result
    }
}

/// Alerte « Faire une pause ? » déclenchée par le rappel du mode concentration.
private struct BreakReminderModifier: ViewModifier {
    /// Une seule vue doit présenter l'alerte : le lecteur s'il est ouvert, sinon la racine.
    var active = true
    @EnvironmentObject private var player: PlayerManager
    @AppStorage(SettingsKey.breakReminder) private var minutes = 0

    func body(content: Content) -> some View {
        content.alert("Faire une pause ?", isPresented: Binding(
            get: { active && player.breakReminderDue },
            set: { if !$0 && player.breakReminderDue { player.dismissBreakReminder(resume: false) } })
        ) {
            Button("Continuer \(minutes) min") { player.dismissBreakReminder(resume: true) }
            Button("Arrêter", role: .cancel) { player.dismissBreakReminder(resume: false) }
        } message: {
            Text("Vous regardez depuis \(minutes) minutes. La lecture est en pause.")
        }
    }
}

extension View {
    func breakReminder(active: Bool = true) -> some View { modifier(BreakReminderModifier(active: active)) }
}

struct QueueView: View {
    @EnvironmentObject private var player: PlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.offset) { i, item in
                    Button { player.jump(to: i) } label: {
                        HStack {
                            StreamRow(item: item)
                            if i == player.index {
                                Image(systemName: "waveform").foregroundStyle(Color.accentColor)
                                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(i == player.index ? Color.accentColor.opacity(0.08) : nil)
                }
                .onDelete { player.removeFromQueue(at: $0) }
                .onMove { player.moveInQueue(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .navigationTitle("File d'attente")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() }.bold() }
            }
        }
    }
}

/// Mini-lecteur flottant au-dessus de la barre d'onglets.
struct MiniPlayerView: View {
    @EnvironmentObject private var player: PlayerManager
    @AppStorage(SettingsKey.calmTitles) private var calmTitles = false

    var body: some View {
        if let item = player.current {
            HStack(spacing: 12) {
                ZStack {
                    AsyncImage(url: item.thumbnailURL) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                    if !player.audioOnly && !player.isLoading { VideoLayerView(player: player.player) }
                }
                .frame(width: 88, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    let title = player.info?.title ?? item.title
                    Text(calmTitles ? CalmTitle.apply(title) : title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(player.info?.channelName ?? item.channelName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Group {
                    if player.isLoading {
                        ProgressView().frame(width: 36, height: 36)
                    } else {
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
                    }
                    Button { player.stop() } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }
                        .accessibilityLabel("Fermer le lecteur")
                }
                .font(.title3)
                .foregroundStyle(.primary)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Capsule().fill(Color.accentColor)
                        .frame(width: player.duration > 0 ? geo.size.width * min(player.currentTime / player.duration, 1) : 0, height: 2.5)
                }
                .frame(height: 2.5)
                .padding(.horizontal, 14)
            }
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { player.showFullPlayer = true }
            .gesture(DragGesture().onEnded { v in if v.translation.height < -30 { player.showFullPlayer = true } })
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
