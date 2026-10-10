import Foundation
import NewPipeExtractor

// Usage : swift run extractor-cli [search|stream|channel|playlist|feed|resolve|hls|comments|renderers|dump] <arg>
let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "smoke"
let arg = args.dropFirst().joined(separator: " ")
let yt = YouTubeService(client: InnerTubeClient(language: "fr", region: "FR"))

func show(_ s: StreamItem) {
    print("  \(s.isShort ? "📱" : "🎬") \(s.id) | \(s.title) | \(s.channelName ?? "?") [\(s.channelId ?? "-")] | \(s.duration.map(String.init) ?? (s.isLive ? "LIVE" : "?"))s | \(s.viewCountText ?? "") | \(s.publishedText ?? s.publishedDate?.description ?? "")")
}

func show(_ item: InfoItem) {
    switch item {
    case .stream(let s): show(s)
    case .channel(let c): print("  📺 \(c.id) | \(c.name) | \(c.subtitle ?? "") | \(c.avatarURL?.absoluteString.prefix(40) ?? "")")
    case .playlist(let p): print("  📃 \(p.id) | \(p.title) | \(p.channelName ?? "") | \(p.videoCountText ?? "")")
    }
}

func run() async throws {
    switch command {
    case "search":
        let page = try await yt.search(arg)
        page.items.prefix(15).forEach(show)
        print("→ \(page.items.count) éléments, continuation: \(page.continuation != nil)")
        if let c = page.continuation {
            let next = try await yt.searchContinuation(c)
            print("→ page 2 : \(next.items.count) éléments")
        }
        print("Suggestions :", try await yt.suggestions(String(arg.prefix(4))))
    case "stream":
        let info = try await yt.streamInfo(id: arg)
        print("Titre : \(info.title)\nChaîne : \(info.channelName) [\(info.channelId ?? "")] \(info.channelSubscriberText ?? "")")
        print("Vues : \(info.viewCount ?? -1) | J'aime : \(info.likeCountText ?? "?") | Date : \(info.dateText ?? "?") | Durée : \(info.duration)s | Live : \(info.isLive)")
        print("HLS : \(info.hlsURL?.absoluteString ?? "AUCUN")")
        print("Audio d'origine : \(info.originalAudioLanguage ?? "piste unique")")
        print("Muxés : \(info.muxedFormats.map { "\($0.itag)/\($0.qualityLabel ?? "")" })")
        print("Vidéo H.264 : \(info.downloadableVideoFormats.map { $0.qualityLabel ?? "" })")
        print("Audio : \(info.bestAudio.map { "\($0.itag) \($0.mimeType) \($0.bitrate)" } ?? "AUCUN")")
        print("Description : \(info.description.prefix(100))…")
        print("Suggestions (\(info.related.count)) :"); info.related.prefix(5).forEach(show)
        for f in [info.bestAudio, info.downloadableVideoFormats.first].compactMap({ $0 }) {
            var req = URLRequest(url: f.url); req.httpMethod = "GET"
            req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            req.setValue(f.userAgent, forHTTPHeaderField: "User-Agent")
            let (_, resp) = try await URLSession.shared.data(for: req)
            print("Test téléchargement itag \(f.itag) → HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        if let hls = info.hlsURL {
            let (data, resp) = try await URLSession.shared.data(from: hls)
            print("Test HLS → HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0), \(data.count) octets")
        }
    case "channel":
        let c = try await yt.channel(id: arg)
        print("\(c.name) | \(c.subscriberText ?? "?") | avatar: \(c.avatarURL != nil) | bannière: \(c.bannerURL != nil)")
        c.videos.items.prefix(8).forEach(show)
        print("→ \(c.videos.items.count) vidéos, continuation: \(c.videos.continuation != nil)")
    case "playlist":
        let p = try await yt.playlist(id: arg)
        print("\(p.title) | \(p.channelName ?? "?")")
        p.items.items.prefix(8).forEach(show)
        print("→ \(p.items.items.count) vidéos, continuation: \(p.items.continuation != nil)")
    case "feed":
        let items = try await yt.feed(channelId: arg)
        items.prefix(5).forEach(show)
        print("→ \(items.count) vidéos")
    case "resolve":
        print(try await yt.resolve(arg) as Any)
    case "hls":
        // Affiche le manifeste HLS principal puis le début d'une playlist vidéo et audio.
        guard let master = try await yt.streamInfo(id: arg).hlsURL else { print("Pas de HLS"); return }
        let text = String(decoding: try await URLSession.shared.data(from: master).0, as: UTF8.self)
        let lines = text.split(separator: "\n").map(String.init)
        lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF") || $0.hasPrefix("#EXT-X-MEDIA") }.forEach { print($0.replacing(#/URI="[^"]*",?/#, with: "")) }
        let videoURL = lines.first { !$0.hasPrefix("#") && $0.contains("/itag/") }
        let audioURL = lines.first { $0.hasPrefix("#EXT-X-MEDIA") }?.firstMatch(of: #/URI="([^"]+)"/#)?.1
        for (label, url) in [("VIDÉO", videoURL), ("AUDIO", audioURL.map(String.init))] {
            guard let url, let u = URL(string: url) else { continue }
            let media = String(decoding: try await URLSession.shared.data(from: u).0, as: UTF8.self).split(separator: "\n")
            print("--- \(label) : \(media.filter { !$0.hasPrefix("#") }.count) segments")
            media.prefix(6).forEach { print("   " + $0.prefix(160)) }
            if let first = media.first(where: { !$0.hasPrefix("#") }), let s = URL(string: String(first)) {
                let (data, response) = try await URLSession.shared.data(from: s)
                let head = data.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("   1er segment : HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), \(data.count) octets, début \(head)")
            }
        }
    case "renderers":
        // Compte les types d'éléments d'une recherche (ou de la page vidéo avec « v:ID ») et les marqueurs de Shorts.
        let json = arg.hasPrefix("v:")
            ? try await yt.client.post("next", body: ["videoId": String(arg.dropFirst(2))])
            : try await yt.client.post("search", body: ["query": arg])
        var counts: [String: Int] = [:]
        for (key, _) in json.collect(["videoRenderer", "compactVideoRenderer", "lockupViewModel", "channelRenderer", "playlistRenderer", "reelItemRenderer", "shortsLockupViewModel", "reelShelfRenderer", "gridShelfViewModel"]) {
            counts[key, default: 0] += 1
        }
        print(counts.sorted { $0.key < $1.key })
        for (key, node) in json.collect(["videoRenderer", "lockupViewModel", "shortsLockupViewModel", "reelItemRenderer"]).prefix(40) {
            let urls = node.strings(forKey: "url").filter { $0.hasPrefix("/") }
            let shortMarks = [node.collect(["reelWatchEndpoint"]).isEmpty ? nil : "reelWatchEndpoint",
                              urls.contains { $0.hasPrefix("/shorts/") } ? "/shorts/" : nil,
                              node["contentType"].string].compactMap { $0 }
            print(key, node["videoId"].string ?? node["contentId"].string ?? node.first("videoId").string ?? "?", shortMarks)
        }
    case "comments":
        // Première page de commentaires, puis les réponses au premier commentaire qui en a.
        guard let token = try await yt.streamInfo(id: arg).commentsContinuation else { print("Commentaires désactivés"); return }
        let page = try await yt.comments(token)
        print("Total : \(page.countText ?? "?") | page suivante : \(page.continuation != nil)")
        for c in page.comments.prefix(10) {
            print("  💬 \(c.author)\(c.isCreator ? " (créateur)" : "") • \(c.publishedText ?? "") • 👍 \(c.likeCountText ?? "0") • ↩︎ \(c.replyCount)\n     \(c.text.prefix(100).replacingOccurrences(of: "\n", with: " "))")
        }
        if let replies = page.comments.first(where: { $0.repliesContinuation != nil })?.repliesContinuation {
            let r = try await yt.comments(replies)
            print("Réponses : \(r.comments.count), suite : \(r.continuation != nil)")
            r.comments.prefix(3).forEach { print("    ↩︎ \($0.author) : \($0.text.prefix(80))") }
        }
        if let next = page.continuation { print("Page 2 : \(try await yt.comments(next).comments.count) commentaires") }
    case "dump":
        // dump <videoId|continuation:TOKEN> <clé> [n] : affiche les n premiers nœuds portant cette clé dans la réponse `next`.
        let parts = arg.split(separator: " ").map(String.init)
        let body: [String: Any] = parts[0].hasPrefix("continuation:") ? ["continuation": String(parts[0].dropFirst(13))] : ["videoId": parts[0]]
        let json = try await yt.client.post("next", body: body)
        for (_, node) in json.collect([parts[1]]).prefix(parts.count > 2 ? Int(parts[2]) ?? 1 : 1) {
            if let raw = node.raw, let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.contains("trackingParams") && !$0.contains("loggingDirectives") }.prefix(120).joined(separator: "\n"))
            } else { print(node.raw as Any) }
        }
    default:
        print("Commandes : search, stream, channel, playlist, feed, resolve, hls, comments, renderers, dump")
    }
}

do { try await run() } catch { print("ERREUR :", error) ; exit(1) }
