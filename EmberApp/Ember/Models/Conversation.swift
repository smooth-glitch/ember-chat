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
    var messages: [ChatMessage] = []
    var historyLoaded = false

    static func key(dm user: String) -> String { "dm:\(user)" }
    static func key(group name: String) -> String { "group:\(name)" }
}
