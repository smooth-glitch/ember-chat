import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    /// Looks up the quoted original message by id, from the same cache
    /// pattern the web client uses (messagesById) -- reply quotes render
    /// from what this client already has locally, never a server round
    /// trip.
    let lookupMessage: (Int) -> ChatMessage?
    /// Resolved by the caller (ChatView) from client.profiles so reading it
    /// there registers the @Observable dependency -- a profile change then
    /// re-renders every bubble live, not just ones sent after it.
    var avatarURL: String?
    let onLongPress: () -> Void
    let onSwipeReply: () -> Void
    var onOpenImage: (URL) -> Void = { _ in }
    var onTapQuote: (Int) -> Void = { _ in }
    var onTapAvatar: (String) -> Void = { _ in }
    /// Briefly true after jumping here from a reply quote.
    var highlighted = false
    var starred = false
    var onTapReactions: () -> Void = {}

    @State private var dragOffset: CGFloat = 0
    @State private var swipeArmed = false
    @AppStorage("ember.haptics") private var hapticsOn = true

    private let triggerDistance: CGFloat = 64
    private let maxDrag: CGFloat = 84

    var body: some View {
        if message.kind == .system {
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.05), in: .capsule)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if message.out { Spacer(minLength: 40) }

                if !message.out {
                    ZStack {
                        Circle().fill(Theme.avatarColor(for: message.from))
                        if let avatarURL, let url = URL(string: avatarURL) {
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Text(String(message.from.prefix(1)).uppercased())
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .clipShape(.circle)
                        } else {
                            Text(String(message.from.prefix(1)).uppercased())
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .onTapGesture { onTapAvatar(message.from) }
                }

                VStack(alignment: message.out ? .trailing : .leading, spacing: 3) {
                    if !message.out {
                        Text(message.from)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Theme.avatarColor(for: message.from))
                    }

                    bubbleContent

                    if (message.time != nil || message.edited || starred) && !message.deleted {
                        HStack(spacing: 4) {
                            if starred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                            if message.edited { Text("Edited") }
                            if message.edited && message.time != nil { Text("·") }
                            if let time = message.time { Text(time, format: .dateTime.hour().minute()) }
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 4)
                    }

                    if !message.reactions.isEmpty {
                        reactionPills
                    }
                }

                if !message.out { Spacer(minLength: 40) }
            }
            .overlay(alignment: .leading) {
                if dragOffset > 4 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(swipeArmed ? .white : Theme.accent)
                        .frame(width: 30, height: 30)
                        .background(swipeArmed ? Theme.accent : Theme.accentSoft, in: .circle)
                        .scaleEffect(0.6 + 0.4 * min(1, dragOffset / triggerDistance))
                        .offset(x: -34)
                }
            }
            .offset(x: dragOffset)
            // `.simultaneousGesture` rather than `.highPriorityGesture` --
            // the latter forces every row's gesture recognizer to contest
            // priority against the ScrollView's own pan gesture on *every*
            // touch, which is what was making scrolling feel laggy (many
            // visible rows each fighting for gesture priority per frame).
            // Simultaneous lets the ScrollView win vertical drags for
            // free while this still activates correctly for horizontal
            // ones, since onChanged already bails unless the drag is
            // clearly more horizontal than vertical.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard value.translation.width > 0, abs(value.translation.width) > abs(value.translation.height) else { return }
                        let dx = value.translation.width
                        dragOffset = dx <= maxDrag ? dx : maxDrag + (dx - maxDrag) * 0.2
                        swipeArmed = dragOffset >= triggerDistance
                    }
                    .onEnded { _ in
                        if swipeArmed { onSwipeReply() }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            dragOffset = 0
                        }
                        swipeArmed = false
                    }
            )
            .sensoryFeedback(trigger: swipeArmed) { _, armed in hapticsOn && armed ? .impact(flexibility: .soft) : nil }
            .onLongPressGesture(minimumDuration: 0.4) {
                onLongPress()
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if message.deleted {
                Text("This message was deleted")
                    .font(.system(size: 15))
                    .italic()
                    .foregroundStyle(message.out ? .white.opacity(0.85) : Theme.muted)
            } else {
            if let replyTo = message.replyTo {
                replyQuote(for: replyTo)
            }

            if message.isImageMessage, let url = URL(string: message.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Group {
                    if url.isLikelyAnimated {
                        AnimatedGIFView(url: url).aspectRatio(contentMode: .fill)
                    } else {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            case .failure:
                                Image(systemName: "photo").foregroundStyle(Theme.muted)
                            default:
                                ProgressView()
                            }
                        }
                    }
                }
                .frame(width: 200, height: 200)
                .clipShape(.rect(cornerRadius: 14))
                .contentShape(.rect(cornerRadius: 14))
                .onTapGesture { onOpenImage(url) }
            } else if message.isDocumentMessage, let url = URL(string: message.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Link(destination: url) {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.richtext.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(message.out ? .white : Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message.documentName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(message.out ? .white : Theme.text)
                                .lineLimit(2)
                            Text("PDF · Tap to open")
                                .font(.system(size: 11.5))
                                .foregroundStyle(message.out ? .white.opacity(0.75) : Theme.muted)
                        }
                    }
                    .frame(maxWidth: 230, alignment: .leading)
                }
                .buttonStyle(.plain)
            } else if message.isAudioMessage, let url = URL(string: message.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AudioMessagePlayer(url: url, tint: message.out ? .white : Theme.accent)
            } else {
                Text(linkified(message.text))
                    .font(.system(size: message.isEmojiOnly ? 44 : 15))
                    .foregroundStyle(message.out ? .white : Theme.text)

                if let preview = message.preview, let url = URL(string: preview.url) {
                    Link(destination: url) { linkCard(preview) }
                        .buttonStyle(.plain)
                }
            }

            if let status = message.status {
                HStack {
                    Spacer()
                    Text(status == .sent ? "✓" : "✓✓")
                        .font(.system(size: 11))
                        .foregroundStyle(status == .read ? Color(hex: 0x4A_E3B5) : .white.opacity(0.75))
                }
            }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if message.isEmojiOnly && message.replyTo == nil {
                Color.clear
            } else if message.out {
                Theme.accentGradient
            } else {
                Theme.panel
            }
        }
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            if highlighted {
                RoundedRectangle(cornerRadius: 18).stroke(Theme.accent, lineWidth: 2.5)
            }
        }
        .animation(.easeOut(duration: 0.25), value: highlighted)
    }

    private func linkCard(_ preview: ChatMessage.LinkPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = URL(string: preview.image), !preview.image.isEmpty {
                AsyncImage(url: image) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.black.opacity(0.06)
                    }
                }
                .frame(width: 240, height: 120)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 2) {
                if !preview.title.isEmpty {
                    Text(preview.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(message.out ? .white : Theme.text)
                        .lineLimit(2)
                }
                if !preview.description.isEmpty {
                    Text(preview.description)
                        .font(.system(size: 12))
                        .foregroundStyle(message.out ? .white.opacity(0.8) : Theme.muted)
                        .lineLimit(2)
                }
                Text(URL(string: preview.url)?.host() ?? preview.url)
                    .font(.system(size: 11))
                    .foregroundStyle(message.out ? .white.opacity(0.65) : Theme.muted)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.leading)
            .padding(8)
            .frame(width: 240, alignment: .leading)
        }
        .background(message.out ? .white.opacity(0.16) : .black.opacity(0.05), in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
    }

    /// Underlines and links any URLs in the text (tapping opens Safari).
    private func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, let range = Range(match.range, in: result) else { continue }
            result[range].link = url
            result[range].underlineStyle = .single
            result[range].foregroundColor = message.out ? .white : Theme.accent
        }
        return result
    }

    @ViewBuilder
    private func replyQuote(for id: Int) -> some View {
        let original = lookupMessage(id)
        VStack(alignment: .leading, spacing: 2) {
            Text(original?.from ?? "Original message")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(message.out ? .white.opacity(0.9) : Theme.avatarColor(for: original?.from ?? ""))

            if let original, original.isImageMessage {
                HStack(spacing: 6) {
                    Text(original.text.lowercased().hasSuffix(".gif") ? "GIF" : "Photo")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(message.out ? .white.opacity(0.22) : .black.opacity(0.08), in: .rect(cornerRadius: 4))
                    if let url = URL(string: original.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(.rect(cornerRadius: 6))
                    }
                }
            } else {
                Text(original?.text ?? "Not available")
                    .font(.system(size: 12))
                    .foregroundStyle(message.out ? .white.opacity(0.75) : Theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .background(message.out ? .white.opacity(0.16) : .black.opacity(0.05), in: .rect(cornerRadius: 8))
        .contentShape(.rect(cornerRadius: 8))
        .onTapGesture { onTapQuote(id) }
    }

    private var reactionPills: some View {
        let grouped = Dictionary(grouping: message.reactions, by: \.emoji)
        return HStack(spacing: 4) {
            ForEach(grouped.keys.sorted(), id: \.self) { emoji in
                Text("\(emoji) \(grouped[emoji]?.count ?? 0)")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accentSoft, in: .capsule)
                    .contentShape(.capsule)
                    .onTapGesture { onTapReactions() }
            }
        }
    }
}
