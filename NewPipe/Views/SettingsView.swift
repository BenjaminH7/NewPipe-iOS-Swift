import SwiftUI
import SwiftData
import Charts

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(SettingsKey.maxResolution) private var maxResolution = 0
    @AppStorage(SettingsKey.backgroundPlayback) private var backgroundPlayback = true
    @AppStorage(SettingsKey.autoPiP) private var autoPiP = true
    @AppStorage(SettingsKey.resumePlayback) private var resumePlayback = true
    @AppStorage(SettingsKey.historyEnabled) private var historyEnabled = true
    @AppStorage(SettingsKey.searchHistoryEnabled) private var searchHistoryEnabled = true
    @AppStorage(SettingsKey.downloadResolution) private var downloadResolution = 720
    @AppStorage(SettingsKey.contentLanguage) private var language = "fr"
    @AppStorage(SettingsKey.contentCountry) private var country = "FR"
    @AppStorage(SettingsKey.videoLayout) private var layout = VideoLayout.cards.rawValue
    @AppStorage(SettingsKey.focusMode) private var focusMode = false
    @State private var confirmClearSearch = false

    private let resolutions = [0, 2160, 1440, 1080, 720, 480, 360, 240, 144]

    var body: some View {
        Form {
            Section {
                NavigationLink { ConcentrationView().miniPlayerInset() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "leaf.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Theme.focus.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Concentration").font(.headline)
                            Text(focusMode ? "Mode concentration activé" : "Shorts, commentaires, suggestions, rappels de pause…")
                                .font(.caption).foregroundStyle(focusMode ? Theme.focus : .secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Apparence") {
                Picker(selection: $layout) {
                    ForEach(VideoLayout.allCases) { Text($0.label).tag($0.rawValue) }
                } label: { SettingsLabel(title: "Affichage", icon: "rectangle.grid.1x2.fill", color: .indigo) }
            }

            Section("Lecture") {
                Picker(selection: $maxResolution) {
                    ForEach(resolutions, id: \.self) { Text($0 == 0 ? "Automatique" : "\($0)p").tag($0) }
                } label: { SettingsLabel(title: "Résolution maximale", icon: "sparkles.tv.fill", color: .blue) }
                Toggle(isOn: $backgroundPlayback) { SettingsLabel(title: "Lecture en arrière-plan", icon: "headphones", color: .pink) }
                Toggle(isOn: $autoPiP) { SettingsLabel(title: "Picture-in-Picture automatique", icon: "pip.fill", color: .cyan) }
                Toggle(isOn: $resumePlayback) { SettingsLabel(title: "Reprendre là où je me suis arrêté", icon: "playpause.fill", color: .orange) }
            }

            Section("Téléchargements") {
                Picker(selection: $downloadResolution) {
                    ForEach(resolutions.dropFirst(), id: \.self) { Text("\($0)p").tag($0) }
                } label: { SettingsLabel(title: "Qualité par défaut", icon: "arrow.down.circle.fill", color: .green) }
            }

            Section("Contenu") {
                Picker(selection: $language) {
                    ForEach(["fr", "en", "de", "es", "it", "pt", "nl", "ja", "ar"], id: \.self) {
                        Text(Locale.current.localizedString(forLanguageCode: $0)?.capitalized ?? $0).tag($0)
                    }
                } label: { SettingsLabel(title: "Langue du contenu", icon: "character.bubble.fill", color: .purple) }
                Picker(selection: $country) {
                    ForEach(["FR", "BE", "CH", "CA", "US", "GB", "DE", "ES", "IT", "JP"], id: \.self) {
                        Text(Locale.current.localizedString(forRegionCode: $0) ?? $0).tag($0)
                    }
                } label: { SettingsLabel(title: "Pays du contenu", icon: "globe.europe.africa.fill", color: .teal) }
            }
            .onChange(of: language) { Services.applyContentSettings() }
            .onChange(of: country) { Services.applyContentSettings() }

            Section {
                Toggle(isOn: $historyEnabled) { SettingsLabel(title: "Historique de visionnage", icon: "clock.fill", color: .gray) }
                Toggle(isOn: $searchHistoryEnabled) { SettingsLabel(title: "Historique de recherche", icon: "magnifyingglass", color: .gray) }
                Button(role: .destructive) { confirmClearSearch = true } label: {
                    SettingsLabel(title: "Effacer l'historique de recherche", icon: "trash.fill", color: .red)
                }
                Button { URLCache.shared.removeAllCachedResponses() } label: {
                    SettingsLabel(title: "Vider le cache des miniatures", icon: "photo.stack.fill", color: .brown)
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Confidentialité et stockage")
            } footer: {
                Text("Tout reste sur cet appareil : aucun compte, aucune publicité, aucun traqueur.")
            }

            Section("À propos") {
                LabeledContent {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                } label: {
                    SettingsLabel(title: "Version", icon: "info.circle.fill", color: .gray)
                }
                Link(destination: URL(string: "https://github.com/TeamNewPipe/NewPipe")!) {
                    SettingsLabel(title: "NewPipe (Android) sur GitHub", icon: "chevron.left.forwardslash.chevron.right", color: .black)
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle("Réglages")
        .confirmationDialog("Effacer l'historique de recherche ?", isPresented: $confirmClearSearch, titleVisibility: .visible) {
            Button("Effacer", role: .destructive) { try? context.delete(model: SearchHistoryEntry.self) }
        }
    }
}

/// Réglages anti-distraction et temps de visionnage.
struct ConcentrationView: View {
    @AppStorage(SettingsKey.focusMode) private var focusMode = false
    @AppStorage(SettingsKey.hideShorts) private var hideShorts = true
    @AppStorage(SettingsKey.commentsMode) private var commentsMode = RevealMode.onDemand.rawValue
    @AppStorage(SettingsKey.suggestionsMode) private var suggestionsMode = RevealMode.visible.rawValue
    @AppStorage(SettingsKey.hideCounts) private var hideCounts = false
    @AppStorage(SettingsKey.thumbnailMode) private var thumbnailMode = ThumbnailMode.normal.rawValue
    @AppStorage(SettingsKey.calmTitles) private var calmTitles = false
    @AppStorage(SettingsKey.searchSuggestions) private var searchSuggestions = true
    @AppStorage(SettingsKey.autoplayNext) private var autoplayNext = true
    @AppStorage(SettingsKey.breakReminder) private var breakReminder = 0
    @AppStorage(SettingsKey.feedHideWatched) private var hideWatched = false
    @AppStorage(SettingsKey.feedSinceSubscription) private var sinceSubscription = true

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Image(systemName: focusMode ? "leaf.fill" : "leaf")
                            .font(.title)
                            .foregroundStyle(focusMode ? .white : Theme.focus)
                            .frame(width: 56, height: 56)
                            .background(focusMode ? AnyShapeStyle(Theme.focus.gradient) : AnyShapeStyle(Theme.focus.opacity(0.15)),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .contentTransition(.symbolEffect(.replace))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mode concentration").font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                            Text(focusMode ? "Activé" : "Désactivé").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Mode concentration", isOn: Binding(get: { focusMode }, set: { on in
                            withAnimation(.snappy) { FocusMode.setEnabled(on) }
                        }))
                        .labelsHidden()
                        .tint(Theme.focus)
                    }
                    Text("Masque d'un coup les Shorts, commentaires, suggestions, compteurs et miniatures accrocheuses, coupe la lecture automatique et active un rappel de pause toutes les 30 minutes. Vos réglages précédents sont restaurés quand vous le désactivez.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .sensoryFeedback(.success, trigger: focusMode)
            }

            Section("Temps de visionnage") {
                WatchTimeChart()
            }

            Section {
                Toggle(isOn: $hideShorts) { SettingsLabel(title: "Masquer les Shorts", icon: "bolt.slash.fill", color: .red) }
                Picker(selection: $commentsMode) {
                    ForEach(RevealMode.allCases) { Text($0.label).tag($0.rawValue) }
                } label: { SettingsLabel(title: "Commentaires", icon: "text.bubble.fill", color: .blue) }
                Picker(selection: $suggestionsMode) {
                    ForEach(RevealMode.allCases) { Text($0.label).tag($0.rawValue) }
                } label: { SettingsLabel(title: "Suggestions sous les vidéos", icon: "rectangle.stack.fill", color: .purple) }
                Toggle(isOn: $sinceSubscription) { SettingsLabel(title: "Seulement depuis l'abonnement", icon: "calendar.badge.clock", color: .cyan, subtitle: "Nouveautés n'affiche que les vidéos publiées après l'abonnement") }
                Toggle(isOn: $hideWatched) { SettingsLabel(title: "Masquer les vidéos vues", icon: "eye.slash.fill", color: .gray, subtitle: "Dans Nouveautés") }
            } header: {
                Text("Contenus")
            } footer: {
                Text("« Sur demande » : un bouton permet de les afficher quand vous le décidez.")
            }

            Section {
                Toggle(isOn: $hideCounts) { SettingsLabel(title: "Masquer les compteurs", icon: "number", color: .orange, subtitle: "Vues, « J'aime », abonnés") }
                Picker(selection: $thumbnailMode) {
                    ForEach(ThumbnailMode.allCases) { Text($0.label).tag($0.rawValue) }
                } label: { SettingsLabel(title: "Miniatures", icon: "photo.fill", color: .pink) }
                Toggle(isOn: $calmTitles) { SettingsLabel(title: "Titres apaisés", icon: "textformat", color: .teal, subtitle: "Sans MAJUSCULES, « !!! » ni hashtags") }
                Toggle(isOn: $searchSuggestions) { SettingsLabel(title: "Suggestions de recherche", icon: "text.magnifyingglass", color: .indigo) }
            } header: {
                Text("Moins de sollicitations")
            }

            Section {
                Toggle(isOn: $autoplayNext) { SettingsLabel(title: "Lecture automatique de la suivante", icon: "forward.end.fill", color: .green) }
                Picker(selection: $breakReminder) {
                    Text("Désactivé").tag(0)
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("Après \($0) min").tag($0) }
                } label: { SettingsLabel(title: "Rappel de pause", icon: "timer", color: .brown) }
            } header: {
                Text("Habitudes")
            } footer: {
                Text("Le rappel met la lecture en pause et vous demande si vous voulez continuer.")
            }
        }
        .navigationTitle("Concentration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Histogramme des 7 derniers jours.
private struct WatchTimeChart: View {
    @State private var days: [(day: Date, seconds: Double)] = []

    var body: some View {
        let today = days.last?.seconds ?? 0
        let average = days.isEmpty ? 0 : days.map(\.seconds).reduce(0, +) / Double(days.count)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Aujourd'hui").font(.caption).foregroundStyle(.secondary)
                    Text(Self.format(today)).font(.title2.bold().monospacedDigit())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Moyenne / jour").font(.caption).foregroundStyle(.secondary)
                    Text(Self.format(average)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Chart(days, id: \.day) { entry in
                BarMark(x: .value("Jour", entry.day, unit: .day), y: .value("Minutes", entry.seconds / 60))
                    .foregroundStyle(Calendar.current.isDateInToday(entry.day) ? AnyShapeStyle(Theme.focus.gradient) : AnyShapeStyle(Theme.focus.opacity(0.35)))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine()
                    AxisValueLabel { if let m = value.as(Double.self) { Text("\(Int(m)) min") } }
                }
            }
            .chartYScale(domain: 0...max(30, (days.map(\.seconds).max() ?? 0) / 60 * 1.15))
            .frame(height: 140)
        }
        .padding(.vertical, 6)
        .onAppear {
            days = WatchTime.lastWeek(from: UserDefaults.standard.dictionary(forKey: SettingsKey.watchTime) as? [String: Double] ?? [:])
        }
    }

    private static func format(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60))" : "\(minutes) min"
    }
}
