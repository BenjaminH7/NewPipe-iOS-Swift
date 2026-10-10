import Foundation
import SwiftData
import UniformTypeIdentifiers
import SwiftUI
import NewPipeExtractor

/// Import/export des abonnements, compatible avec NewPipe Android et Google Takeout.
enum SubscriptionTransfer {
    struct Entry: Hashable { var channelId: String; var name: String }

    /// Format d'export NewPipe :
    /// {"app_version":"0.27.0","app_version_int":1000,"subscriptions":[{"service_id":0,"url":"https://www.youtube.com/channel/UC…","name":"…"}]}
    /// Format Takeout (subscriptions.csv) : "Channel Id,Channel Url,Channel Title"
    static func parse(_ data: Data) async throws -> [Entry] {
        if let json = try? JSONNode(data: data), json["subscriptions"].exists {
            var result: [Entry] = []
            for sub in json["subscriptions"].array where (sub["service_id"].int ?? 0) == 0 {
                guard let url = sub["url"].string, let name = sub["name"].string else { continue }
                if case .channel(let id)? = YouTubeService.parseLink(url) {
                    result.append(Entry(channelId: id, name: name))
                } else if case .channel(let id)? = try? await Services.youtube.resolve(url) {
                    result.append(Entry(channelId: id, name: name))
                }
            }
            return result
        }
        guard let text = String(data: data, encoding: .utf8) else { throw ExtractionError.parsing("fichier") }
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let cols = line.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cols.count >= 3, cols[0].hasPrefix("UC") else { return nil }
            return Entry(channelId: cols[0], name: cols[2])
        }
    }

    @MainActor
    static func importEntries(_ entries: [Entry], into context: ModelContext) -> Int {
        let existing = Set(((try? context.fetch(FetchDescriptor<Subscription>())) ?? []).map(\.channelId))
        var added = 0
        for e in entries where !existing.contains(e.channelId) {
            context.insert(Subscription(channelId: e.channelId, name: e.name))
            added += 1
        }
        try? context.save()
        return added
    }

    static func exportNewPipeJSON(_ subs: [Subscription]) -> Data {
        let payload: [String: Any] = [
            "app_version": "0.27.0",
            "app_version_int": 1000,
            "subscriptions": subs.map { ["service_id": 0, "url": "https://www.youtube.com/channel/\($0.channelId)", "name": $0.name] },
        ]
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
    }
}

struct SubscriptionsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
