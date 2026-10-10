import Foundation
import SwiftData
import NewPipeExtractor

/// Abonnement local à une chaîne (aucun compte Google, comme NewPipe).
@Model
final class Subscription {
    @Attribute(.unique) var channelId: String
    var name: String
    var avatarURL: URL?
    var subscribedAt: Date

    init(channelId: String, name: String, avatarURL: URL? = nil) {
        self.channelId = channelId
        self.name = name
        self.avatarURL = avatarURL
        self.subscribedAt = .now
    }
}

/// Entrée de l'historique de visionnage, avec la position pour reprendre la lecture.
@Model
final class HistoryEntry {
    @Attribute(.unique) var videoId: String
    var stream: StreamItem
    var watchedAt: Date
    var position: Double
    var watchCount: Int

    init(stream: StreamItem) {
        self.videoId = stream.id
        self.stream = stream
        self.watchedAt = .now
        self.position = 0
        self.watchCount = 1
    }
}

/// Playlist locale.
@Model
final class LocalPlaylist {
    var name: String
    var createdAt: Date
    var items: [StreamItem]

    init(name: String) {
        self.name = name
        self.createdAt = .now
        self.items = []
    }
}

/// Playlist YouTube enregistrée (signet).
@Model
final class BookmarkedPlaylist {
    @Attribute(.unique) var playlistId: String
    var title: String
    var channelName: String?
    var thumbnailURL: URL?

    init(_ p: PlaylistItem) {
        playlistId = p.id
        title = p.title
        channelName = p.channelName
        thumbnailURL = p.thumbnailURL
    }
}

/// Historique des recherches.
@Model
final class SearchHistoryEntry {
    @Attribute(.unique) var query: String
    var date: Date

    init(query: String) {
        self.query = query
        self.date = .now
    }
}
