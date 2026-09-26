import Foundation

/// A single chat message, built up from whichever server event produced it
/// (a live "chat" push, or one entry inside a "history" reply). Mirrors the
/// plain-object shape web/index.html keeps per message, not the wire JSON
/// directly -- `out` is computed client-side by comparing `from` to the
/// signed-in username, same as the web client does.
struct ChatMessage: Identifiable, Equatable {
    var id: Int
    var text: String
    var from: String
    var out: Bool
    var replyTo: Int?
    var reactions: [Reaction]
    var kind: Kind
    /// DM-only (the original app never shows ticks in global/group chat).
    /// nil for anything that isn't your own outgoing DM.
    var status: DeliveryStatus? = nil
    var deleted: Bool = false
    /// When the server received it; nil for system lines and any message
    /// the server didn't stamp.
    var time: Date? = nil
    var edited: Bool = false
    var preview: LinkPreview? = nil

    enum DeliveryStatus { case sent, delivered, read }

    enum Kind: Equatable {
        case chat
        case system
    }

    /// Server-fetched Open Graph card for the first URL in a text message.
    struct LinkPreview: Equatable {
        var url: String
        var title: String
        var description: String
        var image: String
    }

    struct Reaction: Equatable {
        var user: String
        var emoji: String
    }

    /// True when the text is a bare media URL this app should render as an
    /// inline image rather than a text bubble -- same GIF_RE the web
    /// client uses (`.gif|.png|.jpe?g|.webp`, optionally followed by a
    /// query string).
    var isImageMessage: Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let path = url.path.lowercased()
        return [".gif", ".png", ".jpg", ".jpeg", ".webp"].contains { path.hasSuffix($0) }
    }

    /// Same AUDIO_RE the web client uses to render a bare voice-note URL as
    /// an `<audio>` player instead of text.
    var isAudioMessage: Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        let path = url.path.lowercased()
        return [".webm", ".ogg", ".m4a"].contains { path.hasSuffix($0) }
    }
}
