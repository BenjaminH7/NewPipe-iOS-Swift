import Foundation

/// Profil de client InnerTube (l'API interne utilisée par les applications YouTube officielles).
/// Comme NewPipeExtractor, on imite différents clients selon l'opération :
/// - WEB pour la recherche, les chaînes, les playlists et la page vidéo ;
/// - VISIONOS pour le flux HLS (lisible par AVPlayer de bout en bout sans PO token, comme yt-dlp) ;
/// - IOS pour le flux HLS de secours (y compris les directs) ;
/// - ANDROID_VR pour les URL directes non chiffrées (lecture audio seule, téléchargements).
///   Sans PO token, googlevideo coupe ces URL directes après la première minute environ.
public struct InnerTubeProfile: Sendable {
    public var clientName: String
    public var clientVersion: String
    public var clientNameId: Int
    public var userAgent: String
    public var extra: [String: String]

    public static let web = InnerTubeProfile(
        clientName: "WEB", clientVersion: "2.20250925.01.00", clientNameId: 1,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36",
        extra: ["platform": "DESKTOP"])

    public static let ios = InnerTubeProfile(
        clientName: "IOS", clientVersion: "20.10.4", clientNameId: 5,
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"])

    // Valeurs reprises de yt-dlp (client « visionos »).
    public static let visionOS = InnerTubeProfile(
        clientName: "VISIONOS", clientVersion: "1.02", clientNameId: 101,
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        extra: ["deviceMake": "Apple", "deviceModel": "RealityDevice17,1", "osName": "visionOS", "osVersion": "26.5.23O471"])

    public static let androidVR = InnerTubeProfile(
        clientName: "ANDROID_VR", clientVersion: "1.65.10", clientNameId: 28,
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android", "osVersion": "12L", "androidSdkVersion": "32"])
}

public final class InnerTubeClient: @unchecked Sendable {
    public var language: String
    public var region: String
    private let session: URLSession
    private var visitorData: String?
    private let lock = NSLock()

    public init(language: String = Locale.current.language.languageCode?.identifier ?? "en",
                region: String = Locale.current.region?.identifier ?? "US",
                session: URLSession = .shared) {
        self.language = language
        self.region = region
        self.session = session
    }

    public func post(_ endpoint: String, body: [String: Any], profile: InnerTubeProfile = .web) async throws -> JSONNode {
        var client: [String: Any] = [
            "clientName": profile.clientName,
            "clientVersion": profile.clientVersion,
            "hl": language,
            "gl": region,
            "userAgent": profile.userAgent,
        ]
        for (k, v) in profile.extra { client[k] = Int(v) ?? v }
        if let visitor { client["visitorData"] = visitor }

        var payload = body
        payload["context"] = ["client": client, "user": ["lockedSafetyMode": false]]

        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(String(profile.clientNameId), forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(profile.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie") // évite la page de consentement UE
        if let visitor { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ExtractionError.http(status) }
        let json = try JSONNode(data: data)
        if visitor == nil, let v = json.path("responseContext.visitorData").string {
            // `visitor_id` le renvoie encodé pour une URL (« %3D%3D »).
            lock.withLock { visitorData = v.removingPercentEncoding ?? v }
        }
        return json
    }

    private var visitor: String? { lock.withLock { visitorData } }

    /// Obtient un visitorData avant les requêtes `player` : sans lui, YouTube répond
    /// « Connectez-vous pour confirmer que vous n'êtes pas un robot » à plusieurs clients.
    public func ensureVisitorData() async {
        guard visitor == nil else { return }
        _ = try? await post("visitor_id", body: [:])
    }

    public func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(InnerTubeProfile.web.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ExtractionError.http(status) }
        return data
    }
}
