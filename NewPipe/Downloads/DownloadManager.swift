import AVFoundation
import UIKit
import NewPipeExtractor

/// Téléchargements vidéo (H.264 + AAC fusionnés en .mp4) ou audio (.m4a).
/// Les fichiers sont dans Documents/Téléchargements, visibles dans l'app Fichiers.
@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    enum Kind: String, Codable { case video, audio }
    enum State: Equatable, Codable {
        case queued, downloading, merging, finished, failed(String), cancelled
    }

    struct Record: Identifiable, Codable, Equatable {
        var id = UUID()
        var stream: StreamItem
        var kind: Kind
        var quality: String
        var fileName: String
        var state: State = .queued
        var progress: Double = 0
        var totalBytes: Int64 = 0
        var createdAt = Date()
    }

    @Published private(set) var records: [Record] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let chunkSize: Int64 = 10 * 1024 * 1024

    let directory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Téléchargements", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var indexURL: URL { directory.appendingPathComponent(".index.json") }

    private init() {
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Record].self, from: data) {
            // Les téléchargements interrompus par la fermeture de l'app sont marqués en échec.
            records = saved.map { r in
                var r = r
                if r.state != .finished, r.state != .cancelled { r.state = .failed("Interrompu") }
                return r
            }
        }
    }

    func fileURL(_ r: Record) -> URL { directory.appendingPathComponent(r.fileName) }

    func localFile(for videoId: String, preferAudio: Bool) -> URL? {
        let done = records.filter { $0.stream.id == videoId && $0.state == .finished }
            .filter { FileManager.default.fileExists(atPath: fileURL($0).path) }
        let pick = done.first { $0.kind == (preferAudio ? .audio : .video) } ?? done.first
        return pick.map(fileURL)
    }

    // MARK: Démarrage

    func download(_ info: StreamInfo, kind: Kind, video: MediaFormat? = nil) {
        guard let audio = info.bestAudio else { return }
        let base = sanitize(info.title)
        let quality = kind == .audio ? "\(audio.bitrate / 1000) kb/s" : (video?.qualityLabel ?? "")
        var record = Record(stream: info.item, kind: kind, quality: quality,
                            fileName: uniqueName(base + (kind == .audio ? ".m4a" : " (\(quality)).mp4")))
        record.totalBytes = (audio.contentLength ?? 0) + (kind == .video ? (video?.contentLength ?? 0) : 0)
        records.insert(record, at: 0)
        save()
        start(record.id, audio: audio, video: kind == .video ? video : nil, hls: info.hlsURL)
    }

    private func start(_ id: UUID, audio: MediaFormat, video: MediaFormat?, hls: URL?) {
        tasks[id] = Task {
            let bg = UIApplication.shared.beginBackgroundTask(withName: "download") {}
            defer { UIApplication.shared.endBackgroundTask(bg) }
            update(id) { $0.state = .downloading }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                guard let record = records.first(where: { $0.id == id }) else { return }
                let destination = fileURL(record)
                var done: Int64 = 0
                let total = max(record.totalBytes, 1)
                let progress: (Int64) -> Void = { bytes in
                    done += bytes
                    let p = Double(done) / Double(total)
                    self.update(id) { $0.progress = min(p, 1) }
                }
                if let hls {
                    // Les URL directes sont coupées après ~1 min sans PO token : on passe par le HLS.
                    try await HLSDownloader.download(
                        master: hls, maxHeight: video.map { $0.height ?? 720 }, to: destination, workDir: tmp,
                        progress: { p in
                            Task { @MainActor in self.update(id) { if $0.state == .downloading { $0.progress = min(p, 1) } } }
                        },
                        merging: {
                            Task { @MainActor in self.update(id) { if $0.state == .downloading { $0.state = .merging } } }
                        })
                } else if let video {
                    let videoFile = tmp.appendingPathComponent("video.mp4")
                    let audioFile = tmp.appendingPathComponent("audio.m4a")
                    try await fetch(video, to: videoFile, progress: progress)
                    try await fetch(audio, to: audioFile, progress: progress)
                    update(id) { $0.state = .merging }
                    try await Self.merge(video: videoFile, audio: audioFile, to: destination)
                } else {
                    let audioFile = tmp.appendingPathComponent("audio.m4a")
                    try await fetch(audio, to: audioFile, progress: progress)
                    try FileManager.default.moveItem(at: audioFile, to: destination)
                }
                update(id) { $0.state = .finished; $0.progress = 1 }
            } catch is CancellationError {
                update(id) { $0.state = .cancelled }
            } catch {
                update(id) { $0.state = Task.isCancelled ? .cancelled : .failed(error.localizedDescription) }
            }
            tasks[id] = nil
            save()
        }
    }

    /// Téléchargement par tranches de 10 Mo avec en-tête Range (évite le bridage de googlevideo).
    private func fetch(_ format: MediaFormat, to file: URL, progress: @escaping (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        let length = format.contentLength
        while true {
            try Task.checkCancellation()
            var end = offset + chunkSize - 1
            if let length { end = min(end, length - 1) }
            var request = URLRequest(url: format.url)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            if let ua = format.userAgent { request.setValue(ua, forHTTPHeaderField: "User-Agent") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 || status == 206 else { throw ExtractionError.http(status) }
            try handle.write(contentsOf: data)
            let requested = end - offset + 1
            offset += Int64(data.count)
            progress(Int64(data.count))
            // Fin du fichier : réponse complète (200), tranche incomplète, ou taille connue atteinte.
            if status == 200 || Int64(data.count) < requested { break }
            if let length, offset >= length { break }
        }
    }

    /// Fusionne la piste vidéo et la piste audio sans réencodage.
    /// `audioOffset` > 0 : l'audio commence après la vidéo ; < 0 : son début est coupé.
    nonisolated static func merge(video: URL, audio: URL, to output: URL, audioOffset: CMTime = .zero) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        // Durée précise : pour un .aac (ADTS), la durée par défaut n'est qu'une estimation.
        let audioAsset = AVURLAsset(url: audio, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let aTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw ExtractionError.parsing("pistes")
        }
        let duration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let cv = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let ca = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        try cv?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: vTrack, at: .zero)
        let audioStart = audioOffset < .zero ? CMTimeAbsoluteValue(audioOffset) : .zero
        let audioAt = audioOffset > .zero ? audioOffset : .zero
        let audioLength = min(audioDuration - audioStart, duration - audioAt)
        if audioLength > .zero {
            try ca?.insertTimeRange(CMTimeRange(start: audioStart, duration: audioLength), of: aTrack, at: audioAt)
        }
        cv?.preferredTransform = try await vTrack.load(.preferredTransform)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExtractionError.parsing("export")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        if let error = export.error { throw error }
        guard export.status == .completed else { throw ExtractionError.parsing("fusion") }
    }

    // MARK: Gestion

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    func retry(_ record: Record) {
        delete(record)
        Task {
            guard let info = try? await Services.youtube.streamInfo(id: record.stream.id) else { return }
            let height = Int(record.quality.filter(\.isNumber)) ?? 0
            let video = info.downloadableVideoFormats.first { ($0.height ?? 0) <= height } ?? info.downloadableVideoFormats.last
            download(info, kind: record.kind, video: video)
        }
    }

    func delete(_ record: Record) {
        tasks[record.id]?.cancel()
        try? FileManager.default.removeItem(at: fileURL(record))
        records.removeAll { $0.id == record.id }
        save()
    }

    private func update(_ id: UUID, _ change: (inout Record) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: indexURL) }
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return String(name.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }).prefix(120).trimmingCharacters(in: .whitespaces)
    }

    private func uniqueName(_ name: String) -> String {
        var candidate = name
        var n = 2
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                || records.contains(where: { $0.fileName == candidate }) {
            candidate = "\(stem) \(n).\(ext)"
            n += 1
        }
        return candidate
    }
}
