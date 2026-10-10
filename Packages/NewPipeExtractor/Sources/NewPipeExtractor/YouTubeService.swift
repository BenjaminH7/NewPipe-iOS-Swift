import Foundation

/// Point d'entrée de l'extracteur, équivalent de `ServiceList.YouTube` dans NewPipeExtractor.
public final class YouTubeService: @unchecked Sendable {
    public let client: InnerTubeClient

    public init(client: InnerTubeClient = InnerTubeClient()) {
        self.client = client
    }

    // MARK: Recherche

    public enum SearchFilter: String, CaseIterable, Sendable {
        case all, videos, channels, playlists

        /// Paramètres protobuf encodés utilisés par youtube.com pour filtrer par type.
        var params: String? {
            switch self {
            case .all: nil
            case .videos: "EgIQAQ%3D%3D"
            case .channels: "EgIQAg%3D%3D"
            case .playlists: "EgIQAw%3D%3D"
            }
        }
    }

    public func search(_ query: String, filter: SearchFilter = .all) async throws -> Page<InfoItem> {
        var body: [String: Any] = ["query": query]
        if let p = filter.params?.removingPercentEncoding { body["params"] = p }
        return Parsers.items(in: try await client.post("search", body: body))
    }

    public func searchContinuation(_ token: String) async throws -> Page<InfoItem> {
        Parsers.items(in: try await client.post("search", body: ["continuation": token]))
    }

    public func suggestions(_ query: String) async throws -> [String] {
        var c = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")!
        c.queryItems = [.init(name: "client", value: "youtube"), .init(name: "ds", value: "yt"),
                        .init(name: "hl", value: client.language), .init(name: "gl", value: client.region),
                        .init(name: "q", value: query)]
        let data = try await client.get(c.url!)
        // Réponse JSONP : window.google.ac.h(["q",[["sugg",0,[512]],...]])
        guard let text = String(data: data, encoding: .utf8),
              let start = text.firstIndex(of: "("), let end = text.lastIndex(of: ")") else { return [] }
        let json = try JSONNode(data: Data(text[text.index(after: start)..<end].utf8))
        return json[1].array.compactMap { $0[0].string }
    }

    // MARK: Vidéo

    public func streamInfo(id: String) async throws -> StreamInfo {
        await client.ensureVisitorData()
        async let nextTask = client.post("next", body: ["videoId": id, "racyCheckOk": true, "contentCheckOk": true])
        async let iosTask = player(id: id, profile: .ios)
        async let vrTask = player(id: id, profile: .androidVR)
        async let visionTask = player(id: id, profile: .visionOS)

        let next = try? await nextTask
        let ios = try? await iosTask
        let vr = try? await vrTask
        let vision = try? await visionTask

        guard let main = [vision, ios, vr].compactMap({ $0 }).first(where: { $0.path("playabilityStatus.status").string == "OK" })
                ?? vision ?? ios ?? vr else { throw ExtractionError.notFound }
        let status = main.path("playabilityStatus.status").string ?? ""
        guard status == "OK" else {
            throw ExtractionError.unplayable(main.path("playabilityStatus.reason").string ?? status)
        }

        let details = main["videoDetails"]
        var muxed: [MediaFormat] = []
        var adaptive: [MediaFormat] = []
        for (json, profile) in [(vr, InnerTubeProfile.androidVR), (ios, InnerTubeProfile.ios), (vision, InnerTubeProfile.visionOS)] {
            guard let json, json.path("playabilityStatus.status").string == "OK" else { continue }
            let sd = json["streamingData"]
            if muxed.isEmpty { muxed = Parsers.formats(sd["formats"], userAgent: profile.userAgent) }
            if adaptive.isEmpty { adaptive = Parsers.formats(sd["adaptiveFormats"], userAgent: profile.userAgent) }
        }
        // Le HLS de VISIONOS se lit en entier ; celui d'IOS n'est plus fourni pour la plupart des vidéos.
        let hls = [vision, ios, vr].lazy.compactMap { $0?.path("streamingData.hlsManifestUrl").string }.first
            .flatMap(URL.init(string:))

        var info = StreamInfo(
            id: id,
            title: details["title"].string ?? "",
            description: details["shortDescription"].string ?? "",
            channelName: details["author"].string ?? "",
            channelId: details["channelId"].string,
            viewCount: details["viewCount"].int,
            duration: details["lengthSeconds"].int ?? 0,
            isLive: details["isLive"].bool ?? false,
            hlsURL: hls,
            muxedFormats: muxed,
            videoOnlyFormats: adaptive.filter { $0.hasVideo },
            audioOnlyFormats: adaptive.filter { !$0.hasVideo && $0.hasAudio },
            related: [])
        // Les URL directes d'un direct sont des fragments DASH, inutilisables par AVPlayer.
        if info.isLive {
            info.muxedFormats = []; info.videoOnlyFormats = []; info.audioOnlyFormats = []
        }

        if let next {
            let primary = next.first("videoPrimaryInfoRenderer")
            let secondary = next.first("videoSecondaryInfoRenderer")
            let owner = secondary.path("owner.videoOwnerRenderer")
            if info.title.isEmpty { info.title = primary["title"].text ?? "" }
            info.dateText = primary["dateText"].text ?? primary["relativeDateText"].text
            info.channelAvatarURL = Parsers.imageURL(owner["thumbnail"])
            info.channelSubscriberText = owner["subscriberCountText"].text
            info.likeCountText = next.first("likeButtonViewModel").strings(forKey: "title").first { !$0.isEmpty }
            if let full = secondary["attributedDescription"].text, !full.isEmpty { info.description = full }
            let secondaryResults = next.first("secondaryResults")
            info.related = Parsers.streams(in: secondaryResults.exists ? secondaryResults : next).items.filter { $0.id != id }
            info.commentsContinuation = next.collect(["itemSectionRenderer"])
                .first { $0.node["sectionIdentifier"].string == "comment-item-section" }?.node.first("token").string
            info.commentCountText = next.collect(["engagementPanelSectionListRenderer"])
                .first { $0.node["panelIdentifier"].string == "engagement-panel-comments-section" }?
                .node.first("contextualInfo").text
        }
        return info
    }

    /// Commentaires (ou réponses à un commentaire) à partir d'un jeton de continuation.
    public func comments(_ token: String) async throws -> CommentsPage {
        Parsers.comments(in: try await client.post("next", body: ["continuation": token]))
    }

    func player(id: String, profile: InnerTubeProfile) async throws -> JSONNode {
        try await client.post("player", body: [
            "videoId": id, "contentCheckOk": true, "racyCheckOk": true,
        ], profile: profile)
    }

    public func relatedContinuation(_ token: String) async throws -> Page<StreamItem> {
        Parsers.streams(in: try await client.post("next", body: ["continuation": token]))
    }

    // MARK: Chaîne

    public func channel(id: String) async throws -> ChannelInfo {
        // Onglet "Vidéos"
        let json = try await client.post("browse", body: ["browseId": id, "params": "EgZ2aWRlb3PyBgQKAjoA"])
        let meta = json.path("metadata.channelMetadataRenderer")
        let name = meta["title"].string ?? json.first("pageTitle").string ?? ""
        let header = json["header"]
        var videos = Parsers.streams(in: json["contents"])
        for i in videos.items.indices {
            videos.items[i].channelName = videos.items[i].channelName ?? name
            videos.items[i].channelId = id
        }
        let subs = header.collect(["metadataParts"]).flatMap { $0.node.array.compactMap { $0["text"].text } }
            .first { $0.rangeOfCharacter(from: .decimalDigits) != nil && !$0.hasPrefix("@") }
        return ChannelInfo(
            id: meta["externalId"].string ?? id,
            name: name,
            avatarURL: Parsers.imageURL(meta["avatar"]),
            bannerURL: header.first("imageBannerViewModel")["image"].exists
                ? Parsers.imageURL(header.first("imageBannerViewModel")["image"]) : nil,
            description: meta["description"].string,
            subscriberText: subs,
            videos: videos)
    }

    public func channelContinuation(_ token: String, channelId: String, channelName: String) async throws -> Page<StreamItem> {
        var page = Parsers.streams(in: try await client.post("browse", body: ["continuation": token]))
        for i in page.items.indices {
            page.items[i].channelName = page.items[i].channelName ?? channelName
            page.items[i].channelId = channelId
        }
        return page
    }

    // MARK: Playlist

    public func playlist(id: String) async throws -> PlaylistInfo {
        let json = try await client.post("browse", body: ["browseId": "VL" + id])
        let title = json.path("metadata.playlistMetadataRenderer.title").string
            ?? json.first("pageTitle").string ?? ""
        let owner = json["header"].strings(forKey: "content").first
        return PlaylistInfo(id: id, title: title, channelName: owner, items: Parsers.streams(in: json["contents"]))
    }

    public func playlistContinuation(_ token: String) async throws -> Page<StreamItem> {
        Parsers.streams(in: try await client.post("browse", body: ["continuation": token]))
    }

    // MARK: Flux d'abonnements (RSS, comme le "fast mode" de NewPipe)

    public func feed(channelId: String) async throws -> [StreamItem] {
        do {
            let data = try await client.get(URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)")!)
            let items = RSSFeedParser.parse(data)
            if !items.isEmpty { return items }
        } catch {}
        // Repli : onglet Vidéos de la chaîne.
        return try await channel(id: channelId).videos.items
    }

    // MARK: Résolution d'URL (liens partagés, @handles)

    public enum Link: Sendable, Equatable {
        case stream(String), channel(String), playlist(String)
    }

    public func resolve(_ input: String) async throws -> Link? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = Self.parseLink(text) { return link }
        guard text.contains("youtube.com") || text.contains("youtu.be") || text.hasPrefix("@") else { return nil }
        let url = text.hasPrefix("@") ? "https://www.youtube.com/\(text)" : text
        let json = try await client.post("navigation/resolve_url", body: ["url": url])
        if let id = json.path("endpoint.browseEndpoint.browseId").string, id.hasPrefix("UC") { return .channel(id) }
        if let id = json.path("endpoint.watchEndpoint.videoId").string { return .stream(id) }
        return nil
    }

    /// Analyse locale des formes d'URL courantes, sans requête réseau.
    public static func parseLink(_ text: String) -> Link? {
        guard let comps = URLComponents(string: text), let host = comps.host?.lowercased() else { return nil }
        let q = Dictionary(comps.queryItems?.compactMap { i in i.value.map { (i.name, $0) } } ?? [], uniquingKeysWith: { a, _ in a })
        let parts = comps.path.split(separator: "/").map(String.init)
        if host.hasSuffix("youtu.be"), let id = parts.first { return .stream(id) }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else { return nil }
        if let v = q["v"] { return .stream(v) }
        if parts.first == "shorts" || parts.first == "live" || parts.first == "embed", parts.count > 1 { return .stream(parts[1]) }
        if parts.first == "channel", parts.count > 1 { return .channel(parts[1]) }
        if let list = q["list"] { return .playlist(list) }
        return nil
    }
}
