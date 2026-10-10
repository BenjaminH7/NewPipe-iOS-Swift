import Foundation

/// Convertit les différents "renderers" YouTube (anciens et nouveaux formats) en éléments du modèle.
enum Parsers {
    static let itemKeys: Set<String> = [
        "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer",
        "lockupViewModel", "channelRenderer", "playlistRenderer", "continuationItemRenderer",
        "shortsLockupViewModel", "reelItemRenderer",
    ]

    /// Extrait tous les éléments d'une réponse, plus le jeton de continuation éventuel.
    static func items(in json: JSONNode) -> Page<InfoItem> {
        var items: [InfoItem] = []
        var seen = Set<String>()
        var continuation: String?
        for (key, node) in json.collect(itemKeys) {
            let item: InfoItem?
            switch key {
            case "videoRenderer", "compactVideoRenderer", "gridVideoRenderer", "playlistVideoRenderer":
                item = video(node).map(InfoItem.stream)
            case "lockupViewModel":
                item = lockup(node)
            case "shortsLockupViewModel", "reelItemRenderer":
                item = short(node).map(InfoItem.stream)
            case "channelRenderer":
                item = channel(node).map(InfoItem.channel)
            case "playlistRenderer":
                item = playlist(node).map(InfoItem.playlist)
            case "continuationItemRenderer":
                continuation = node.first("token").string ?? continuation
                item = nil
            default:
                item = nil
            }
            if let item, seen.insert(item.id).inserted { items.append(item) }
        }
        return Page(items: items, continuation: continuation)
    }

    static func streams(in json: JSONNode) -> Page<StreamItem> {
        let page = items(in: json)
        return Page(items: page.items.compactMap { if case .stream(let s) = $0 { s } else { nil } },
                    continuation: page.continuation)
    }

    static func video(_ node: JSONNode) -> StreamItem? {
        guard let id = node["videoId"].string, let title = node["title"].text ?? node["headline"].text else { return nil }
        let owner = node["ownerText"].exists ? node["ownerText"] : (node["longBylineText"].exists ? node["longBylineText"] : node["shortBylineText"])
        let lengthText = node["lengthText"].text
        let isLive = lengthText == nil && node["lengthSeconds"].int == nil
            && (node.collect(["style"]).contains { $0.node.string?.contains("LIVE") == true })
        return StreamItem(
            id: id,
            title: title,
            channelName: owner.text,
            channelId: owner.path("runs.0.navigationEndpoint.browseEndpoint.browseId").string,
            duration: node["lengthSeconds"].int ?? lengthText.flatMap(parseDuration),
            viewCountText: node["shortViewCountText"].text ?? node["viewCountText"].text,
            publishedText: node["publishedTimeText"].text,
            isLive: isLive,
            isShort: isShort(node))
    }

    /// Un Short se reconnaît à son point d'entrée « reelWatchEndpoint » ou à un lien /shorts/.
    static func isShort(_ node: JSONNode) -> Bool {
        !node.collect(["reelWatchEndpoint"]).isEmpty || node.strings(forKey: "url").contains { $0.hasPrefix("/shorts/") }
    }

    /// Élément d'une étagère Shorts (« shortsLockupViewModel », ou l'ancien « reelItemRenderer »).
    static func short(_ node: JSONNode) -> StreamItem? {
        guard let id = node["videoId"].string ?? node.first("reelWatchEndpoint")["videoId"].string,
              let title = node.path("overlayMetadata.primaryText").text ?? node["headline"].text else { return nil }
        return StreamItem(id: id, title: title,
                          viewCountText: node.path("overlayMetadata.secondaryText").text ?? node["viewCountText"].text,
                          isShort: true)
    }

    /// Nouveau format "lockupViewModel" (suggestions, playlists, parfois recherche).
    static func lockup(_ node: JSONNode) -> InfoItem? {
        guard let id = node["contentId"].string else { return nil }
        let meta = node.path("metadata.lockupMetadataViewModel")
        guard let title = meta["title"].text else { return nil }
        let rows = meta.path("metadata.contentMetadataViewModel.metadataRows").array
            .map { $0["metadataParts"].array.compactMap { $0["text"].text } }
        let channelId = node.strings(forKey: "browseId").first { $0.hasPrefix("UC") }
        let type = node["contentType"].string ?? ""

        if type.contains("PLAYLIST") || type.contains("PODCAST") {
            let badge = node.strings(forKey: "text").first { $0.rangeOfCharacter(from: .decimalDigits) != nil && $0.count < 30 }
            let thumb = node.strings(forKey: "url").first { $0.contains("ytimg") }
            return .playlist(PlaylistItem(id: id, title: title, channelName: rows.first?.first,
                                          thumbnailURL: thumb.flatMap(URL.init(string:)), videoCountText: badge))
        }
        guard type.contains("VIDEO") || type.isEmpty else { return nil }
        let durationText = node.strings(forKey: "text").first { $0.range(of: #"^\d+(:\d{2})+$"#, options: .regularExpression) != nil }
        let isLive = durationText == nil && node.collect(["badgeStyle"]).contains { $0.node.string?.contains("LIVE") == true }
        // Sur la page d'une chaîne, il n'y a qu'une ligne "vues • date" et pas de nom de chaîne.
        let hasChannelRow = rows.count > 1
        let second = hasChannelRow ? rows[1] : (rows.first ?? [])
        return .stream(StreamItem(
            id: id, title: title,
            channelName: hasChannelRow ? rows.first?.first : nil,
            channelId: channelId,
            duration: durationText.flatMap(parseDuration),
            viewCountText: second.first,
            publishedText: second.count > 1 ? second[1] : nil,
            isLive: isLive,
            isShort: isShort(node)))
    }

    // MARK: Commentaires

    /// Page de commentaires (ou de réponses) renvoyée par `next` avec un jeton de continuation.
    /// Les éléments (`commentViewModel`) renvoient par clé vers les données (`commentEntityPayload`).
    static func comments(in json: JSONNode) -> CommentsPage {
        var entities: [String: JSONNode] = [:]
        for (_, entity) in json.collect(["commentEntityPayload"]) {
            if let key = entity["key"].string { entities[key] = entity }
        }
        var comments: [Comment] = []
        var continuation: String?
        for (key, node) in json.collect(["commentThreadRenderer", "commentViewModel", "continuationItemRenderer"]) {
            switch key {
            case "continuationItemRenderer":
                continuation = node.first("token").string ?? continuation
            case "commentThreadRenderer":
                let replies = node.path("replies.commentRepliesRenderer").first("token").string
                if let c = comment(node.first("commentViewModel"), entities: entities, replies: replies) { comments.append(c) }
            default:
                if let c = comment(node, entities: entities, replies: nil) { comments.append(c) }
            }
        }
        let header = json.first("commentsHeaderRenderer")["countText"].text
        return CommentsPage(comments: comments, continuation: continuation, countText: header)
    }

    private static func comment(_ viewModel: JSONNode, entities: [String: JSONNode], replies: String?) -> Comment? {
        // Le commentViewModel peut être imbriqué une fois de plus.
        let vm = viewModel["commentViewModel"].exists ? viewModel["commentViewModel"] : viewModel
        guard let key = vm["commentKey"].string, let entity = entities[key] else { return nil }
        let props = entity["properties"], author = entity["author"], toolbar = entity["toolbar"]
        let replyCount = toolbar["replyCount"].string.flatMap { Int($0.filter(\.isNumber)) } ?? 0
        let likes = toolbar["likeCountNotliked"].string?.trimmingCharacters(in: .whitespaces)
        return Comment(
            id: props["commentId"].string ?? key,
            author: author["displayName"].string ?? "",
            authorChannelId: author["channelId"].string,
            authorAvatarURL: author["avatarThumbnailUrl"].string.flatMap(URL.init(string:)),
            text: props.path("content.content").string ?? "",
            publishedText: props["publishedTime"].string,
            likeCountText: (likes?.isEmpty ?? true) ? nil : likes,
            replyCount: replyCount,
            repliesContinuation: replyCount > 0 ? replies : nil,
            isCreator: author["isCreator"].bool ?? false,
            isVerified: author["isVerified"].bool ?? false)
    }

    static func channel(_ node: JSONNode) -> ChannelItem? {
        guard let id = node["channelId"].string, let name = node["title"].text else { return nil }
        let subtitle = [node["subscriberCountText"].text, node["videoCountText"].text].compactMap { $0 }.joined(separator: " • ")
        return ChannelItem(id: id, name: name, avatarURL: imageURL(node["thumbnail"]), subtitle: subtitle.isEmpty ? nil : subtitle)
    }

    static func playlist(_ node: JSONNode) -> PlaylistItem? {
        guard let id = node["playlistId"].string, let title = node["title"].text else { return nil }
        let thumb = node.path("thumbnails.0").exists ? imageURL(node.path("thumbnails.0")) : imageURL(node["thumbnail"])
        return PlaylistItem(id: id, title: title,
                            channelName: (node["longBylineText"].exists ? node["longBylineText"] : node["shortBylineText"]).text,
                            thumbnailURL: thumb,
                            videoCountText: node["videoCountText"].text ?? node["videoCount"].string)
    }

    static func imageURL(_ thumbnail: JSONNode) -> URL? {
        let list = thumbnail["thumbnails"].exists ? thumbnail["thumbnails"] : thumbnail["sources"]
        guard var s = list.last["url"].string else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    static func parseDuration(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    static func formats(_ list: JSONNode, userAgent: String) -> [MediaFormat] {
        list.array.compactMap { f in
            guard let itag = f["itag"].int, let s = f["url"].string, let url = URL(string: s),
                  let mime = f["mimeType"].string else { return nil }  // formats chiffrés (signatureCipher) ignorés
            return MediaFormat(
                itag: itag, url: url, mimeType: mime,
                bitrate: f["bitrate"].int ?? 0,
                width: f["width"].int, height: f["height"].int, fps: f["fps"].int,
                qualityLabel: f["qualityLabel"].string,
                contentLength: f["contentLength"].string.flatMap { Int64($0) },
                audioQuality: f["audioQuality"].string,
                userAgent: userAgent,
                audioTrackId: f.path("audioTrack.id").string)
        }
    }
}
