import AVFoundation
import CoreMedia
import Foundation
import NewPipeExtractor

/// Téléchargement depuis le flux HLS de YouTube, le seul lisible en entier sans PO token.
///
/// Le manifeste fournit la vidéo H.264 en segments MPEG-TS et l'audio AAC à part, en
/// « packed audio » (balise ID3 + trames ADTS). AVFoundation ne lit pas le MPEG-TS : la vidéo
/// est donc extraite des segments et réécrite telle quelle dans un .mp4, tandis que l'audio
/// ADTS est concaténé dans un .aac, que `DownloadManager.merge` sait déjà fusionner.
enum HLSDownloader {
    /// Télécharge l'audio et, si `maxHeight` est fourni, la vidéo H.264 de hauteur ≤ `maxHeight`.
    /// Produit `destination` (.mp4 si vidéo, .m4a sinon). `workDir` reçoit les fichiers intermédiaires.
    static func download(master url: URL, maxHeight: Int?, to destination: URL, workDir: URL,
                         progress: @escaping @Sendable (Double) -> Void,
                         merging: @escaping @Sendable () -> Void) async throws {
        let master = try await Master.load(url)
        guard let best = master.avcVariant(maxHeight: .max),
              let audioURL = master.audio[best.audioGroup ?? ""] ?? master.audio.values.first else {
            throw ExtractionError.parsing("manifeste HLS sans piste H.264/AAC")
        }
        let video = maxHeight.flatMap { master.avcVariant(maxHeight: $0) }
        let audioSegments = try await segments(of: audioURL)
        var videoSegments: [URL] = []
        if let video { videoSegments = try await segments(of: video.url) }
        let total = Double(audioSegments.count + videoSegments.count)
        var done = 0.0

        let audioFile = workDir.appendingPathComponent("audio.aac")
        let audio = try PackedAudioWriter(output: audioFile)
        try await forEachSegment(audioSegments) { data in
            try audio.append(data)
            done += 1
            progress(done / total)
        }
        try audio.close()

        guard video != nil else {
            merging()
            try await exportAudio(audioFile, to: destination)
            return
        }
        let videoFile = workDir.appendingPathComponent("video.mp4")
        let remuxer = TSVideoRemuxer(output: videoFile)
        try await forEachSegment(videoSegments) { data in
            try await remuxer.append(data)
            done += 1
            progress(done / total)
        }
        try await remuxer.finish()

        merging()
        // Décalage de l'audio par rapport au début de la vidéo, sur l'horloge MPEG commune (90 kHz).
        var offset = CMTime.zero
        if let audioStart = audio.firstTimestamp, let videoStart = remuxer.firstTimestamp {
            offset = CMTime(value: audioStart - videoStart, timescale: 90_000)
            if abs(offset.seconds) > 5 { offset = .zero } // horloges incohérentes : on ignore
        }
        try await DownloadManager.merge(video: videoFile, audio: audioFile, to: destination, audioOffset: offset)
    }

    // MARK: Manifestes

    struct Variant {
        var url: URL
        var height: Int
        var bandwidth: Int
        var codecs: String
        var audioGroup: String?
    }

    struct Master {
        var variants: [Variant] = []
        var audio: [String: URL] = [:]

        static func load(_ url: URL) async throws -> Master {
            var master = Master()
            var pending: [String: String]?
            for line in try await HLSDownloader.lines(of: url) {
                if line.hasPrefix("#EXT-X-MEDIA:") {
                    let a = attributes(line)
                    if a["TYPE"] == "AUDIO", let group = a["GROUP-ID"], let uri = a["URI"], let u = URL(string: uri, relativeTo: url) {
                        // Vidéos doublées : on garde la piste d'origine (« … - original », identifiant en « .4 »).
                        let isOriginal = a["NAME"]?.localizedCaseInsensitiveContains("original") == true
                            || a["YT-EXT-AUDIO-CONTENT-ID"]?.hasSuffix(".4") == true
                        if master.audio[group] == nil || isOriginal { master.audio[group] = u.absoluteURL }
                    }
                } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    pending = attributes(line)
                } else if !line.hasPrefix("#"), let a = pending, let u = URL(string: line, relativeTo: url) {
                    master.variants.append(Variant(
                        url: u.absoluteURL,
                        height: a["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) } ?? 0,
                        bandwidth: a["BANDWIDTH"].flatMap { Int($0) } ?? 0,
                        codecs: a["CODECS"] ?? "",
                        audioGroup: a["AUDIO"]))
                    pending = nil
                }
            }
            return master
        }

        /// Meilleure variante H.264 ne dépassant pas `maxHeight` (sinon la plus petite).
        func avcVariant(maxHeight: Int) -> Variant? {
            let avc = variants.filter { $0.codecs.hasPrefix("avc1") }
            return avc.filter { $0.height <= maxHeight }.max { ($0.height, $0.bandwidth) < ($1.height, $1.bandwidth) }
                ?? avc.min { $0.height < $1.height }
        }
    }

    /// Attributs `CLE=valeur` ou `CLE="valeur, avec virgules"` d'une ligne de manifeste.
    static func attributes(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in line.matches(of: #/([A-Z0-9-]+)=("[^"]*"|[^,]*)/#) {
            result[String(match.1)] = String(match.2).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return result
    }

    static func segments(of url: URL) async throws -> [URL] {
        let lines = try await lines(of: url)
        if lines.contains(where: { $0.hasPrefix("#EXT-X-MAP") || ($0.hasPrefix("#EXT-X-KEY") && !$0.contains("METHOD=NONE")) }) {
            throw ExtractionError.parsing("format HLS non pris en charge (fMP4 ou chiffré)")
        }
        let urls = lines.filter { !$0.hasPrefix("#") }.compactMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        guard !urls.isEmpty else { throw ExtractionError.parsing("playlist HLS vide") }
        return urls
    }

    private static func lines(of url: URL) async throws -> [String] {
        String(decoding: try await fetch(url), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Réseau

    /// Parcourt les segments dans l'ordre en en préchargeant `window` à l'avance.
    private static func forEachSegment(_ urls: [URL], window: Int = 4, _ body: (Data) async throws -> Void) async throws {
        var tasks: [Int: Task<Data, Error>] = [:]
        defer { tasks.values.forEach { $0.cancel() } }
        func launch(_ i: Int) { tasks[i] = Task { try await fetch(urls[i]) } }
        for i in 0..<min(window, urls.count) { launch(i) }
        for i in urls.indices {
            try Task.checkCancellation()
            let data = try await tasks[i]!.value
            tasks[i] = nil
            if i + window < urls.count { launch(i + window) }
            try await body(data)
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw ExtractionError.http(status) }
                return data
            } catch where attempt < 2 && !(error is CancellationError) && !Task.isCancelled {
                attempt += 1
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    // MARK: Audio seul

    private static func exportAudio(_ file: URL, to output: URL) async throws {
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: file), presetName: AVAssetExportPresetPassthrough) else {
            throw ExtractionError.parsing("export")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        if let error = export.error { throw error }
        guard export.status == .completed else { throw ExtractionError.parsing("export audio") }
    }
}

// MARK: - Audio « packed audio » → .aac

/// Concatène les segments audio HLS (balise ID3 + trames ADTS) en un fichier ADTS
/// lisible par AVFoundation, en retenant l'horodatage MPEG du premier segment.
final class PackedAudioWriter {
    private let handle: FileHandle
    private(set) var firstTimestamp: Int64?
    private static let timestampOwner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]

    init(output: URL) throws {
        FileManager.default.createFile(atPath: output.path, contents: nil)
        handle = try FileHandle(forWritingTo: output)
    }

    func append(_ segment: Data) throws {
        let bytes = [UInt8](segment)
        var start = 0
        while start + 10 <= bytes.count, bytes[start] == 0x49, bytes[start + 1] == 0x44, bytes[start + 2] == 0x33 { // « ID3 »
            let size = Int(bytes[start + 6]) << 21 | Int(bytes[start + 7]) << 14 | Int(bytes[start + 8]) << 7 | Int(bytes[start + 9])
            let end = min(bytes.count, start + 10 + size + (bytes[start + 5] & 0x10 != 0 ? 10 : 0))
            if firstTimestamp == nil { firstTimestamp = Self.timestamp(in: bytes[start..<end]) }
            start = end
        }
        try handle.write(contentsOf: bytes[start...])
    }

    func close() throws { try handle.close() }

    /// Trame PRIV « com.apple.streaming.transportStreamTimestamp » : PTS 33 bits sur 8 octets.
    private static func timestamp(in tag: ArraySlice<UInt8>) -> Int64? {
        let owner = timestampOwner
        guard tag.count > owner.count + 8 else { return nil }
        var i = tag.startIndex
        while i + owner.count + 8 <= tag.endIndex {
            if tag[i..<i + owner.count].elementsEqual(owner) {
                return tag[(i + owner.count)..<(i + owner.count + 8)].reduce(Int64(0)) { $0 << 8 | Int64($1) } & 0x1_FFFF_FFFF
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Vidéo MPEG-TS → .mp4

/// Extrait la vidéo H.264 de segments MPEG-TS et l'écrit dans un .mp4, sans réencodage.
final class TSVideoRemuxer {
    private struct Sample {
        var data: [UInt8]
        var pts: Int64
        var dts: Int64
        var isKey: Bool
    }

    private let output: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var format: CMVideoFormatDescription?
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var videoPID: Int?
    private var pes: [UInt8] = []
    private var pesPTS: Int64?
    private var pesDTS: Int64?
    private var pending: Sample?
    private var lastDuration: Int64 = 3750 // 1/24 s à 90 kHz
    private var leftover: [UInt8] = []
    private var lastDTS: Int64?
    private var wrap: Int64 = 0
    /// DTS (90 kHz) de la première image écrite : origine de la timeline du fichier.
    private(set) var firstTimestamp: Int64?

    init(output: URL) {
        self.output = output
    }

    func append(_ segment: Data) async throws {
        let bytes = leftover + [UInt8](segment)
        var offset = 0
        while offset + 188 <= bytes.count {
            guard bytes[offset] == 0x47 else { offset += 1; continue } // resynchronisation
            try await packet(bytes, at: offset)
            offset += 188
        }
        leftover = Array(bytes[offset...])
    }

    func finish() async throws {
        try await flushPES()
        if let pending { try await write(pending, duration: lastDuration) }
        pending = nil
        guard let writer, let input else { throw ExtractionError.parsing("aucune image vidéo") }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? ExtractionError.parsing("écriture vidéo") }
    }

    // MARK: Paquets TS et PES

    private func packet(_ p: [UInt8], at o: Int) async throws {
        let unitStart = p[o + 1] & 0x40 != 0
        let pid = Int(p[o + 1] & 0x1F) << 8 | Int(p[o + 2])
        let adaptation = (p[o + 3] >> 4) & 0x3
        var start = o + 4
        if adaptation == 2 || adaptation == 3 { start += 1 + Int(p[o + 4]) }
        let end = o + 188
        guard adaptation & 0x1 != 0, start < end else { return }

        if unitStart {
            // En-tête PES : 00 00 01, stream_id (0xE0–0xEF = vidéo), longueur, drapeaux, PTS/DTS.
            guard end - start >= 9, p[start] == 0, p[start + 1] == 0, p[start + 2] == 1,
                  (0xE0...0xEF).contains(p[start + 3]) else { return }
            if videoPID == nil { videoPID = pid }
            guard pid == videoPID else { return }
            try await flushPES()
            let flags = p[start + 7]
            let body = start + 9 + Int(p[start + 8])
            pesPTS = flags & 0x80 != 0 ? Self.timestamp(p, start + 9) : nil
            pesDTS = flags & 0x40 != 0 ? Self.timestamp(p, start + 14) : pesPTS
            if body < end { pes.append(contentsOf: p[body..<end]) }
        } else if pid == videoPID, pesPTS != nil {
            pes.append(contentsOf: p[start..<end])
        }
    }

    private static func timestamp(_ p: [UInt8], _ i: Int) -> Int64 {
        Int64(p[i] & 0x0E) << 29 | Int64(p[i + 1]) << 22 | Int64(p[i + 2] & 0xFE) << 14 | Int64(p[i + 3]) << 7 | Int64(p[i + 4]) >> 1
    }

    /// Une unité PES vidéo complète = une image (access unit) en Annex B.
    private func flushPES() async throws {
        defer { pes = []; pesPTS = nil; pesDTS = nil }
        guard !pes.isEmpty, var pts = pesPTS, var dts = pesDTS else { return }

        // Déroulement du compteur 33 bits (vidéos de plus de ~26 h).
        if let last = lastDTS, dts + wrap < last - (1 << 32) { wrap += 1 << 33 }
        pts += wrap
        dts += wrap
        if pts < dts - (1 << 32) { pts += 1 << 33 }
        lastDTS = dts

        var avcc: [UInt8] = []
        var isKey = false
        for nal in Self.nalUnits(pes) {
            switch nal.first.map({ $0 & 0x1F }) {
            case 7: if sps == nil { sps = Array(nal) }
            case 8: if pps == nil { pps = Array(nal) }
            case 9, nil: break // délimiteur d'unité d'accès : inutile en MP4
            case let type:
                if type == 5 { isKey = true }
                let n = UInt32(nal.count)
                avcc += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
                avcc += nal
            }
        }
        guard !avcc.isEmpty else { return }
        if format == nil {
            // On attend la première image clé et les paramètres SPS/PPS.
            guard isKey, let sps, let pps else { return }
            format = try Self.formatDescription(sps: sps, pps: pps)
        }
        let sample = Sample(data: avcc, pts: pts, dts: dts, isKey: isKey)
        if let previous = pending {
            let duration = sample.dts - previous.dts
            if duration > 0 { lastDuration = duration }
            try await write(previous, duration: lastDuration)
        }
        pending = sample
    }

    /// Découpe un flux Annex B (codes de début 00 00 01 / 00 00 00 01) en unités NAL.
    private static func nalUnits(_ d: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var start: Int?
        var i = 0
        func close(_ end: Int) {
            guard let s = start else { return }
            var e = end
            while e > s, d[e - 1] == 0 { e -= 1 }
            if e > s { units.append(d[s..<e]) }
        }
        while i + 2 < d.count {
            if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
                close(i)
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        close(d.count)
        return units
    }

    private static func formatDescription(sps: [UInt8], pps: [UInt8]) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { throw ExtractionError.parsing("SPS/PPS H.264 (\(status))") }
        return description
    }

    // MARK: Écriture MP4

    private func write(_ sample: Sample, duration: Int64) async throws {
        guard let format else { return }
        if writer == nil {
            try? FileManager.default.removeItem(at: output)
            let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? ExtractionError.parsing("écriture vidéo") }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            firstTimestamp = sample.dts
        }
        guard let writer, let input, let origin = firstTimestamp else { return }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: sample.data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: sample.data.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw ExtractionError.parsing("tampon vidéo") }
        status = sample.data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: sample.data.count)
        }
        guard status == noErr else { throw ExtractionError.parsing("tampon vidéo") }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: duration, timescale: 90_000),
            presentationTimeStamp: CMTime(value: sample.pts - origin, timescale: 90_000),
            decodeTimeStamp: CMTime(value: sample.dts - origin, timescale: 90_000))
        var size = sample.data.count
        var buffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw ExtractionError.parsing("échantillon vidéo") }
        if !sample.isKey, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
        guard input.append(buffer) else { throw writer.error ?? ExtractionError.parsing("écriture vidéo") }
    }
}
