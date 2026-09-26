import Foundation
import CryptoKit
@preconcurrency import UserNotifications

/// Talks to the exact same hand-rolled WebSocket protocol web/index.html
/// uses -- plain-text commands out, JSON pushes in. No REST API; everything
/// is this one socket. Multi-conversation: global room, DMs, groups, all
/// keyed the same way the web client keys them ("global", "dm:<user>",
/// "group:<name>").
@MainActor
@Observable
final class ChatClient {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var state: ConnectionState = .disconnected
    /// Separate from `state` on purpose: an upload failure isn't a
    /// connection failure, and setting `state = .failed(...)` for it
    /// flipped RootView back to LoginView -- looked exactly like being
    /// logged out, when the socket was fine the whole time (confirmed
    /// live: a rejected upload booted the user back to the login screen
    /// with no actual disconnect).
    var uploadError: String?
    private(set) var conversations: [String: Conversation] = [
        "global": Conversation(id: "global", kind: .global, title: "Everyone")
    ]
    private(set) var conversationOrder: [String] = ["global"]
    /// convKey -> messages received while that conversation wasn't the one
    /// on screen. Cleared by `setActive` when the chat is opened.
    private(set) var unreadCounts: [String: Int] = [:]
    /// Muted chats keep receiving messages but don't count toward the badge.
    /// Local-only, persisted like pins.
    private(set) var mutedKeys: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ember.muted") ?? [])
    /// Starred messages (ids are unique across all conversations). Local-only.
    private(set) var starredIDs: Set<Int> = Set((UserDefaults.standard.array(forKey: "ember.starred") as? [Int]) ?? [])
    /// Archived chats leave the main list (and the badge) until unarchived.
    private(set) var archivedKeys: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ember.archived") ?? [])
    /// Unsent composer text per conversation, so leaving a chat and coming
    /// back doesn't lose what you were typing.
    var drafts: [String: String] = [:]
    /// The conversation currently visible in ChatView, if any.
    private(set) var activeConvKey: String?
    /// Chats pinned to the top of the list. Local-only (the server has no
    /// notion of pins), persisted so it survives relaunch.
    /// Users you've blocked. Their messages are dropped on arrival (the
    /// server still delivers them -- it has no block list). Local-only.
    private(set) var blockedUsers: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ember.blocked") ?? [])
    private(set) var pinnedKeys: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ember.pinned") ?? [])
    private(set) var onlineUsers: [String] = []
    private(set) var myName: String = ""
    var myAvatarURL: String?
    var myStatus: String?
    /// username -> (avatarURL, status), fetched on demand (see
    /// fetchProfile) rather than broadcast with the online list -- most
    /// screens only need this for whoever's actually visible.
    private(set) var profiles: [String: (avatar: String?, status: String?)] = [:]
    /// convKey -> usernames currently typing there, each with its own 3s
    /// expiry (no "stopped typing" event exists in this protocol -- see
    /// showTyping in web/index.html).
    private(set) var typingUsers: [String: Set<String>] = [:]
    private(set) var gifResults: [MediaResult] = []
    private(set) var stickerResults: [MediaResult] = []

    /// Local dev server (see chat_app:start_web_only/1). `localhost` only
    /// resolves from the simulator, which shares the Mac's network stack; a
    /// real device needs the Mac's LAN IP or a tunnel instead.
    var serverURL = URL(string: "ws://localhost:8080/")!

    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var manualDisconnect = false
    private var typingExpiryTasks: [String: Task<Void, Never>] = [:]
    private var lastTypingSentAt: [String: Date] = [:]
    private let typingThrottle: TimeInterval = 2.5
    /// (convKey, index into that conversation's messages) for the most
    /// recent optimistically-rendered send still waiting on its ack.
    private var pendingSend: (key: String, index: Int)?
    private var messagesByID: [Int: (convKey: String, message: ChatMessage)] = [:]

    // MARK: - DM end-to-end encryption
    private let identity = CryptoBox.loadOrCreateIdentity()
    /// username -> derived AES key, once we've fetched their public key.
    private var dmKeys: [String: SymmetricKey] = [:]
    /// True once a DM with this user is confirmed encrypted (their key was
    /// available); surfaced to the UI as a lock icon. A user who hasn't
    /// published a key yet (older session, or hasn't reconnected since
    /// this shipped) simply won't have an entry here -- DMs to them stay
    /// plaintext rather than silently failing to send.
    private(set) var dmEncrypted: Set<String> = []

    func connect(as name: String) {
        NotificationManager.shared.requestAuthorization()
        NotificationManager.onOpen = { [weak self] key in self?.pendingOpenKey = key }
        manualDisconnect = false
        myName = name
        state = .connecting
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: serverURL)
        self.task = task
        task.resume()
        send(raw: name)
        listenForever(on: task)
    }

    /// Fetches (and caches) another user's DM public key, deriving the
    /// shared AES key on arrival. Safe to call repeatedly -- a no-op once
    /// cached.
    private func ensureDMKey(for user: String) {
        guard dmKeys[user] == nil else { return }
        send(raw: "/getpubkey \(user)")
    }

    func disconnect() {
        manualDisconnect = true
        task?.cancel(with: .goingAway, reason: nil)
        receiveLoopTask?.cancel()
        state = .disconnected
    }

    // MARK: - Conversations

    func openDM(with user: String) {
        let key = Conversation.key(dm: user)
        if conversations[key] == nil {
            conversations[key] = Conversation(id: key, kind: .dm, title: user)
            conversationOrder.append(key)
        }
        // Requested before history on purpose: both go out over the same
        // connection roughly in submission order, so asking for the key
        // first improves the odds it resolves before history does and
        // this first load decrypts cleanly instead of needing a later
        // re-decrypt pass this app doesn't implement.
        ensureDMKey(for: user)
        if conversations[key]?.historyLoaded == false {
            send(raw: "/history dm \(user)")
        }
        send(raw: "/read dm \(user)")
    }

    private func decryptIfNeeded(_ text: String, from user: String) -> String {
        guard text.hasPrefix(CryptoBox.wirePrefix) else { return text }
        guard let key = dmKeys[user], let plaintext = CryptoBox.decrypt(text, key: key) else {
            return "🔒 Encrypted message (key not available yet)"
        }
        return plaintext
    }

    func createGroup(name: String, invite: [String]) {
        send(raw: "/creategroup \(name)")
        for user in invite { send(raw: "/addmember \(name) \(user)") }
    }

    func addMember(_ user: String, toGroup name: String) {
        send(raw: "/addmember \(name) \(user)")
    }

    /// Owner-only (the server enforces it): kicks `user` out of the group.
    func removeMember(_ user: String, fromGroup name: String) {
        send(raw: "/removemember \(name) \(user)")
    }

    func leaveGroup(_ name: String) {
        send(raw: "/leavegroup \(name)")
    }

    // MARK: - Profile

    func setStatus(_ status: String) {
        myStatus = status
        send(raw: "/setstatus \(status)")
    }

    func setAvatarURL(_ url: String) {
        myAvatarURL = url
        send(raw: "/setavatar \(url)")
    }

    /// Fetch-on-demand rather than broadcast with the online list -- a
    /// screen calls this for whichever usernames it's actually about to
    /// render (People tab rows, a DM's header).
    /// username -> when they last disconnected (server-stamped). Only
    /// meaningful while they're offline.
    private(set) var lastSeen: [String: Date] = [:]

    /// Re-request even if cached -- used when someone goes offline, since
    /// their last-seen time only exists after they disconnect.
    func refreshProfile(for user: String) {
        send(raw: "/getprofile \(user)")
    }

    func fetchProfile(for user: String) {
        guard profiles[user] == nil else { return }
        send(raw: "/getprofile \(user)")
    }

    // MARK: - Sending

    /// The server never echoes a send back to its own sender -- only an
    /// ack with the real id ("own_message_id" for global, "dm_ack" for
    /// DMs, "group_msg_ack" for groups). Confirmed live against the
    /// running server. Render optimistically here and reconcile the id
    /// when the ack lands, or the sender never sees their own message.
    func sendMessage(in convKey: String, text: String, replyTo: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var conv = conversations[convKey] else { return }
        let placeholderID = -(messagesByID.count + 1) - 1_000_000
        let msg = ChatMessage(id: placeholderID, text: trimmed, from: myName, out: true, replyTo: replyTo, reactions: [], kind: .chat, status: conv.kind == .dm ? .sent : nil, time: Date())
        conv.messages.append(msg)
        conversations[convKey] = conv
        pendingSend = (convKey, conv.messages.count - 1)

        switch conv.kind {
        case .global:
            send(raw: replyTo != nil ? "/reply \(replyTo!) \(trimmed)" : trimmed)
        case .dm:
            // The optimistic local `msg` above already holds the real
            // plaintext (that's what the sender sees rendered) -- only the
            // text that actually goes over the wire is swapped for
            // ciphertext, when a key is available. No key yet (recipient
            // hasn't published one) falls back to sending plaintext rather
            // than silently failing to deliver.
            let wireText = dmKeys[conv.title].flatMap { CryptoBox.encrypt(trimmed, key: $0) } ?? trimmed
            send(raw: replyTo != nil ? "/replydm \(conv.title) \(replyTo!) \(wireText)" : "/msg \(conv.title) \(wireText)")
        case .group:
            send(raw: replyTo != nil ? "/replygroup \(conv.title) \(replyTo!) \(trimmed)" : "/groupmsg \(conv.title) \(trimmed)")
        }
    }

    func sendReaction(in convKey: String, messageID: Int, emoji: String) {
        guard let conv = conversations[convKey] else { return }
        switch conv.kind {
        case .global: send(raw: "/react global \(messageID) \(emoji)")
        case .dm: send(raw: "/react dm \(conv.title) \(messageID) \(emoji)")
        case .group: send(raw: "/react group \(conv.title) \(messageID) \(emoji)")
        }
    }

    /// Server re-checks that this client is actually the original sender
    /// before honoring it (see chat_store:delete_message/2) -- this is just
    /// the send side, the resulting "deleted"/"dm_deleted"/"group_deleted"
    /// push (handled below) is what actually updates the message.
    func deleteMessage(in convKey: String, messageID: Int) {
        guard let conv = conversations[convKey] else { return }
        switch conv.kind {
        case .global: send(raw: "/delete global \(messageID)")
        case .dm: send(raw: "/delete dm \(conv.title) \(messageID)")
        case .group: send(raw: "/delete group \(conv.title) \(messageID)")
        }
    }

    /// Only your own, non-deleted text messages can be edited (the server
    /// enforces that too). The "edited"/"dm_edited"/"group_edited" push
    /// below is what actually updates the bubble, same as delete.
    func editMessage(in convKey: String, messageID: Int, newText: String) {
        guard let conv = conversations[convKey] else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch conv.kind {
        case .global: send(raw: "/edit global \(messageID) \(trimmed)")
        case .dm:
            let wireText = dmKeys[conv.title].flatMap { CryptoBox.encrypt(trimmed, key: $0) } ?? trimmed
            send(raw: "/edit dm \(conv.title) \(messageID) \(wireText)")
        case .group: send(raw: "/edit group \(conv.title) \(messageID) \(trimmed)")
        }
    }

    /// Empty query returns Giphy's trending results, same as the web
    /// client's initial panel-open behavior.
    func searchGifs(_ query: String) {
        send(raw: query.isEmpty ? "/gifsearch" : "/gifsearch \(query)")
    }

    func searchStickers(_ query: String) {
        send(raw: query.isEmpty ? "/stickersearch" : "/stickersearch \(query)")
    }

    func sendTypingPing(in convKey: String) {
        let now = Date()
        guard now.timeIntervalSince(lastTypingSentAt[convKey] ?? .distantPast) > typingThrottle else { return }
        lastTypingSentAt[convKey] = now
        guard let conv = conversations[convKey] else { return }
        switch conv.kind {
        case .global: send(raw: "/typing global")
        case .dm: send(raw: "/typing dm \(conv.title)")
        case .group: send(raw: "/typing group \(conv.title)")
        }
    }

    func lookupMessage(_ id: Int) -> ChatMessage? {
        messagesByID[id]?.message
    }

    /// `wss://` -> `https://` (or `ws://` -> `http://`), same swap the web
    /// client's `location.origin` gets for free by virtue of being loaded
    /// from that origin over the matching scheme. Used anywhere this app
    /// needs to hit a plain HTTP route on the same server the WebSocket
    /// connects to (`/upload`, `/auth/google/start`).
    var httpOrigin: URLComponents {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = ""
        return components
    }

    /// `/upload` is a plain HTTP POST (multipart/form-data, field "file"),
    /// not a WebSocket command -- same endpoint the web client's
    /// uploadBlobAndSend() hits. Response is `{"url": "/uploads/xxx.ext"}`;
    /// the returned URL is relative and needs the server's own origin
    /// prepended -- returns the full absolute URL, or nil on failure
    /// (setting `uploadError` itself).
    private func upload(fileURL: URL, filename: String, mimeType: String) async -> String? {
        var components = httpOrigin
        components.path = "/upload"
        guard let uploadURL = components.url, let fileData = try? Data(contentsOf: fileURL) else { return nil }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let relativeURL = json["url"] as? String
        else {
            uploadError = "Upload failed."
            return nil
        }
        components.path = relativeURL
        components.query = nil
        return components.url?.absoluteString
    }

    func uploadAndSend(fileURL: URL, filename: String, mimeType: String, in convKey: String) async {
        guard var url = await upload(fileURL: fileURL, filename: filename, mimeType: mimeType) else { return }
        if mimeType == "application/pdf" {
            // Uploaded files get random server names; keep the original one
            // in the query so recipients see what the document is called.
            url += "?name=" + (filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Document.pdf")
        }
        sendMessage(in: convKey, text: url)
    }

    /// Same `/upload` endpoint, but the result becomes the profile
    /// picture (`/setavatar`) instead of a chat message.
    func uploadAvatarOnly(fileURL: URL) async {
        guard let url = await upload(fileURL: fileURL, filename: "avatar.jpg", mimeType: "image/jpeg") else { return }
        setAvatarURL(url)
    }

    private func send(raw text: String) {
        task?.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            Task { @MainActor in self.state = .failed(error.localizedDescription) }
        }
    }

    private func listenForever(on task: URLSessionWebSocketTask) {
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text): await self.handleIncoming(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { await self.handleIncoming(text) }
                    @unknown default: break
                    }
                } catch {
                    if self.manualDisconnect { return }
                    self.state = .failed(error.localizedDescription)
                    return
                }
            }
        }
    }

    private func parseMediaResults(_ raw: Any?) -> [MediaResult] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let preview = entry["preview"] as? String, let url = entry["url"] as? String else { return nil }
            return MediaResult(preview: preview, url: url)
        }
    }

    private func parseReactions(_ raw: Any?) -> [ChatMessage.Reaction] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let user = entry["user"] as? String, let emoji = entry["emoji"] as? String else { return nil }
            return ChatMessage.Reaction(user: user, emoji: emoji)
        }
    }

    /// Server timestamps are epoch milliseconds; 0/absent means unknown.
    private static func date(_ raw: Any?) -> Date? {
        guard let ms = (raw as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    var totalUnread: Int {
        unreadCounts.reduce(0) { $0 + (mutedKeys.contains($1.key) || archivedKeys.contains($1.key) ? 0 : $1.value) }
    }

    func toggleMute(_ key: String) {
        if mutedKeys.contains(key) { mutedKeys.remove(key) } else { mutedKeys.insert(key) }
        UserDefaults.standard.set(Array(mutedKeys), forKey: "ember.muted")
    }

    /// Pinned chats first, otherwise the existing order.
    var displayOrder: [String] {
        let active = conversationOrder.filter { !archivedKeys.contains($0) }
        return active.filter(pinnedKeys.contains) + active.filter { !pinnedKeys.contains($0) }
    }

    var archivedOrder: [String] { conversationOrder.filter(archivedKeys.contains) }

    func toggleArchive(_ key: String) {
        if archivedKeys.contains(key) { archivedKeys.remove(key) } else { archivedKeys.insert(key) }
        UserDefaults.standard.set(Array(archivedKeys), forKey: "ember.archived")
    }

    /// WhatsApp's "Mark as unread": shows a badge again without new messages.
    func markUnread(_ key: String) {
        unreadCounts[key] = max(unreadCounts[key] ?? 0, 1)
    }

    func toggleBlock(_ user: String) {
        guard user != myName else { return }
        if blockedUsers.contains(user) { blockedUsers.remove(user) } else { blockedUsers.insert(user) }
        UserDefaults.standard.set(Array(blockedUsers), forKey: "ember.blocked")
    }

    private static func preview(_ raw: [String: Any]) -> ChatMessage.LinkPreview? {
        guard let url = raw["previewUrl"] as? String, !url.isEmpty else { return nil }
        return ChatMessage.LinkPreview(
            url: url,
            title: (raw["previewTitle"] as? String) ?? "",
            description: (raw["previewDescription"] as? String) ?? "",
            image: (raw["previewImage"] as? String) ?? ""
        )
    }

    func toggleStar(_ id: Int) {
        if starredIDs.contains(id) { starredIDs.remove(id) } else { starredIDs.insert(id) }
        UserDefaults.standard.set(Array(starredIDs), forKey: "ember.starred")
    }

    /// Starred messages this session has loaded, newest first, with the chat
    /// each one lives in.
    var starredMessages: [(convKey: String, message: ChatMessage)] {
        starredIDs.compactMap { messagesByID[$0] }
            .filter { !$0.message.deleted }
            .sorted { $0.message.id > $1.message.id }
    }

    // MARK: - Status updates

    private(set) var statuses: [StatusPost] = []
    private(set) var viewedStatusIDs: Set<Int> = Set((UserDefaults.standard.array(forKey: "ember.viewedStatus") as? [Int]) ?? [])

    var myStatuses: [StatusPost] { statuses.filter { $0.user == myName } }

    /// Other people's live posts grouped by author, most recently active first.
    /// Blocked users are left out.
    var statusGroups: [(user: String, posts: [StatusPost])] {
        Dictionary(grouping: statuses.filter { $0.user != myName && !blockedUsers.contains($0.user) }, by: \.user)
            .map { (user: $0.key, posts: $0.value.sorted { $0.id < $1.id }) }
            .sorted { ($0.posts.last?.id ?? 0) > ($1.posts.last?.id ?? 0) }
    }

    var unviewedStatusCount: Int {
        statusGroups.reduce(0) { total, group in total + group.posts.filter { !viewedStatusIDs.contains($0.id) }.count }
    }

    func statuses(by user: String) -> [StatusPost] {
        statuses.filter { $0.user == user }.sorted { $0.id < $1.id }
    }

    func postTextStatus(_ text: String, bg: Int) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send(raw: "/poststatus text \(bg) \(t)")
    }

    func postImageStatus(fileURL: URL) async {
        guard let url = await upload(fileURL: fileURL, filename: "status.jpg", mimeType: "image/jpeg") else { return }
        send(raw: "/poststatus image \(url)")
    }

    /// Marks it seen locally and (for other people's posts) tells the author.
    func viewStatus(_ post: StatusPost) {
        guard !viewedStatusIDs.contains(post.id) || post.user != myName else { return }
        if post.user != myName {
            viewedStatusIDs.insert(post.id)
            UserDefaults.standard.set(Array(viewedStatusIDs), forKey: "ember.viewedStatus")
            send(raw: "/viewstatus \(post.id)")
        }
    }

    func deleteStatus(_ id: Int) { send(raw: "/deletestatus \(id)") }

    private static func statusPost(_ raw: [String: Any]) -> StatusPost? {
        guard let id = raw["id"] as? Int, let user = raw["user"] as? String,
              let kind = (raw["kind"] as? String).flatMap(StatusPost.Kind.init(rawValue:)),
              let content = raw["content"] as? String,
              let ts = (raw["ts"] as? NSNumber)?.doubleValue, let exp = (raw["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return StatusPost(id: id, user: user, kind: kind, content: content, bg: (raw["bg"] as? Int) ?? 0,
                          time: Date(timeIntervalSince1970: ts / 1000), expires: Date(timeIntervalSince1970: exp / 1000),
                          views: raw["views"] as? [String])
    }

    private var systemCounter = -2_000_000
    private var pruneTask: Task<Void, Never>?

    /// Local "X turned on disappearing messages" style line.
    private func addSystemLine(_ text: String, to key: String) {
        systemCounter -= 1
        appendMessage(ChatMessage(id: systemCounter, text: text, from: "", out: false, replyTo: nil, reactions: [], kind: .system), to: key)
    }

    /// Drops messages whose disappearing timer has run out. The server
    /// deletes them for good on its own sweep; this just makes them vanish
    /// from the screen at the right moment.
    func pruneExpired() {
        let now = Date()
        if statuses.contains(where: { $0.expires <= now }) { statuses.removeAll { $0.expires <= now } }
        for (key, var conv) in conversations {
            let before = conv.messages.count
            let gone = conv.messages.filter { ($0.expires ?? .distantFuture) <= now }
            guard !gone.isEmpty else { continue }
            conv.messages.removeAll { ($0.expires ?? .distantFuture) <= now }
            for m in gone { messagesByID[m.id] = nil; starredIDs.remove(m.id) }
            if conv.messages.count != before { conversations[key] = conv }
        }
    }

    private func startPruning() {
        pruneTask?.cancel()
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.pruneExpired()
            }
        }
    }

    static func describe(seconds: Int) -> String {
        switch seconds {
        case 60: "1 minute"
        case 86_400: "24 hours"
        case 604_800: "7 days"
        case 7_776_000: "90 days"
        default: seconds % 86_400 == 0 ? "\(seconds / 86_400) days" : seconds % 3600 == 0 ? "\(seconds / 3600) hours" : "\(seconds) seconds"
        }
    }

    /// Any participant (DM) or member (group) can change it; 0 turns it off.
    /// The "disappear" push is what updates the UI.
    func setDisappearing(in convKey: String, seconds: Int) {
        guard let conv = conversations[convKey] else { return }
        switch conv.kind {
        case .dm: send(raw: "/disappear dm \(conv.title) \(seconds)")
        case .group: send(raw: "/disappear group \(conv.title) \(seconds)")
        case .global: break
        }
    }

    private func resolveMediaURL(_ s: String) -> String {
        guard s.hasPrefix("/") else { return s }
        var c = httpOrigin
        c.path = s
        return c.url?.absoluteString ?? s
    }

    func requestGroupInfo(_ name: String) { send(raw: "/groupinfo \(name)") }

    func setGroupDescription(_ name: String, _ text: String) {
        send(raw: "/setgroupdesc \(name) \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    func uploadGroupIcon(fileURL: URL, group name: String) async {
        guard let url = await upload(fileURL: fileURL, filename: "icon.jpg", mimeType: "image/jpeg") else { return }
        send(raw: "/setgroupicon \(name) \(url)")
    }

    /// Set when a notification is tapped; ChatsTab consumes it to open that chat.
    var pendingOpenKey: String?

    func setActive(_ key: String?) {
        activeConvKey = key
        if let key {
            unreadCounts[key] = nil
            NotificationManager.shared.clear(convKey: key)
            NotificationManager.shared.setBadge(totalUnread)
        }
    }

    func togglePin(_ key: String) {
        if pinnedKeys.contains(key) { pinnedKeys.remove(key) } else { pinnedKeys.insert(key) }
        UserDefaults.standard.set(Array(pinnedKeys), forKey: "ember.pinned")
    }

    private func appendMessage(_ msg: ChatMessage, to convKey: String) {
        guard var conv = conversations[convKey] else { return }
        if !msg.out, msg.kind == .chat, blockedUsers.contains(msg.from) { return }
        if !msg.out, msg.kind == .chat, convKey != activeConvKey {
            unreadCounts[convKey, default: 0] += 1
            if !mutedKeys.contains(convKey), !archivedKeys.contains(convKey) {
                let preview = msg.isImageMessage ? "📷 Photo" : msg.isAudioMessage ? "🎤 Voice message" : msg.isDocumentMessage ? "📄 \(msg.documentName)" : msg.text
                let isDM = conv.kind == .dm
                NotificationManager.shared.post(
                    title: isDM ? msg.from : conv.title,
                    body: isDM ? preview : "\(msg.from): \(preview)",
                    convKey: convKey
                )
                NotificationManager.shared.setBadge(totalUnread)
            }
        }
        conv.messages.append(msg)
        conversations[convKey] = conv
        messagesByID[msg.id] = (convKey, msg)
    }

    private func markTyping(_ user: String, in convKey: String) {
        guard user != myName else { return }
        typingUsers[convKey, default: []].insert(user)
        let taskKey = "\(convKey)|\(user)"
        typingExpiryTasks[taskKey]?.cancel()
        typingExpiryTasks[taskKey] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.typingUsers[convKey]?.remove(user)
        }
    }

    private func handleIncoming(_ text: String) async {
        guard
            let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        switch type {
        case "welcome":
            state = .connected
            startPruning()
            send(raw: "/statuses")
            myName = (json["name"] as? String) ?? myName
            send(raw: "/list")
            send(raw: "/groups")
            send(raw: "/pubkey \(CryptoBox.publicKeyBase64(identity))")
            send(raw: "/getprofile \(myName)") // restore avatar/status set in an earlier session

        case "error":
            state = .failed((json["text"] as? String) ?? "Server error.")

        case "system":
            let text = (json["text"] as? String) ?? ""
            appendMessage(ChatMessage(id: -messagesByID.count - 1, text: text, from: "", out: false, replyTo: nil, reactions: [], kind: .system), to: "global")
            send(raw: "/list")

        case "chat":
            guard let id = json["id"] as? Int, let from = json["from"] as? String, let text = json["text"] as? String else { return }
            typingUsers["global"]?.remove(from)
            appendMessage(ChatMessage(id: id, text: text, from: from, out: from == myName, replyTo: json["replyTo"] as? Int, reactions: parseReactions(json["reactions"]), kind: .chat, time: Self.date(json["ts"]), expires: Self.date(json["exp"])), to: "global")

        case "private":
            guard let id = json["id"] as? Int, let from = json["from"] as? String, let text = json["text"] as? String else { return }
            let key = Conversation.key(dm: from)
            if conversations[key] == nil {
                conversations[key] = Conversation(id: key, kind: .dm, title: from)
                conversationOrder.append(key)
            }
            typingUsers[key]?.remove(from)
            ensureDMKey(for: from) // so a reply we send back can encrypt, and the UI can show the lock
            let decoded = decryptIfNeeded(text, from: from)
            appendMessage(ChatMessage(id: id, text: decoded, from: from, out: false, replyTo: json["replyTo"] as? Int, reactions: parseReactions(json["reactions"]), kind: .chat, time: Self.date(json["ts"]), expires: Self.date(json["exp"])), to: key)

        case "group_message":
            guard let id = json["id"] as? Int, let from = json["from"] as? String, let text = json["text"] as? String, let group = json["group"] as? String else { return }
            let key = Conversation.key(group: group)
            if conversations[key] == nil {
                conversations[key] = Conversation(id: key, kind: .group, title: group)
                conversationOrder.append(key)
            }
            typingUsers[key]?.remove(from)
            appendMessage(ChatMessage(id: id, text: text, from: from, out: from == myName, replyTo: json["replyTo"] as? Int, reactions: parseReactions(json["reactions"]), kind: .chat, time: Self.date(json["ts"]), expires: Self.date(json["exp"])), to: key)

        case "group_system":
            guard let group = json["group"] as? String, let text = json["text"] as? String else { return }
            let key = Conversation.key(group: group)
            appendMessage(ChatMessage(id: -messagesByID.count - 1, text: text, from: "", out: false, replyTo: nil, reactions: [], kind: .system), to: key)

        case "group_created", "added_to_group":
            guard let name = json["name"] as? String else { return }
            let key = Conversation.key(group: name)
            let members = (json["members"] as? [String]) ?? (json["list"] as? [String]) ?? []
            if conversations[key] == nil {
                conversations[key] = Conversation(id: key, kind: .group, title: name, members: members)
                conversationOrder.append(key)
            } else {
                conversations[key]?.members = members
            }

        case "statuses":
            let list = (json["list"] as? [[String: Any]]) ?? []
            statuses = list.compactMap(Self.statusPost)

        case "status_new":
            guard let raw = json["item"] as? [String: Any], let post = Self.statusPost(raw),
                  !statuses.contains(where: { $0.id == post.id }) else { return }
            statuses.append(post)

        case "status_deleted":
            if let id = json["id"] as? Int { statuses.removeAll { $0.id == id } }

        case "status_view":
            guard let id = json["id"] as? Int, let viewer = json["viewer"] as? String,
                  let i = statuses.firstIndex(where: { $0.id == id }) else { return }
            var views = statuses[i].views ?? []
            if !views.contains(viewer) { views.append(viewer) }
            statuses[i].views = views

        case "disappear":
            guard let scope = json["scope"] as? String, let target = json["target"] as? String,
                  let secs = (json["seconds"] as? NSNumber)?.intValue else { return }
            let key = scope == "dm" ? Conversation.key(dm: target) : Conversation.key(group: target)
            if conversations[key] == nil, scope == "dm" {
                conversations[key] = Conversation(id: key, kind: .dm, title: target)
                conversationOrder.append(key)
            }
            guard conversations[key] != nil else { return }
            let changed = conversations[key]?.disappearSeconds != secs
            conversations[key]?.disappearSeconds = secs
            // "by" is empty when this is just the current setting sent with history.
            if let by = json["by"] as? String, !by.isEmpty, changed {
                let who = by == myName ? "You" : by
                addSystemLine(secs == 0 ? "\(who) turned off disappearing messages" : "\(who) set messages to disappear after \(Self.describe(seconds: secs))", to: key)
            }

        case "group_meta":
            guard let name = json["name"] as? String else { return }
            let key = Conversation.key(group: name)
            guard conversations[key] != nil else { return }
            conversations[key]?.groupDescription = (json["description"] as? String) ?? ""
            let icon = (json["icon"] as? String) ?? ""
            conversations[key]?.iconURL = icon.isEmpty ? nil : resolveMediaURL(icon)

        case "group_members":
            // Live membership/owner change pushed to every member.
            guard let name = json["name"] as? String else { return }
            let key = Conversation.key(group: name)
            guard conversations[key] != nil else { return }
            conversations[key]?.members = (json["members"] as? [String]) ?? []
            conversations[key]?.owner = (json["owner"] as? String) ?? ""

        case "groups":
            guard let list = json["list"] as? [[String: Any]] else { return }
            for g in list {
                guard let name = g["name"] as? String else { continue }
                let key = Conversation.key(group: name)
                let members = (g["members"] as? [String]) ?? []
                let owner = (g["owner"] as? String) ?? ""
                let desc = (g["description"] as? String) ?? ""
                let icon = (g["icon"] as? String) ?? ""
                if conversations[key] == nil {
                    conversations[key] = Conversation(id: key, kind: .group, title: name, members: members, owner: owner)
                    conversationOrder.append(key)
                } else {
                    conversations[key]?.members = members
                    conversations[key]?.owner = owner
                }
                conversations[key]?.groupDescription = desc
                conversations[key]?.iconURL = icon.isEmpty ? nil : resolveMediaURL(icon)
            }

        case "left_group":
            guard let name = json["text"] as? String else { return }
            let key = Conversation.key(group: name)
            conversations.removeValue(forKey: key)
            conversationOrder.removeAll { $0 == key }

        case "history":
            guard let scope = json["scope"] as? String else { return }
            let key: String
            switch scope {
            case "global": key = "global"
            case "dm": key = Conversation.key(dm: (json["with"] as? String) ?? "")
            case "group": key = Conversation.key(group: (json["group"] as? String) ?? "")
            default: return
            }
            guard var conv = conversations[key], !conv.historyLoaded, let list = json["list"] as? [[String: Any]] else { return }
            conv.historyLoaded = true
            // For a DM, the "other party" for key lookup is always the
            // conversation partner (conv.title), never item["from"] --
            // that's us for our own past sent messages in this same
            // history list.
            let dmPartner = conv.kind == .dm ? conv.title : nil
            let historical: [ChatMessage] = list.compactMap { item in
                guard let id = item["id"] as? Int, let from = item["from"] as? String, let text = item["text"] as? String else { return nil }
                let decoded = dmPartner.map { decryptIfNeeded(text, from: $0) } ?? text
                let msg = ChatMessage(id: id, text: decoded, from: from, out: from == myName, replyTo: item["replyTo"] as? Int, reactions: parseReactions(item["reactions"]), kind: .chat, deleted: (item["deleted"] as? Bool) ?? false, time: Self.date(item["ts"]), edited: (item["edited"] as? Bool) ?? false, preview: Self.preview(item), expires: Self.date(item["exp"]))
                if blockedUsers.contains(from) && from != myName { return nil }
                messagesByID[id] = (key, msg)
                return msg
            }
            let existingIDs = Set(conv.messages.map(\.id))
            conv.messages = historical.filter { !existingIDs.contains($0.id) } + conv.messages
            conversations[key] = conv

        case "own_message_id", "dm_ack", "group_msg_ack":
            guard let pending = pendingSend, let realID = json["id"] as? Int,
                  var conv = conversations[pending.key], conv.messages.indices.contains(pending.index) else { return }
            conv.messages[pending.index].id = realID
            if type == "dm_ack" {
                conv.messages[pending.index].status = (json["status"] as? String) == "read" ? .read : .delivered
            }
            conversations[pending.key] = conv
            messagesByID[realID] = (pending.key, conv.messages[pending.index])
            pendingSend = nil

        case "dm_read":
            // The recipient just opened this DM -- every message *we've*
            // sent them so far is now read, same all-at-once semantics as
            // markConversationRead() in web/index.html (this protocol has
            // no per-message read acks, only "everything up to now").
            guard let from = json["from"] as? String else { return }
            let key = Conversation.key(dm: from)
            guard var conv = conversations[key] else { return }
            for i in conv.messages.indices where conv.messages[i].out {
                conv.messages[i].status = .read
            }
            conversations[key] = conv

        case "reaction", "dm_reaction", "group_reaction":
            guard let messageID = json["messageId"] as? Int, let (key, _) = messagesByID[messageID], var conv = conversations[key],
                  let index = conv.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conv.messages[index].reactions = parseReactions(json["reactions"])
            conversations[key] = conv
            messagesByID[messageID]?.message = conv.messages[index]

        case "deleted", "dm_deleted", "group_deleted":
            guard let messageID = json["messageId"] as? Int, let (key, _) = messagesByID[messageID], var conv = conversations[key],
                  let index = conv.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conv.messages[index].deleted = true
            conv.messages[index].text = ""
            conv.messages[index].reactions = []
            conversations[key] = conv
            messagesByID[messageID]?.message = conv.messages[index]

        case "edited", "dm_edited", "group_edited":
            guard let messageID = json["messageId"] as? Int, let text = json["text"] as? String,
                  let (key, _) = messagesByID[messageID], var conv = conversations[key],
                  let index = conv.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conv.messages[index].text = conv.kind == .dm ? decryptIfNeeded(text, from: conv.title) : text
            conv.messages[index].edited = true
            conversations[key] = conv
            messagesByID[messageID]?.message = conv.messages[index]

        case "link_preview", "dm_link_preview", "group_link_preview":
            guard let messageID = json["messageId"] as? Int, let (key, _) = messagesByID[messageID], var conv = conversations[key],
                  let index = conv.messages.firstIndex(where: { $0.id == messageID }) else { return }
            conv.messages[index].preview = Self.preview(json)
            conversations[key] = conv
            messagesByID[messageID]?.message = conv.messages[index]

        case "typing":
            if let user = json["text"] as? String { markTyping(user, in: "global") }

        case "typing_dm":
            if let user = json["from"] as? String { markTyping(user, in: Conversation.key(dm: user)) }

        case "group_typing":
            if let user = json["from"] as? String, let group = json["group"] as? String { markTyping(user, in: Conversation.key(group: group)) }

        case "profile":
            guard let user = json["user"] as? String else { return }
            let avatar = json["avatar"] as? String
            let status = json["status"] as? String
            profiles[user] = (avatar, status)
            // Only the /getprofile reply carries lastSeen; the live
            // avatar/status broadcast doesn't, so don't clear it then.
            if let ms = (json["lastSeen"] as? NSNumber)?.doubleValue, ms > 0 {
                lastSeen[user] = Date(timeIntervalSince1970: ms / 1000)
            }
            if user == myName {
                myAvatarURL = avatar
                myStatus = status
            }

        case "pubkey":
            guard let user = json["user"] as? String, let b64 = json["key"] as? String,
                  let symmetric = CryptoBox.symmetricKey(myPrivate: identity, theirPublicBase64: b64)
            else { return }
            dmKeys[user] = symmetric
            dmEncrypted.insert(user)

        case "gif_results":
            gifResults = parseMediaResults(json["results"])

        case "sticker_results":
            stickerResults = parseMediaResults(json["results"])

        case "users":
            onlineUsers = (json["list"] as? [String]) ?? []

        default:
            break
        }
    }
}


/// Local notifications for messages in chats that aren't open. Works while
/// the app is in the foreground (banner over another chat) and for the short
/// time iOS keeps the socket alive after backgrounding -- true push while
/// the app is closed would need APNs and a server-side sender.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationManager()

    /// Called on the main actor with the tapped notification's conversation key.
    @MainActor static var onOpen: ((String) -> Void)?

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, convKey: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = convKey
        content.userInfo = ["convKey": convKey]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count)
    }

    func clear(convKey: String) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == convKey }.map(\.request.identifier)
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let key = response.notification.request.content.userInfo["convKey"] as? String else { return }
        await MainActor.run { Self.onOpen?(key) }
    }
}
