import SwiftUI

struct MessageBubbleView: View {
    let message: ChatMessage
    /// Looks up the quoted original message by id, from the same cache
    /// pattern the web client uses (messagesById) -- reply quotes render
    /// from what this client already has locally, never a server round
    /// trip.
    let lookupMessage: (Int) -> ChatMessage?
    let onLongPress: () -> Void
    let onSwipeReply: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var swipeArmed = false

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
                    Circle()
                        .fill(Theme.avatarColor(for: message.from))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Text(String(message.from.prefix(1)).uppercased())
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                }

                VStack(alignment: message.out ? .trailing : .leading, spacing: 3) {
                    if !message.out {
                        Text(message.from)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(Theme.avatarColor(for: message.from))
                    }

                    bubbleContent

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
            .onLongPressGesture(minimumDuration: 0.4) {
                onLongPress()
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            } else if message.isAudioMessage, let url = URL(string: message.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                AudioMessagePlayer(url: url, tint: message.out ? .white : Theme.accent)
            } else {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(message.out ? .white : Theme.text)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            if message.out {
                Theme.accentGradient
            } else {
                Theme.panel
            }
        }
        .clipShape(.rect(cornerRadius: 18))
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
    }

    private var reactionPills: some View {
        let grouped = Dictionary(grouping: message.reactions, by: \.emoji)
        return HStack(spacing: 4) {
            ForEach(grouped.keys.sorted(), id: \.self) { emoji in
                Text("\(emoji) \(grouped[emoji]?.count ?? 0)")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.accentSoft, in: .capsule)
            }
        }
    }
}
