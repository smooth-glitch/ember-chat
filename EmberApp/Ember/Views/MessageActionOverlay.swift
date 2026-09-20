import SwiftUI

/// The combined long-press sheet: a horizontal reaction bar plus a
/// Reply/Copy action list, both real Liquid Glass -- mirrors the same
/// pattern built for the web app's long-press UI (see feedback memory),
/// scoped to what this app actually supports (no Forward/Star/Delete,
/// same reasoning as the web version: don't fake buttons with nothing
/// behind them).
struct MessageActionOverlay: View {
    let message: ChatMessage
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    private let quickEmoji = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.001) // full-screen tap target to dismiss
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                GlassEffectContainer {
                    HStack(spacing: 4) {
                        ForEach(quickEmoji, id: \.self) { emoji in
                            Button {
                                onReact(emoji)
                            } label: {
                                Text(emoji).font(.system(size: 24))
                                    .frame(width: 40, height: 40)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6)
                    .glassEffect(.regular, in: .capsule)
                }

                VStack(spacing: 0) {
                    actionRow(icon: "arrowshape.turn.up.left.fill", label: "Reply", action: onReply)
                    Divider().padding(.leading, 44)
                    actionRow(icon: "doc.on.doc.fill", label: "Copy Text", action: onCopy)
                }
                .frame(width: 200)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }
        }
    }

    private func actionRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                Text(label)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
    }
}
