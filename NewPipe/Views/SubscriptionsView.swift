import SwiftUI
import SwiftData
import NewPipeExtractor

struct SubscriptionsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var feed: FeedModel
    @Query(sort: \Subscription.name) private var subscriptions: [Subscription]

    @State private var filter = ""
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var importMessage: String?
    @State private var importing = false

    private var filtered: [Subscription] {
        filter.isEmpty ? subscriptions : subscriptions.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List {
            if importing {
                HStack { ProgressView(); Text("Import en cours…") }
            }
            ForEach(filtered) { sub in
                NavigationLink(value: Route.channel(id: sub.channelId, name: sub.name)) {
                    HStack(spacing: 14) {
                        Avatar(url: sub.avatarURL, size: 44, name: sub.name)
                        Text(sub.name).font(.body.weight(.medium))
                    }
                    .padding(.vertical, 2)
                }
                .swipeActions {
                    Button("Se désabonner", role: .destructive) {
                        feed.removeChannel(sub.channelId)
                        context.delete(sub)
                    }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $filter, prompt: "Filtrer")
        .navigationTitle("Abonnements (\(subscriptions.count))")
        .overlay {
            if subscriptions.isEmpty && !importing {
                ContentUnavailableView {
                    Label("Aucun abonnement", systemImage: "person.2")
                } description: {
                    Text("Importez un fichier d'export NewPipe (.json) ou Google Takeout (subscriptions.csv).")
                } actions: {
                    Button("Importer") { showImporter = true }.buttonStyle(.prominentPill)
                }
            }
        }
        .toolbar {
            Menu {
                Button { showImporter = true } label: { Label("Importer (NewPipe / Takeout)", systemImage: "square.and.arrow.down") }
                Button { showExporter = true } label: { Label("Exporter (format NewPipe)", systemImage: "square.and.arrow.up") }
                    .disabled(subscriptions.isEmpty)
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json, .commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            Task { await importFile(url) }
        }
        .fileExporter(isPresented: $showExporter,
                      document: SubscriptionsDocument(data: SubscriptionTransfer.exportNewPipeJSON(subscriptions)),
                      contentType: .json, defaultFilename: "newpipe_subscriptions") { _ in }
        .alert("Import", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
            Button("OK") {}
        } message: { Text(importMessage ?? "") }
    }

    private func importFile(_ url: URL) async {
        importing = true
        defer { importing = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let entries = try await SubscriptionTransfer.parse(data)
            let added = SubscriptionTransfer.importEntries(entries, into: context)
            importMessage = "\(added) abonnement(s) importé(s) sur \(entries.count)."
        } catch {
            importMessage = "Échec de l'import : \(error.localizedDescription)"
        }
    }
}
