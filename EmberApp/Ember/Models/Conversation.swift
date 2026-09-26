import Foundation

/// One chat surface -- global room, a DM, or a group -- keyed the same way
/// the web client keys `conversations` (Map<String, conv>): "global",
/// "dm:<username>", "group:<name>".
struct Conversation: Identifiable, Equatable {
    enum Kind: Equatable {
        case global
        case dm
        case group
    }

    var id: String
    var kind: Kind
    var title: String
    var members: [String] = []
    /// Groups only: the one member who can remove others. Empty until the
    /// server says (older servers never send it).
    var owner: String = ""
    /// Disappearing-messages timer in seconds; 0 = off.
    var disappearSeconds = 0
    /// Groups only, set by the owner.
    var groupDescription = ""
    var iconURL: String?
    var messages: [ChatMessage] = []
    var historyLoaded = false

    static func key(dm user: String) -> String { "dm:\(user)" }
    static func key(group name: String) -> String { "group:\(name)" }
}
