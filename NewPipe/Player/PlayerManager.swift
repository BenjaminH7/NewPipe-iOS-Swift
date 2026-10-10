import AVKit
import MediaPlayer
import SwiftData
import SwiftUI
import NewPipeExtractor

/// Lecteur global (équivalent du PlayerService de NewPipe) :
/// file d'attente, lecture en arrière-plan, Picture-in-Picture, contrôles de l'écran verrouillé,
/// reprise de la lecture et enregistrement de l'historique.
@MainActor
final class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    let player = AVPlayer()

    @Published private(set) var queue: [StreamItem] = []
    @Published private(set) var index = 0
    @Published private(set) var info: StreamInfo?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPlayingOffline = false
    @Published var error: String?
    @Published private(set) var audioOnly = false
    @Published var showFullPlayer = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPiPActive = false
    /// Rappel de pause à afficher (mode concentration).
    @Published var breakReminderDue = false
    /// Lecteur plein écran natif (AVPlayerViewController présenté par-dessus tout, à l'horizontale).
    @Published private(set) var isFullscreen = false
    private var fullscreenReturnsToPlayer = false

    var current: StreamItem? { queue.indices.contains(index) ? queue[index] : nil }
    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 }

    weak var playerController: AVPlayerViewController?
    var modelContext: ModelContext?

    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var lastSavedPosition: Double = 0
    private var lastTick: Date?
    private var unsavedWatchTime: Double = 0
    /// Temps regardé depuis le dernier rappel de pause.
    private var sessionWatchTime: Double = 0
    private var artwork: MPMediaItemArtwork?
    private var defaults: UserDefaults { .standard }

    override private init() {
        super.init()
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidEnd), name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        player.addObserver(self, forKeyPath: "timeControlStatus", options: [.new], context: nil)
        setupRemoteCommands()
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            self.isPlaying = self.player.timeControlStatus != .paused
            self.updateNowPlaying()
        }
    }

    static func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    // MARK: File d'attente

    /// Lance une vidéo. Si `queue` est fourni, la file est remplacée et démarre sur `item`.
    func play(_ item: StreamItem, queue newQueue: [StreamItem]? = nil, audioOnly: Bool = false, openPlayer: Bool = true) {
        if let newQueue, let i = newQueue.firstIndex(where: { $0.id == item.id }) {
            queue = newQueue
            index = i
        } else {
            queue = [item]
            index = 0
        }
        self.audioOnly = audioOnly
        if openPlayer && !audioOnly { showFullPlayer = true }
        load()
    }

    func enqueue(_ item: StreamItem) {
        if queue.isEmpty { play(item, openPlayer: false); return }
        queue.append(item)
    }

    func enqueueNext(_ item: StreamItem) {
        if queue.isEmpty { play(item, openPlayer: false); return }
        queue.insert(item, at: index + 1)
    }

    func removeFromQueue(at offsets: IndexSet) {
        for i in offsets.sorted(by: >) where i != index {
            queue.remove(at: i)
            if i < index { index -= 1 }
        }
    }

    func moveInQueue(from: IndexSet, to: Int) {
        let currentId = current?.id
        queue.move(fromOffsets: from, toOffset: to)
        if let currentId, let i = queue.firstIndex(where: { $0.id == currentId }) { index = i }
    }

    func jump(to i: Int) {
        guard queue.indices.contains(i) else { return }
        saveProgress()
        index = i
        load()
    }

    func next() {
        saveProgress()
        if hasNext {
            index += 1
            load()
        } else if defaults.bool(forKey: SettingsKey.autoplayNext),
                  let related = info?.related.filteringShorts(defaults.bool(forKey: SettingsKey.hideShorts))
                    .first(where: { r in !queue.contains { $0.id == r.id } }) {
            queue.append(related)
            index += 1
            load()
        }
    }

    func previous() {
        if currentTime > 5 || !hasPrevious {
            player.seek(to: .zero)
        } else {
            saveProgress()
            index -= 1
            load()
        }
    }

    func togglePlayPause() {
        isPlaying ? player.pause() : player.play()
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ delta: Double) { seek(to: max(0, currentTime + delta)) }

    func setAudioOnly(_ value: Bool) {
        guard value != audioOnly else { return }
        audioOnly = value
        load(resumeAt: currentTime)
    }

    /// Passe en plein écran. Le lecteur étant une feuille (qui bloque la rotation sur iPhone),
    /// on la ferme d'abord puis on présente le lecteur natif depuis la racine.
    func enterFullscreen() {
        guard !audioOnly, current != nil, !isFullscreen else { return }
        isFullscreen = true
        fullscreenReturnsToPlayer = showFullPlayer
        if showFullPlayer {
            showFullPlayer = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.presentFullscreen() }
        } else {
            presentFullscreen()
        }
    }

    private func presentFullscreen(attempt: Int = 0) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { isFullscreen = false; return }
        while let presented = top.presentedViewController { top = presented }
        // On attend que la feuille du lecteur ait fini de se fermer, sinon la présentation est ignorée.
        if (top.isBeingDismissed || top.isBeingPresented) && attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.presentFullscreen(attempt: attempt + 1) }
            return
        }
        let c = FullscreenPlayerController()
        c.player = player
        c.allowsPictureInPicturePlayback = false
        c.updatesNowPlayingInfoCenter = false
        c.speeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map { AVPlaybackSpeed(rate: $0, localizedName: "×\($0.formatted())") }
        c.modalPresentationStyle = .fullScreen
        c.onClose = { [weak self] in self?.fullscreenDidClose() }
        AppDelegate.orientationMask = UIDevice.current.userInterfaceIdiom == .phone ? .allButUpsideDown : .all
        top.present(c, animated: true) { [weak self] in
            guard c.presentingViewController != nil else { self?.fullscreenDidClose(); return }
            Self.setOrientation(.allButUpsideDown, request: .landscape, in: scene)
        }
    }

    private func fullscreenDidClose() {
        isFullscreen = false
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            Self.setOrientation(.portrait, request: .portrait, in: scene)
        }
        guard fullscreenReturnsToPlayer else { return }
        fullscreenReturnsToPlayer = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.showFullPlayer = true }
    }

    private static func setOrientation(_ allowed: UIInterfaceOrientationMask, request: UIInterfaceOrientationMask, in scene: UIWindowScene) {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        AppDelegate.orientationMask = allowed
        var vc = scene.keyWindow?.rootViewController
        while let c = vc {
            c.setNeedsUpdateOfSupportedInterfaceOrientations()
            vc = c.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: request)) { _ in }
    }

    func stop() {
        saveProgress()
        loadTask?.cancel()
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        info = nil
        showFullPlayer = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Chargement

    private func load(resumeAt: Double? = nil) {
        guard let item = current else { return }
        loadTask?.cancel()
        player.pause()
        error = nil
        isLoading = true
        artwork = nil
        currentTime = resumeAt ?? 0
        duration = Double(item.duration ?? 0)
        if info?.id != item.id { info = nil }
        updateNowPlaying()

        loadTask = Task {
            defer { if !Task.isCancelled { isLoading = false } }
            let offline = DownloadManager.shared.localFile(for: item.id, preferAudio: audioOnly)
            var fetched: StreamInfo?
            do {
                fetched = try await Services.youtube.streamInfo(id: item.id)
            } catch where offline == nil {
                if !Task.isCancelled { self.error = error.localizedDescription }
                return
            } catch {}
            guard !Task.isCancelled else { return }
            if let fetched {
                info = fetched
                if !queue.isEmpty, queue[index].id == fetched.id {
                    var updated = fetched.item
                    updated.viewCountText = queue[index].viewCountText ?? updated.viewCountText
                    queue[index] = updated
                }
            }

            let playerItem: AVPlayerItem
            if let offline {
                playerItem = AVPlayerItem(url: offline)
                isPlayingOffline = true
            } else if let fetched, let built = makeItem(for: fetched) {
                playerItem = built
                isPlayingOffline = false
            } else {
                error = info?.isLive == true
                    ? "Les directs ne sont pas encore pris en charge (YouTube ne fournit plus de flux HLS sans connexion)."
                    : "Aucun flux lisible trouvé pour cette vidéo."
                return
            }
            if !isPlayingOffline { await Self.preferOriginalAudio(playerItem, language: fetched?.originalAudioLanguage) }
            playerItem.externalMetadata = metadata()
            player.replaceCurrentItem(with: playerItem)

            var start = resumeAt ?? 0
            if resumeAt == nil, defaults.bool(forKey: SettingsKey.resumePlayback),
               let saved = historyEntry(for: item.id)?.position,
               saved > 10, Double(fetched?.duration ?? item.duration ?? 0) - saved > 15 {
                start = saved
            }
            if start > 0 { await player.seek(to: CMTime(seconds: start, preferredTimescale: 600)) }
            guard !Task.isCancelled else { return }
            player.play()
            recordHistory()
            loadArtwork(for: item)
        }
    }

    /// Les vidéos doublées ont une vingtaine de pistes audio sans piste par défaut : iOS prendrait celle
    /// de la langue du téléphone (le doublage). On sélectionne la piste dans la langue d'origine de la vidéo.
    /// Les doublages restent disponibles dans le menu audio du lecteur.
    private static func preferOriginalAudio(_ item: AVPlayerItem, language: String?) async {
        guard let language,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), group.options.count > 1,
              let original = group.options.first(where: { option in
                  guard let tag = option.extendedLanguageTag ?? option.locale?.identifier else { return false }
                  return tag == language || tag.hasPrefix(language + "-")
              })
        else { return }
        item.select(original, in: group)
    }

    private func makeItem(for info: StreamInfo) -> AVPlayerItem? {
        if let hls = info.hlsURL {
            // Les URL directes sont coupées après ~1 min sans PO token : on passe aussi par HLS
            // en mode audio seul, en limitant la vidéo à la plus petite résolution.
            let item = AVPlayerItem(url: hls)
            let maxRes = audioOnly ? 144 : defaults.integer(forKey: SettingsKey.maxResolution)
            if maxRes > 0 { item.preferredMaximumResolution = CGSize(width: maxRes * 16 / 9, height: maxRes) }
            return item
        }
        if audioOnly, let audio = info.bestAudio {
            return AVPlayerItem(asset: asset(audio.url, userAgent: audio.userAgent))
        }
        if let muxed = info.muxedFormats.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }) {
            return AVPlayerItem(asset: asset(muxed.url, userAgent: muxed.userAgent))
        }
        if let audio = info.bestAudio {
            return AVPlayerItem(asset: asset(audio.url, userAgent: audio.userAgent))
        }
        return nil
    }

    private func asset(_ url: URL, userAgent: String?) -> AVURLAsset {
        var options: [String: Any] = [:]
        if let userAgent { options["AVURLAssetHTTPHeaderFieldsKey"] = ["User-Agent": userAgent] }
        return AVURLAsset(url: url, options: options)
    }

    private func metadata() -> [AVMetadataItem] {
        guard let item = current else { return [] }
        func entry(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value else { return nil }
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value as NSString
            m.extendedLanguageTag = "und"
            return m
        }
        return [entry(.commonIdentifierTitle, item.title), entry(.commonIdentifierArtist, item.channelName)].compactMap { $0 }
    }

    // MARK: Progression, historique

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        if abs(seconds - lastSavedPosition) >= 5 { saveProgress() }
        trackWatchTime()
    }

    /// Cumule le temps de lecture réel (statistiques du jour et rappel de pause).
    private func trackWatchTime() {
        let now = Date()
        defer { lastTick = isPlaying ? now : nil }
        guard isPlaying, let last = lastTick else { return }
        let delta = min(now.timeIntervalSince(last), 2)
        unsavedWatchTime += delta
        sessionWatchTime += delta
        if unsavedWatchTime >= 15 {
            WatchTime.add(unsavedWatchTime)
            unsavedWatchTime = 0
        }
        let limit = defaults.integer(forKey: SettingsKey.breakReminder)
        if limit > 0, sessionWatchTime >= Double(limit * 60), !breakReminderDue {
            player.pause()
            breakReminderDue = true
        }
    }

    /// Réponse au rappel de pause.
    func dismissBreakReminder(resume: Bool) {
        breakReminderDue = false
        sessionWatchTime = 0
        if resume { player.play() }
    }

    @objc private func itemDidEnd(_ note: Notification) {
        guard (note.object as? AVPlayerItem) === player.currentItem else { return }
        if let id = current?.id, let entry = historyEntry(for: id) { entry.position = 0 }
        lastSavedPosition = 0
        next()
    }

    private func historyEntry(for id: String) -> HistoryEntry? {
        guard let modelContext else { return nil }
        var fd = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoId == id })
        fd.fetchLimit = 1
        return try? modelContext.fetch(fd).first
    }

    private func recordHistory() {
        guard defaults.bool(forKey: SettingsKey.historyEnabled), let item = current, let modelContext else { return }
        if let entry = historyEntry(for: item.id) {
            entry.watchedAt = .now
            entry.watchCount += 1
            entry.stream = item
        } else {
            modelContext.insert(HistoryEntry(stream: item))
        }
        try? modelContext.save()
    }

    func saveProgress() {
        guard defaults.bool(forKey: SettingsKey.historyEnabled), let id = current?.id,
              currentTime > 0, let entry = historyEntry(for: id) else { return }
        entry.position = currentTime
        lastSavedPosition = currentTime
    }

    // MARK: Arrière-plan & PiP

    @objc private func didEnterBackground() {
        saveProgress()
        try? modelContext?.save()
        guard !isPiPActive else { return }
        if defaults.bool(forKey: SettingsKey.backgroundPlayback) {
            // Technique recommandée par Apple : détacher le lecteur de la vue pour continuer l'audio.
            playerController?.player = nil
        } else {
            player.pause()
        }
    }

    @objc private func willEnterForeground() {
        playerController?.player = player
    }

    // MARK: Écran verrouillé / Centre de contrôle

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in self?.skip(15); return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-15); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let item = current else { return }
        var np: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.channelName ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(player.rate) : 0,
            MPNowPlayingInfoPropertyMediaType: audioOnly ? MPNowPlayingInfoMediaType.audio.rawValue : MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if info?.isLive == true { np[MPNowPlayingInfoPropertyIsLiveStream] = true }
        if let artwork { np[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = np
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = hasNext || defaults.bool(forKey: SettingsKey.autoplayNext)
    }

    private func loadArtwork(for item: StreamItem) {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: item.largeThumbnailURL),
                  let image = UIImage(data: data), current?.id == item.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateNowPlaying()
        }
    }
}

extension PlayerManager: AVPlayerViewControllerDelegate {
    nonisolated func playerViewControllerDidStartPictureInPicture(_ c: AVPlayerViewController) {
        Task { @MainActor in self.isPiPActive = true }
    }

    nonisolated func playerViewControllerDidStopPictureInPicture(_ c: AVPlayerViewController) {
        Task { @MainActor in self.isPiPActive = false }
    }

    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ c: AVPlayerViewController) -> Bool {
        false
    }

    nonisolated func playerViewController(_ c: AVPlayerViewController,
                                          restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completion: @escaping (Bool) -> Void) {
        Task { @MainActor in
            self.showFullPlayer = true
            completion(true)
        }
    }
}

/// Lecteur plein écran natif : bouton ✕ d'iOS, rotation automatique. Prévient à sa fermeture.
final class FullscreenPlayerController: AVPlayerViewController {
    var onClose: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onClose?()
            onClose = nil
        }
    }
}
