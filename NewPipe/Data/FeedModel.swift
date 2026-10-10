import Foundation
import NewPipeExtractor

/// Flux "Nouveautés" : récupère les dernières vidéos de chaque abonnement via RSS, en parallèle.
@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var items: [StreamItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var progress: (done: Int, total: Int) = (0, 0)
    @Published private(set) var failedChannels: [String] = []
    @Published private(set) var lastUpdate: Date?

    private let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("feed.json")

    init() {
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(Cache.self, from: data) {
            items = cached.items
            lastUpdate = cached.date
        }
    }

    private struct Cache: Codable { var date: Date; var items: [StreamItem] }

    func refresh(subscriptions: [(id: String, name: String)]) async {
        guard !isLoading else { return }
        isLoading = true
        failedChannels = []
        progress = (0, subscriptions.count)
        defer { isLoading = false }

        var collected: [StreamItem] = []
        var failed: [String] = []
        await withTaskGroup(of: (String, [StreamItem]?).self) { group in
            var iterator = subscriptions.makeIterator()
            // 8 requêtes simultanées maximum.
            for _ in 0..<8 {
                guard let sub = iterator.next() else { break }
                group.addTask { (sub.name, try? await Services.youtube.feed(channelId: sub.id)) }
            }
            for await (name, result) in group {
                if let result { collected += result } else { failed.append(name) }
                progress.done += 1
                if let sub = iterator.next() {
                    group.addTask { (sub.name, try? await Services.youtube.feed(channelId: sub.id)) }
                }
            }
        }
        var seen = Set<String>()
        items = collected
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.publishedDate ?? .distantPast) > ($1.publishedDate ?? .distantPast) }
        failedChannels = failed
        lastUpdate = .now
        if let data = try? JSONEncoder().encode(Cache(date: .now, items: items)) {
            try? data.write(to: cacheURL)
        }
    }

    func removeChannel(_ channelId: String) {
        items.removeAll { $0.channelId == channelId }
    }
}
