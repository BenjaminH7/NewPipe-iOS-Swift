import SwiftUI
import NewPipeExtractor

/// Commentaires d'une vidéo, en feuille : pagination infinie et réponses dépliables.
struct CommentsView: View {
    let token: String
    var countText: String?

    @Environment(\.dismiss) private var dismiss
    @State private var comments: [Comment] = []
    @State private var continuation: String?
    @State private var total: String?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    ErrorView(message: error) { Task { await load() } }
                } else if !loaded {
                    ForEach(0..<6, id: \.self) { _ in CommentSkeleton() }
                } else if comments.isEmpty {
                    ContentUnavailableView("Aucun commentaire", systemImage: "text.bubble")
                } else {
                    ForEach(comments) { CommentThreadRow(comment: $0) }
                    if continuation != nil { LoadMoreRow { await loadMore() } }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Commentaires")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Commentaires").font(.headline)
                        if let t = total ?? countText { Text(t).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fermer")
                }
            }
            .task { if !loaded { await load() } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func load() async {
        error = nil
        do {
            let page = try await Services.youtube.comments(token)
            comments = page.comments
            continuation = page.continuation
            total = page.countText
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadMore() async {
        guard let token = continuation else { return }
        continuation = nil
        if let page = try? await Services.youtube.comments(token) {
            let known = Set(comments.map(\.id))
            comments += page.comments.filter { !known.contains($0.id) }
            continuation = page.continuation
        }
    }
}

/// Commentaire de premier niveau avec ses réponses, chargées à la demande.
private struct CommentThreadRow: View {
    let comment: Comment
    @State private var replies: [Comment] = []
    @State private var repliesContinuation: String?
    @State private var expanded = false
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CommentRow(comment: comment)
            if comment.replyCount > 0, comment.repliesContinuation != nil {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                    if expanded && replies.isEmpty { Task { await loadReplies(comment.repliesContinuation) } }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        Text(expanded ? "Masquer les réponses" : "\(comment.replyCount) réponse\(comment.replyCount > 1 ? "s" : "")")
                        if loading { ProgressView().controlSize(.mini) }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.leading, 46)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(replies) { CommentRow(comment: $0, avatarSize: 26) }
                    if let more = repliesContinuation {
                        Button("Plus de réponses") { Task { await loadReplies(more) } }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.leading, 46)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
    }

    private func loadReplies(_ token: String?) async {
        guard let token, !loading else { return }
        loading = true
        defer { loading = false }
        if let page = try? await Services.youtube.comments(token) {
            replies += page.comments
            repliesContinuation = page.continuation
        }
    }
}

private struct CommentRow: View {
    let comment: Comment
    var avatarSize: CGFloat = 34

    @EnvironmentObject private var router: Router
    @AppStorage(SettingsKey.hideCounts) private var hideCounts = false
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if let id = comment.authorChannelId { router.open(.channel(id: id, name: comment.author)) }
            } label: {
                Avatar(url: comment.authorAvatarURL, size: avatarSize, name: comment.author)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, comment.isCreator ? 6 : 0)
                        .padding(.vertical, comment.isCreator ? 2 : 0)
                        .background(comment.isCreator ? AnyShapeStyle(Theme.fill) : AnyShapeStyle(.clear), in: Capsule())
                    if comment.isVerified { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.secondary) }
                    if let t = comment.publishedText { Text(t).font(.caption).foregroundStyle(.secondary) }
                }
                Text(comment.text)
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 6)
                    .textSelection(.enabled)
                    .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
                if !hideCounts, let likes = comment.likeCountText {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.thumbsup")
                        Text(likes)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(likes) J'aime")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct CommentSkeleton: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(Theme.fill).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Theme.fill).frame(width: 120, height: 10)
                Capsule().fill(Theme.fill).frame(height: 10)
                Capsule().fill(Theme.fill).frame(width: 200, height: 10)
            }
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
    }
}
