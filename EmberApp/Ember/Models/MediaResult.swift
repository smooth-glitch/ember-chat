import Foundation

/// One Giphy GIF/sticker search result -- `preview` for the grid thumbnail,
/// `url` is what actually gets sent as the message text (the receiving
/// client's own GIF_RE detection renders it inline, same as any other
/// image message).
struct MediaResult: Identifiable, Equatable {
    var id: String { url }
    var preview: String
    var url: String
}
