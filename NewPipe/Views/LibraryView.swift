import SwiftUI
import SwiftData
import NewPipeExtractor

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LocalPlaylist.createdAt, order: .reverse) private var playlists: [LocalPlaylist]
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]
    @EnvironmentObject private var downloads: DownloadManager
    @State private var newPlaylistName = ""
    @State private var showNewPlaylist = false

    var body: some View {
        List {
            Section {
                let active = downloads.records.filter { $0.state == .downloading || $0.state == .merging }.count
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    LibraryTile(title: "Historique", icon: "clock.arrow.circlepath", color: .blue,
                                detail: history.isEmpty ? nil : "\(history.count)", route: .history)
                    LibraryTile(title: "Téléchargements", icon: "arrow.down.circle.fill", color: .green,
                                detail: active > 0 ? "\(active) en cours" : "\(downloads.records.filter { $0.state == .finished }.count)",
                                route: .downloads)
                    LibraryTile(title: "Playlists enregistrées", icon: "star.fill", color: .orange, detail: nil, route: .bookmarks)
                    Button { showNewPlaylist = true } label: {
                        TileLabel(title: "Nouvelle playlist", icon: "plus", color: .purple, detail: nil)
                    }
                    .buttonStyle(.plain)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }
            if !history.isEmpty {
                Section("Récemment regardées") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(history.prefix(15)) { entry in
                                RecentCard(entry: entry)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }
            Section("Mes playlists") {
                ForEach(playlists) { p in
                    NavigationLink(value: Route.localPlaylist(p.persistentModelID)) {
                        HStack(spacing: 12) {
                            Thumbnail(url: p.items.first?.thumbnailURL, alwaysVisible: true).frame(width: 96)
                            VStack(alignment: .leading) {
                                Text(p.name)
                                Text("\(p.items.count) vidéo(s)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in offsets.map { playlists[$0] }.forEach(context.delete) }
                if playlists.isEmpty {
                    Text("Créez une playlist pour regrouper des vidéos, ou ajoutez-en depuis le menu d'une vidéo (appui long).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Bibliothèque")
        .alert("Nouvelle playlist", isPresented: $showNewPlaylist) {
            TextField("Nom", text: $newPlaylistName)
            Button("Créer") {
                if !newPlaylistName.isEmpty { context.insert(LocalPlaylist(name: newPlaylistName)) }
                newPlaylistName = ""
            }
            Button("Annuler", role: .cancel) { newPlaylistName = "" }
        }
    }
}

/// Tuile de la bibliothèque (accès rapide).
private struct LibraryTile: View {
    let title: String
    let icon: String
    let color: Color
    let detail: String?
    let route: Route
    @EnvironmentObject private var router: Router

    var body: some View {
        // Bouton plutôt que NavigationLink : dans une List, ce dernier ajoute un chevron hors de la tuile.
        Button { router.open(route) } label: { TileLabel(title: title, icon: icon, color: color, detail: detail) }
            .buttonStyle(.plain)
    }
}

private struct TileLabel: View {
    let title: String
    let icon: String
    let color: Color
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SettingsIcon(systemName: icon, color: color)
                Spacer()
                if let detail { Text(detail).font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .cardStyle(padding: 12)
        .contentShape(Rectangle())
    }
}

private struct RecentCard: View {
    let entry: HistoryEntry
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        Button { player.play(entry.stream) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Thumbnail(url: entry.stream.thumbnailURL, duration: entry.stream.duration,
                          progress: entry.stream.duration.map { entry.position / Double(max($0, 1)) })
                Text(entry.stream.title).font(.caption.weight(.medium)).lineLimit(2)
                if let channel = entry.stream.channelName { Text(channel).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(width: 160)
        }
        .buttonStyle(.plain)
        .streamContextMenu(entry.stream)
    }
}

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]
    @State private var confirmClear = false

    var body: some View {
        List {
            ForEach(history) { entry in
                StreamCell(item: entry.stream, queue: history.map(\.stream),
                           progress: entry.stream.duration.map { entry.position / Double(max($0, 1)) })
            }
            .onDelete { offsets in offsets.map { history[$0] }.forEach(context.delete) }
        }
        .listStyle(.plain)
        .navigationTitle("Historique")
        .overlay { if history.isEmpty { ContentUnavailableView("Historique vide", systemImage: "clock") } }
        .toolbar {
            Button("Effacer", role: .destructive) { confirmClear = true }.disabled(history.isEmpty)
        }
        .confirmationDialog("Effacer tout l'historique ?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Effacer l'historique", role: .destructive) { try? context.delete(model: HistoryEntry.self) }
        }
    }
}

struct BookmarksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BookmarkedPlaylist.title) private var bookmarks: [BookmarkedPlaylist]

    var body: some View {
        List {
            ForEach(bookmarks) { b in
                NavigationLink(value: Route.playlist(id: b.playlistId, title: b.title)) {
                    PlaylistRow(item: PlaylistItem(id: b.playlistId, title: b.title, channelName: b.channelName, thumbnailURL: b.thumbnailURL))
                }
            }
            .onDelete { offsets in offsets.map { bookmarks[$0] }.forEach(context.delete) }
        }
        .listStyle(.plain)
        .navigationTitle("Playlists enregistrées")
        .overlay { if bookmarks.isEmpty { ContentUnavailableView("Aucune playlist enregistrée", systemImage: "star", description: Text("Touchez l'étoile sur une playlist YouTube.")) } }
    }
}

struct LocalPlaylistView: View {
    let playlistID: PersistentIdentifier
    @Environment(\.modelContext) private var context
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        if let playlist = context.model(for: playlistID) as? LocalPlaylist {
            List {
                PlayButtons(items: playlist.items).listRowSeparator(.hidden)
                ForEach(playlist.items) { StreamCell(item: $0, queue: playlist.items) }
                    .onDelete { playlist.items.remove(atOffsets: $0) }
                    .onMove { playlist.items.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .navigationTitle(playlist.name)
            .toolbar {
                EditButton()
                Button { name = playlist.name; renaming = true } label: { Image(systemName: "pencil") }
            }
            .alert("Renommer", isPresented: $renaming) {
                TextField("Nom", text: $name)
                Button("OK") { if !name.isEmpty { playlist.name = name } }
                Button("Annuler", role: .cancel) {}
            }
        }
    }
}

/// Feuille "Ajouter à une playlist".
struct PlaylistPickerSheet: View {
    let item: StreamItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LocalPlaylist.createdAt, order: .reverse) private var playlists: [LocalPlaylist]
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Nouvelle playlist", text: $newName)
                        Button("Créer") {
                            let p = LocalPlaylist(name: newName)
                            p.items = [item]
                            context.insert(p)
                            dismiss()
                        }
                        .disabled(newName.isEmpty)
                    }
                }
                Section {
                    ForEach(playlists) { p in
                        Button {
                            if !p.items.contains(where: { $0.id == item.id }) { p.items.append(item) }
                            dismiss()
                        } label: {
                            HStack {
                                Text(p.name)
                                Spacer()
                                if p.items.contains(where: { $0.id == item.id }) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Ajouter à une playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fermer") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
    }
}
