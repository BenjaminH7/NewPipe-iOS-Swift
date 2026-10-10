import SwiftUI
import SwiftData
import NewPipeExtractor

/// Verrouille l'app en portrait sur iPhone ; seul le lecteur plein écran passe à l'horizontale.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : Self.orientationMask
    }
}

@main
struct NewPipeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    let container: ModelContainer
    @StateObject private var player = PlayerManager.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var feed = FeedModel()
    @StateObject private var router = Router()

    init() {
        UserDefaults.registerAppDefaults()
        PlayerManager.configureAudioSession()
        URLCache.shared = URLCache(memoryCapacity: 50 << 20, diskCapacity: 300 << 20)
        do {
            container = try ModelContainer(for: Subscription.self, HistoryEntry.self, LocalPlaylist.self,
                                           BookmarkedPlaylist.self, SearchHistoryEntry.self)
        } catch {
            fatalError("Impossible d'ouvrir la base de données : \(error)")
        }
        PlayerManager.shared.modelContext = container.mainContext
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(feed)
                .environmentObject(router)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @EnvironmentObject private var player: PlayerManager
    @EnvironmentObject private var router: Router

    var body: some View {
        TabView(selection: $router.tab) {
            tab(.feed, "Nouveautés", "play.square.stack.fill") { FeedView() }
            tab(.search, "Recherche", "magnifyingglass") { SearchView() }
            tab(.subscriptions, "Abonnements", "person.2.fill") { SubscriptionsView() }
            tab(.library, "Bibliothèque", "books.vertical.fill") { LibraryView() }
            tab(.settings, "Réglages", "gearshape.fill") { SettingsView() }
        }
        .breakReminder(active: !player.showFullPlayer && !player.isFullscreen)
        // Tourner le téléphone à l'horizontale avec le lecteur ouvert passe en plein écran, comme l'app YouTube.
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            if UIDevice.current.userInterfaceIdiom == .phone, UIDevice.current.orientation.isLandscape, player.showFullPlayer {
                player.enterFullscreen()
            }
        }
        .sheet(isPresented: $player.showFullPlayer) {
            PlayerView()
                .presentationDragIndicator(.visible)
        }
        .onOpenURL(perform: handle)
    }

    private func tab<Content: View>(_ tab: AppTab, _ title: String, _ icon: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: router.binding(for: tab)) {
            content()
                .withRoutes()
                .miniPlayerInset()
        }
        .tabItem { Label(title, systemImage: icon) }
        .tag(tab)
    }

    /// Ouvre newpipe://… ou un lien YouTube passé par newpipe://open?url=…
    private func handle(_ url: URL) {
        var target = url.absoluteString
        if url.scheme == "newpipe" {
            target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value
                ?? target.replacingOccurrences(of: "newpipe://", with: "https://")
        }
        Task {
            switch try? await Services.youtube.resolve(target) {
            case .stream(let id): player.play(StreamItem(id: id, title: ""))
            case .channel(let id): router.open(.channel(id: id, name: ""))
            case .playlist(let id): router.open(.playlist(id: id, title: ""))
            case nil: break
            }
        }
    }
}
