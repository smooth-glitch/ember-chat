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
    /// Disappearing messages: hidden (and dropped) once this passes.
    var expires: Date? = nil

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

    /// One to three emoji and nothing else -- shown big with no bubble.
    var isEmojiOnly: Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 3, !isImageMessage, !isAudioMessage else { return false }
        return t.unicodeScalars.allSatisfy {
            ($0.properties.isEmoji && $0.value > 0x238C) || $0.value == 0xFE0F || $0.value == 0x200D
        }
    }

    /// A shared PDF: a bare uploaded-file URL ending in `.pdf`, with the
    /// original filename carried in a `?name=` query so the card can show it.
    var isDocumentMessage: Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.path.lowercased().hasSuffix(".pdf")
    }

    var documentName: String {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "name" })?.value,
              !name.isEmpty
        else { return "Document.pdf" }
        return name
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

/// One status update ("story"): visible to everyone for 24 hours.
struct StatusPost: Identifiable, Equatable {
    enum Kind: String { case text, image }

    var id: Int
    var user: String
    var kind: Kind
    /// The text itself, or an uploaded image URL.
    var content: String
    /// Index into StatusPalette.gradients (text posts only).
    var bg: Int
    var time: Date
    var expires: Date
    /// Who has viewed it. Only the server sends this, and only to the author.
    var views: [String]?
}
