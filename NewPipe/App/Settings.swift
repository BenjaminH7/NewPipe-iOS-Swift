import SwiftUI
import NewPipeExtractor

/// Clés des réglages (UserDefaults), utilisées via @AppStorage.
enum SettingsKey {
    static let maxResolution = "maxResolution"          // 0 = auto
    static let backgroundPlayback = "backgroundPlayback"
    static let autoPiP = "autoPiP"
    static let autoplayNext = "autoplayNext"
    static let resumePlayback = "resumePlayback"
    static let historyEnabled = "historyEnabled"
    static let searchHistoryEnabled = "searchHistoryEnabled"
    static let downloadResolution = "downloadResolution"
    static let contentLanguage = "contentLanguage"
    static let contentCountry = "contentCountry"
    static let feedHideWatched = "feedHideWatched"
    static let feedSinceSubscription = "feedSinceSubscription"  // seulement les vidéos sorties après l'abonnement
    static let videoLayout = "videoLayout"              // VideoLayout

    // Concentration
    static let focusMode = "focusMode"
    static let focusBackup = "focusBackup"              // réglages d'avant le mode concentration
    static let hideShorts = "hideShorts"
    static let commentsMode = "commentsMode"            // RevealMode
    static let suggestionsMode = "suggestionsMode"      // RevealMode
    static let hideCounts = "hideCounts"
    static let thumbnailMode = "thumbnailMode"          // ThumbnailMode
    static let calmTitles = "calmTitles"
    static let searchSuggestions = "searchSuggestions"
    static let breakReminder = "breakReminder"          // minutes, 0 = désactivé
    static let watchTime = "watchTime"                  // [jour: secondes]
}

/// Affichage d'un élément pouvant distraire (commentaires, suggestions).
enum RevealMode: String, CaseIterable, Identifiable {
    case visible, onDemand, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .visible: "Visibles"
        case .onDemand: "Sur demande"
        case .hidden: "Masqués"
        }
    }
}

enum ThumbnailMode: String, CaseIterable, Identifiable {
    case normal, blurred, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: "Normales"
        case .blurred: "Floutées"
        case .hidden: "Masquées"
        }
    }
}

enum VideoLayout: String, CaseIterable, Identifiable {
    case cards, list
    var id: String { rawValue }
    var label: String { self == .cards ? "Grandes cartes" : "Liste compacte" }
}

/// Mode concentration : applique d'un coup les réglages anti-distraction,
/// et restaure les réglages précédents quand on le désactive.
enum FocusMode {
    static let preset: [String: Any] = [
        SettingsKey.hideShorts: true,
        SettingsKey.commentsMode: RevealMode.hidden.rawValue,
        SettingsKey.suggestionsMode: RevealMode.hidden.rawValue,
        SettingsKey.hideCounts: true,
        SettingsKey.thumbnailMode: ThumbnailMode.blurred.rawValue,
        SettingsKey.calmTitles: true,
        SettingsKey.searchSuggestions: false,
        SettingsKey.autoplayNext: false,
        SettingsKey.breakReminder: 30,
    ]

    static func setEnabled(_ enabled: Bool) {
        let d = UserDefaults.standard
        if enabled {
            var backup: [String: Any] = [:]
            for key in preset.keys { backup[key] = d.object(forKey: key) }
            d.set(backup, forKey: SettingsKey.focusBackup)
            preset.forEach { d.set($1, forKey: $0) }
        } else if let backup = d.dictionary(forKey: SettingsKey.focusBackup) {
            backup.forEach { d.set($1, forKey: $0) }
            d.removeObject(forKey: SettingsKey.focusBackup)
        }
        d.set(enabled, forKey: SettingsKey.focusMode)
    }
}

/// Temps de visionnage par jour (7 derniers jours), pour l'écran Concentration.
enum WatchTime {
    static func dayKey(_ date: Date = .now) -> String {
        date.formatted(.iso8601.year().month().day())
    }

    static func add(_ seconds: Double) {
        let d = UserDefaults.standard
        var days = d.dictionary(forKey: SettingsKey.watchTime) as? [String: Double] ?? [:]
        days[dayKey(), default: 0] += seconds
        // On ne garde qu'une semaine.
        let keep = Set((0..<7).map { dayKey(Calendar.current.date(byAdding: .day, value: -$0, to: .now)!) })
        days = days.filter { keep.contains($0.key) }
        d.set(days, forKey: SettingsKey.watchTime)
    }

    /// Secondes regardées pour chacun des 7 derniers jours, du plus ancien au plus récent.
    static func lastWeek(from raw: [String: Double]) -> [(day: Date, seconds: Double)] {
        (0..<7).reversed().map { offset in
            let day = Calendar.current.date(byAdding: .day, value: -offset, to: .now)!
            return (day, raw[dayKey(day)] ?? 0)
        }
    }
}

/// « Titres apaisés » : moins de majuscules criardes, de ponctuation répétée et de hashtags.
enum CalmTitle {
    static func apply(_ title: String) -> String {
        var words = title.split(separator: " ").map(String.init).filter { !$0.hasPrefix("#") }
        if words.isEmpty { return title }
        words = words.map { word in
            let letters = word.filter(\.isLetter)
            return letters.count >= 4 && letters == letters.uppercased() && letters != letters.lowercased()
                ? word.lowercased() : word
        }
        var result = words.joined(separator: " ")
        result.replace(#/([!?])[!?]+/#) { String($0.output.1) }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}

extension UserDefaults {
    static func registerAppDefaults() {
        standard.register(defaults: [
            SettingsKey.videoLayout: VideoLayout.cards.rawValue,
            SettingsKey.focusMode: false,
            SettingsKey.hideShorts: true,
            SettingsKey.commentsMode: RevealMode.onDemand.rawValue,
            SettingsKey.suggestionsMode: RevealMode.visible.rawValue,
            SettingsKey.hideCounts: false,
            SettingsKey.thumbnailMode: ThumbnailMode.normal.rawValue,
            SettingsKey.calmTitles: false,
            SettingsKey.searchSuggestions: true,
            SettingsKey.breakReminder: 0,
            SettingsKey.maxResolution: 0,
            SettingsKey.backgroundPlayback: true,
            SettingsKey.autoPiP: true,
            SettingsKey.autoplayNext: true,
            SettingsKey.resumePlayback: true,
            SettingsKey.historyEnabled: true,
            SettingsKey.searchHistoryEnabled: true,
            SettingsKey.downloadResolution: 720,
            SettingsKey.contentLanguage: "fr",
            SettingsKey.contentCountry: "FR",
            SettingsKey.feedHideWatched: false,
            SettingsKey.feedSinceSubscription: true,
        ])
    }
}

/// Instance partagée de l'extracteur.
enum Services {
    static let youtube: YouTubeService = {
        let d = UserDefaults.standard
        return YouTubeService(client: InnerTubeClient(
            language: d.string(forKey: SettingsKey.contentLanguage) ?? "fr",
            region: d.string(forKey: SettingsKey.contentCountry) ?? "FR"))
    }()

    static func applyContentSettings() {
        let d = UserDefaults.standard
        youtube.client.language = d.string(forKey: SettingsKey.contentLanguage) ?? "fr"
        youtube.client.region = d.string(forKey: SettingsKey.contentCountry) ?? "FR"
    }
}

enum Format {
    static func duration(_ seconds: Int?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func count(_ n: Int?) -> String? {
        guard let n else { return nil }
        return n.formatted(.number.notation(.compactName))
    }

    static func relative(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(.relative(presentation: .named))
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

extension StreamItem {
    /// Ligne de métadonnées : "Chaîne • 1,2 M de vues • il y a 3 jours" (sans les vues si `hideCounts`).
    func subtitle(hideCounts: Bool = false, includeChannel: Bool = true) -> String {
        [includeChannel ? channelName : nil,
         hideCounts ? nil : viewCountText.flatMap { Int($0) != nil ? "\(Format.count(Int($0)) ?? $0) vues" : $0 },
         publishedText ?? Format.relative(publishedDate)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }

    func displayTitle(calm: Bool) -> String { calm ? CalmTitle.apply(title) : title }
}

extension Array where Element == StreamItem {
    /// Retire les Shorts si le réglage le demande.
    func filteringShorts(_ hide: Bool) -> [StreamItem] { hide ? filter { !$0.isShort } : self }
}
