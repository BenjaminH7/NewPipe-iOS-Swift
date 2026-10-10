import SwiftUI
import NewPipeExtractor

struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @EnvironmentObject private var player: PlayerManager

    var body: some View {
        List {
            ForEach(downloads.records) { r in
                Button {
                    if r.state == .finished { player.play(r.stream, audioOnly: r.kind == .audio) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Thumbnail(url: r.stream.thumbnailURL, duration: r.stream.duration, alwaysVisible: true)
                            .frame(width: 120)
                            .overlay { if r.kind == .audio { Image(systemName: "music.note").font(.title).foregroundStyle(.white).shadow(radius: 4) } }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.stream.title).font(.subheadline).lineLimit(2)
                            Text("\(r.kind == .audio ? "Audio" : "Vidéo") • \(r.quality)" + (r.totalBytes > 0 ? " • \(Format.bytes(r.totalBytes))" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                            status(r)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button("Supprimer", role: .destructive) { downloads.delete(r) }
                    if r.state == .downloading { Button("Annuler") { downloads.cancel(r.id) } }
                }
                .contextMenu {
                    if r.state == .finished {
                        ShareLink(item: downloads.fileURL(r)) { Label("Partager le fichier", systemImage: "square.and.arrow.up") }
                    }
                    if case .failed = r.state { Button { downloads.retry(r) } label: { Label("Réessayer", systemImage: "arrow.clockwise") } }
                    Button(role: .destructive) { downloads.delete(r) } label: { Label("Supprimer", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Téléchargements")
        .overlay {
            if downloads.records.isEmpty {
                ContentUnavailableView("Aucun téléchargement", systemImage: "arrow.down.circle",
                                       description: Text("Les fichiers sont aussi accessibles dans l'app Fichiers › NewPipe."))
            }
        }
    }

    @ViewBuilder private func status(_ r: DownloadManager.Record) -> some View {
        switch r.state {
        case .queued: Text("En attente").font(.caption2)
        case .downloading: ProgressView(value: r.progress) { Text("\(Int(r.progress * 100)) %").font(.caption2) }
        case .merging: HStack { ProgressView().controlSize(.mini); Text("Fusion audio/vidéo…").font(.caption2) }
        case .finished:
            HStack(spacing: 4) { Image(systemName: "checkmark.circle.fill"); Text("Terminé") }
                .font(.caption.weight(.medium)).foregroundStyle(.green)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red).lineLimit(2)
        case .cancelled: Text("Annulé").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Feuille de choix du format, comme la boîte de dialogue de téléchargement de NewPipe.
struct DownloadSheet: View {
    let videoId: String
    var preloaded: StreamInfo? = nil

    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.downloadResolution) private var preferredResolution = 720
    @State private var info: StreamInfo?
    @State private var error: String?
    @State private var kind: DownloadManager.Kind = .video
    @State private var selected: Int?

    var body: some View {
        NavigationStack {
            Group {
                if let info {
                    Form {
                        Section { Text(info.title).font(.headline) }
                        Picker("Type", selection: $kind) {
                            Text("Vidéo").tag(DownloadManager.Kind.video)
                            Text("Audio").tag(DownloadManager.Kind.audio)
                        }
                        .pickerStyle(.segmented)
                        if kind == .video {
                            Section("Qualité (MP4 H.264 + AAC)") {
                                Picker("Qualité", selection: $selected) {
                                    ForEach(info.downloadableVideoFormats) { f in
                                        Text(label(f, audio: info.bestAudio)).tag(Optional(f.itag))
                                    }
                                }
                                .pickerStyle(.inline)
                                .labelsHidden()
                            }
                        } else if let a = info.bestAudio {
                            Section("Format") { Text("M4A (AAC) • \(a.bitrate / 1000) kb/s" + (a.contentLength.map { " • " + Format.bytes($0) } ?? "")) }
                        }
                    }
                } else if let error {
                    ContentUnavailableView("Téléchargement impossible", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Télécharger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Télécharger") {
                        guard let info else { return }
                        let video = info.downloadableVideoFormats.first { $0.itag == selected }
                        downloads.download(info, kind: kind, video: video)
                        dismiss()
                    }
                    .disabled(info?.bestAudio == nil || (kind == .video && selected == nil))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if info == nil {
                do {
                    if let preloaded { info = preloaded } else { info = try await Services.youtube.streamInfo(id: videoId) }
                }
                catch { self.error = error.localizedDescription }
                if info?.isLive == true { info = nil; error = "Les directs ne peuvent pas être téléchargés." }
            }
            let formats = info?.downloadableVideoFormats ?? []
            selected = (formats.first { ($0.height ?? 0) <= preferredResolution } ?? formats.last)?.itag
        }
    }

    private func label(_ f: MediaFormat, audio: MediaFormat?) -> String {
        let size = (f.contentLength ?? 0) + (audio?.contentLength ?? 0)
        return (f.qualityLabel ?? "\(f.height ?? 0)p") + (size > 0 ? "  •  " + Format.bytes(size) : "")
    }
}
