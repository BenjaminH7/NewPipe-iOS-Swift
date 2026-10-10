import SwiftUI

/// Système de design de l'app : couleurs, rayons, styles de boutons et éléments réutilisables.
enum Theme {
    static let corner: CGFloat = 14
    static let smallCorner: CGFloat = 10
    static let card = Color(.secondarySystemGroupedBackground)
    static let fill = Color(.tertiarySystemFill)
    static let focus = Color.teal
}

// MARK: Boutons

/// Bouton « pilule » : actions secondaires (enregistrer, télécharger…) ou principale (`prominent`).
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .labelStyle(PillLabelStyle())
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Theme.fill), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var prominentPill: PillButtonStyle { PillButtonStyle(prominent: true) }
}

/// Bouton d'abonnement commun (lecteur, chaîne).
struct SubscribeButton: View {
    let isSubscribed: Bool
    var expanded = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isSubscribed ? "Abonné" : "S'abonner", systemImage: isSubscribed ? "checkmark" : "plus")
                .frame(maxWidth: expanded ? .infinity : nil)
        }
        .buttonStyle(PillButtonStyle(prominent: !isSubscribed))
        .sensoryFeedback(.selection, trigger: isSubscribed)
        .animation(.snappy, value: isSubscribed)
    }
}

// MARK: Réglages

/// Pictogramme coloré façon app Réglages d'iOS.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

struct SettingsLabel: View {
    let title: String
    let icon: String
    let color: Color
    var subtitle: String? = nil

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
        } icon: {
            SettingsIcon(systemName: icon, color: color)
        }
    }
}

// MARK: Titres et cartes

struct SectionTitle: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

extension View {
    /// Carte arrondie sur fond secondaire.
    func cardStyle(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// Pastille de chaîne quand on n'a pas d'avatar : initiale sur une couleur stable.
struct Monogram: View {
    let name: String
    var size: CGFloat = 36

    private static let palette: [Color] = [.red, .orange, .pink, .purple, .indigo, .blue, .teal, .green, .brown]

    var body: some View {
        let initial = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ ")).first.map { String($0).uppercased() } ?? "?"
        let color = Self.palette[abs(name.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % Self.palette.count]
        Text(initial)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
    }
}

// MARK: Chargement

/// Effet de scintillement des squelettes de chargement.
private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                .mask(content)
                .allowsHitTesting(false)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

/// Squelettes de vidéos affichés pendant un chargement.
struct SkeletonList: View {
    var count = 4
    @AppStorage(SettingsKey.videoLayout) private var layout = VideoLayout.cards.rawValue

    var body: some View {
        ForEach(0..<count, id: \.self) { _ in
            Group {
                if layout == VideoLayout.cards.rawValue {
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).fill(Theme.fill)
                            .aspectRatio(16 / 9, contentMode: .fit)
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Theme.fill).frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().fill(Theme.fill).frame(height: 12)
                                Capsule().fill(Theme.fill).frame(width: 160, height: 10)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: Theme.smallCorner, style: .continuous).fill(Theme.fill)
                            .frame(width: 160, height: 90)
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule().fill(Theme.fill).frame(height: 12)
                            Capsule().fill(Theme.fill).frame(width: 100, height: 10)
                        }
                    }
                }
            }
            .modifier(Shimmer())
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
        }
    }
}
