import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Lit le flux Atom public d'une chaîne : https://www.youtube.com/feeds/videos.xml?channel_id=…
final class RSSFeedParser: NSObject, XMLParserDelegate {
    private var items: [StreamItem] = []
    private var channelName: String?
    private var current: [String: String]?
    private var buffer = ""
    private var inAuthor = false

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ data: Data) -> [StreamItem] {
        let delegate = RSSFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        buffer = ""
        switch name {
        case "entry": current = [:]
        case "author": inAuthor = true
        case "media:statistics": current?["views"] = attributes["views"]
        case "link": if attributes["href"]?.contains("/shorts/") == true { current?["short"] = "1" }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "author": inAuthor = false
        case "name" where inAuthor:
            if current != nil { current?["author"] = value } else { channelName = value }
        case "yt:videoId", "yt:channelId", "title", "published":
            current?[name] = value
        case "entry":
            if let e = current, let id = e["yt:videoId"] {
                let date = e["published"].flatMap { Self.isoFormatter.date(from: $0) }
                items.append(StreamItem(
                    id: id, title: e["title"] ?? "",
                    channelName: e["author"] ?? channelName,
                    channelId: e["yt:channelId"],
                    viewCountText: e["views"],
                    publishedDate: date,
                    isShort: e["short"] != nil))
            }
            current = nil
        default: break
        }
    }
}
