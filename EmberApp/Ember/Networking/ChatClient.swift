import Foundation
import CryptoKit

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

    /// `wss://` via the project's existing ngrok tunnel -- works from both
    /// the simulator and a real device (unlike `ws://localhost:8080/`,
    /// which only resolves for simulators, since they share the Mac's
    /// network stack). ngrok's free tier rotates this URL on every
    /// restart -- if it's gone stale, check `curl localhost:4040/api/
    /// tunnels` for the current one.
    var serverURL = URL(string: "wss://0178-2406-7400-12b-6041-14f4-4de7-a022-f693.ngrok-free.app/")!

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
        let msg = ChatMessage(id: placeholderID, text: trimmed, from: myName, out: true, replyTo: replyTo, reactions: [], kind: .chat, status: conv.kind == .dm ? .sent : nil)
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
        guard let url = await upload(fileURL: fileURL, filename: filename, mimeType: mimeType) else { return }
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

    private func appendMessage(_ msg: ChatMessage, to convKey: String) {
        guard var conv = conversations[convKey] else { return }
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
            appendMessage(ChatMessage(id: id, text: text, from: from, out: from == myName, replyTo: json["replyTo"] as? Int, reactions: parseReactions(json["reactions"]), kind: .chat), to: "global")

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
            appendMessage(ChatMessage(id: id, text: decoded, from: from, out: false, replyTo: json["replyTo"] as? Int, reactions: parseReactions(json["reactions"]), kind: .chat), to: key)

        case "group_message":
            guard let id = json["id"] as? Int, let from = json["from"] as? String, let text = json["text"] as? String, let group = json["group"] as? String else { return }
            let key = Conversation.key(group: group)
            if conversations[key] == nil {
                conversations[key] = Conversation(id: key, kind: .group, title: group)
                conversationOrder.append(key)
            }
            typingUsers[key]?.remove(from)
            appendMessage(ChatMessage(id: id, text: text, from: from, out: from == myName, replyTo: json["replyTo"] as? Int, reactions: parseReactions(json["reactions"]), kind: .chat), to: key)

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

        case "groups":
            guard let list = json["list"] as? [[String: Any]] else { return }
            for g in list {
                guard let name = g["name"] as? String else { continue }
                let key = Conversation.key(group: name)
                let members = (g["members"] as? [String]) ?? []
                if conversations[key] == nil {
                    conversations[key] = Conversation(id: key, kind: .group, title: name, members: members)
                    conversationOrder.append(key)
                }
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
                let msg = ChatMessage(id: id, text: decoded, from: from, out: from == myName, replyTo: item["replyTo"] as? Int, reactions: parseReactions(item["reactions"]), kind: .chat)
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
