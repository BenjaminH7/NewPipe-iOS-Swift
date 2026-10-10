import Foundation

public struct StreamItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String              // videoId
    public var title: String
    public var channelName: String?
    public var channelId: String?
    public var duration: Int?          // secondes
    public var viewCountText: String?
    public var publishedText: String?
    public var publishedDate: Date?
    public var isLive: Bool
    /// Optionnel pour rester compatible avec les données déjà enregistrées (historique, playlists).
    public var shortFlag: Bool?

    public init(id: String, title: String, channelName: String? = nil, channelId: String? = nil,
                duration: Int? = nil, viewCountText: String? = nil, publishedText: String? = nil,
                publishedDate: Date? = nil, isLive: Bool = false, isShort: Bool = false) {
        self.id = id; self.title = title; self.channelName = channelName; self.channelId = channelId
        self.duration = duration; self.viewCountText = viewCountText; self.publishedText = publishedText
        self.publishedDate = publishedDate; self.isLive = isLive; self.shortFlag = isShort ? true : nil
    }

    /// Vidéo au format Short (lien /shorts/ ou élément d'une étagère Shorts).
    public var isShort: Bool { shortFlag == true }

    public var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    public var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")! }
    public var largeThumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }
}

public struct ChannelItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String              // UC...
    public var name: String
    public var avatarURL: URL?
    public var subtitle: String?

    public init(id: String, name: String, avatarURL: URL? = nil, subtitle: String? = nil) {
        self.id = id; self.name = name; self.avatarURL = avatarURL; self.subtitle = subtitle
    }

    public var url: URL { URL(string: "https://www.youtube.com/channel/\(id)")! }
}

public struct PlaylistItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String              // PL...
    public var title: String
    public var channelName: String?
    public var thumbnailURL: URL?
    public var videoCountText: String?

    public init(id: String, title: String, channelName: String? = nil, thumbnailURL: URL? = nil, videoCountText: String? = nil) {
        self.id = id; self.title = title; self.channelName = channelName
        self.thumbnailURL = thumbnailURL; self.videoCountText = videoCountText
    }
}

public enum InfoItem: Identifiable, Hashable, Sendable {
    case stream(StreamItem)
    case channel(ChannelItem)
    case playlist(PlaylistItem)

    public var id: String {
        switch self {
        case .stream(let s): "v:" + s.id
        case .channel(let c): "c:" + c.id
        case .playlist(let p): "p:" + p.id
        }
    }
}

public struct Page<Item: Sendable>: Sendable {
    public var items: [Item]
    public var continuation: String?
}

public struct MediaFormat: Hashable, Sendable, Identifiable {
    public var itag: Int
    public var url: URL
    public var mimeType: String
    public var bitrate: Int
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var qualityLabel: String?
    public var contentLength: Int64?
    public var audioQuality: String?
    public var userAgent: String?
    /// Piste audio des vidéos multilingues : « en.4 » = originale, « fr.3 » = doublage.
    public var audioTrackId: String? = nil

    public var id: Int { itag }
    public var hasVideo: Bool { mimeType.hasPrefix("video/") }
    public var hasAudio: Bool { mimeType.hasPrefix("audio/") || mimeType.contains("mp4a") }
    public var isMP4: Bool { mimeType.hasPrefix("video/mp4") || mimeType.hasPrefix("audio/mp4") }
    public var isAVC: Bool { mimeType.contains("avc1") }
    public var fileExtension: String { mimeType.hasPrefix("audio/mp4") ? "m4a" : (mimeType.contains("webm") ? "webm" : "mp4") }
}

public struct StreamInfo: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var channelName: String
    public var channelId: String?
    public var channelAvatarURL: URL?
    public var channelSubscriberText: String?
    public var viewCount: Int?
    public var likeCountText: String?
    public var dateText: String?
    public var duration: Int
    public var isLive: Bool
    public var hlsURL: URL?
    /// Formats vidéo+audio (souvent seulement le 360p).
    public var muxedFormats: [MediaFormat]
    public var videoOnlyFormats: [MediaFormat]
    public var audioOnlyFormats: [MediaFormat]
    public var related: [StreamItem]
    /// Jeton de la première page de commentaires (nil si désactivés).
    public var commentsContinuation: String? = nil
    /// Nombre de commentaires abrégé (« 4,3 M »).
    public var commentCountText: String? = nil

    public var item: StreamItem {
        StreamItem(id: id, title: title, channelName: channelName, channelId: channelId,
                   duration: duration, viewCountText: viewCount.map { "\($0)" }, publishedText: dateText, isLive: isLive)
    }
    public var thumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }

    /// Langue de la piste audio d'origine des vidéos doublées (nil si une seule piste).
    public var originalAudioLanguage: String? {
        audioOnlyFormats.compactMap(\.audioTrackId).first { $0.hasSuffix(".4") }
            .map { String($0.prefix { $0 != "." }) }
    }

    /// Meilleur audio AAC (m4a), lisible et téléchargeable sur iOS.
    public var bestAudio: MediaFormat? {
        audioOnlyFormats.filter(\.isMP4).max { $0.bitrate < $1.bitrate } ?? audioOnlyFormats.max { $0.bitrate < $1.bitrate }
    }

    /// Vidéos H.264 (mp4) téléchargeables, une par hauteur, de la meilleure à la moins bonne.
    public var downloadableVideoFormats: [MediaFormat] {
        var byHeight: [Int: MediaFormat] = [:]
        for f in videoOnlyFormats where f.isAVC && f.isMP4 {
            let h = f.height ?? 0
            if let existing = byHeight[h], existing.bitrate >= f.bitrate { continue }
            byHeight[h] = f
        }
        return byHeight.values.sorted { ($0.height ?? 0) > ($1.height ?? 0) }
    }
}

public struct ChannelInfo: Sendable {
    public var id: String
    public var name: String
    public var avatarURL: URL?
    public var bannerURL: URL?
    public var description: String?
    public var subscriberText: String?
    public var videos: Page<StreamItem>
}

public struct PlaylistInfo: Sendable {
    public var id: String
    public var title: String
    public var channelName: String?
    public var items: Page<StreamItem>
}

public struct Comment: Identifiable, Hashable, Sendable {
    public var id: String
    public var author: String
    public var authorChannelId: String?
    public var authorAvatarURL: URL?
    public var text: String
    public var publishedText: String?
    public var likeCountText: String?
    public var replyCount: Int
    /// Jeton pour charger les réponses (nil s'il n'y en a pas).
    public var repliesContinuation: String?
    /// L'auteur est le créateur de la vidéo.
    public var isCreator: Bool
    public var isVerified: Bool
}

public struct CommentsPage: Sendable {
    public var comments: [Comment]
    public var continuation: String?
    /// Nombre total (« 4 395 927 commentaires »), présent sur la première page.
    public var countText: String?
}

public enum ExtractionError: LocalizedError, Sendable {
    case http(Int)
    case unplayable(String)
    case notFound
    case parsing(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): "Erreur réseau (HTTP \(code))"
        case .unplayable(let reason): "Vidéo indisponible : \(reason)"
        case .notFound: "Contenu introuvable"
        case .parsing(let what): "Impossible de lire la réponse de YouTube (\(what))"
        }
    }
}
