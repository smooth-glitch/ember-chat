import SwiftUI
import PhotosUI

/// Root post-login navigation. iOS 26's TabView *is* the floating Liquid
/// Glass pill bar by default now (no custom material/blur needed to get
/// that look) -- three tabs maps this app's actual surface (chats, people
/// to DM, your own account) rather than approximating a 5-tab layout this
/// app doesn't have destinations for.
struct ConversationListView: View {
    @Bindable var client: ChatClient
    // EMBER_TAB is a test hook (like EMBER_OPEN) to launch straight onto a tab.
    @State private var tab = ProcessInfo.processInfo.environment["EMBER_TAB"] ?? "chats"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill", value: "chats") {
                ChatsTab(client: client)
            }
            .badge(client.totalUnread)
            Tab("Updates", systemImage: "circle.dashed", value: "updates") {
                UpdatesTab(client: client)
            }
            .badge(client.unviewedStatusCount)
            Tab("People", systemImage: "person.2.fill", value: "people") {
                PeopleTab(client: client)
            }
            Tab("You", systemImage: "person.crop.circle.fill", value: "you") {
                ProfileTab(client: client)
            }
        }
        .tint(Theme.accent)
    }
}

private struct ChatsTab: View {
    @Bindable var client: ChatClient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showNewGroup = false
    @State private var search = ""
    /// iPad / large-width only: which chat the split view's detail pane shows.
    @State private var selection: String?
    @State private var path: [String] = []

    private var filteredKeys: [String] {
        guard !search.isEmpty else { return client.displayOrder }
        return client.displayOrder.filter {
            client.conversations[$0]?.title.localizedCaseInsensitiveContains(search) ?? false
        }
    }

    private var archivedFiltered: [String] {
        guard !search.isEmpty else { return client.archivedOrder }
        return client.archivedOrder.filter {
            client.conversations[$0]?.title.localizedCaseInsensitiveContains(search) ?? false
        }
    }

    @ViewBuilder
    private func listRows(split: Bool) -> some View {
        ForEach(filteredKeys, id: \.self) { key in chatRow(key, split: split) }
        if !archivedFiltered.isEmpty {
            Section {
                ForEach(archivedFiltered, id: \.self) { key in chatRow(key, split: split) }
            } header: {
                Label("Archived", systemImage: "archivebox.fill")
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ key: String, split: Bool) -> some View {
        if let conv = client.conversations[key] {
            let pinned = client.pinnedKeys.contains(key)
            let muted = client.mutedKeys.contains(key)
            let archived = client.archivedKeys.contains(key)
            Group {
                if split {
                    // Soft tint instead of the system's solid accent fill, which
                    // made the muted preview text unreadable on the selected row.
                    row(for: conv).tag(key)
                        .listRowBackground(selection == key ? Theme.accentSoft : Color.clear)
                } else {
                    NavigationLink(value: key) { row(for: conv) }
                }
            }
            .swipeActions(edge: .leading) {
                Button { withAnimation { client.togglePin(key) } } label: {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash.fill" : "pin.fill")
                }
                .tint(Theme.accent)
                Button { client.markUnread(key) } label: {
                    Label("Unread", systemImage: "message.badge.fill")
                }
                .tint(.blue)
            }
            .swipeActions(edge: .trailing) {
                Button { withAnimation { client.toggleArchive(key) } } label: {
                    Label(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up.fill" : "archivebox.fill")
                }
                .tint(.gray)
                Button { withAnimation { client.toggleMute(key) } } label: {
                    Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell.fill" : "bell.slash.fill")
                }
                .tint(.indigo)
            }
            .contextMenu {
                Button { withAnimation { client.togglePin(key) } } label: {
                    Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin")
                }
                Button { withAnimation { client.toggleMute(key) } } label: {
                    Label(muted ? "Unmute" : "Mute", systemImage: muted ? "bell" : "bell.slash")
                }
                Button { client.markUnread(key) } label: {
                    Label("Mark as Unread", systemImage: "message.badge")
                }
                Button { withAnimation { client.toggleArchive(key) } } label: {
                    Label(archived ? "Unarchive" : "Archive", systemImage: archived ? "tray.and.arrow.up" : "archivebox")
                }
            }
        }
    }

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                chatList(split: true)
            } detail: {
                if let selection {
                    ChatView(client: client, convKey: selection).id(selection)
                } else {
                    ContentUnavailableView("Select a Chat", systemImage: "bubble.left.and.bubble.right", description: Text("Choose a conversation from the sidebar."))
                }
            }
        } else {
            NavigationStack(path: $path) {
                chatList(split: false)
                    .navigationDestination(for: String.self) { key in
                        ChatView(client: client, convKey: key)
                    }
            }
        }
    }

    @ViewBuilder
    private func chatList(split: Bool) -> some View {
        Group {
            if client.conversationOrder.isEmpty {
                ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.bubble.right", description: Text("Start a conversation from the People tab."))
            } else if filteredKeys.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                // Two separate Lists on purpose: a `selection:` binding on
                // the iPhone stack list competes with NavigationLink taps.
                if split {
                    List(selection: $selection) { listRows(split: true) }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                } else {
                    List { listRows(split: false) }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                }
            }
        }
        .background(Theme.bg)
        // Test hook (same idea as EMBER_AUTOJOIN): open a chat straight away
        // so it can be screenshotted without tapping. Inert on a normal launch.
        .onChange(of: client.pendingOpenKey) { _, key in
            guard let key, client.conversations[key] != nil else { return }
            if split { selection = key } else { path = [key] }
            client.pendingOpenKey = nil
        }
        .task {
            if let key = ProcessInfo.processInfo.environment["EMBER_OPEN"] {
                // Groups/DMs arrive a moment after connecting, so wait for it.
                for _ in 0..<30 where client.conversations[key] == nil { try? await Task.sleep(for: .milliseconds(200)) }
                guard client.conversations[key] != nil else { return }
                if split { selection = key } else { path = [key] }
            }
        }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewGroup = true } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .sheet(isPresented: $showNewGroup) { NewGroupView(client: client) }
    }

    private func preview(for conv: Conversation) -> String {
        if let draft = client.drafts[conv.id], !draft.isEmpty { return "Draft: \(draft)" }
        guard let last = conv.messages.last else { return " " }
        if last.deleted { return "This message was deleted" }
        if last.isImageMessage { return "📷 Photo" }
        if last.isAudioMessage { return "🎤 Voice message" }
        if last.isDocumentMessage { return "📄 \(last.documentName)" }
        return last.text
    }

    private func row(for conv: Conversation) -> some View {
        let unread = client.unreadCounts[conv.id] ?? 0
        return HStack(spacing: 12) {
            switch conv.kind {
            case .group:
                Circle().fill(Theme.accent).frame(width: 44, height: 44)
                    .overlay {
                        if let icon = conv.iconURL, let url = URL(string: icon) {
                            AsyncImage(url: url) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Image(systemName: "person.3.fill").font(.system(size: 16)).foregroundStyle(.white)
                                }
                            }
                            .clipShape(.circle)
                        } else {
                            Image(systemName: "person.3.fill").font(.system(size: 16)).foregroundStyle(.white)
                        }
                    }
            case .global:
                Circle().fill(Theme.accentGradient).frame(width: 44, height: 44)
                    .overlay { Image(systemName: "globe").font(.system(size: 16)).foregroundStyle(.white) }
            case .dm:
                avatar(conv.title, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(preview(for: conv))
                    .font(.system(size: 13, weight: unread > 0 ? .medium : .regular))
                    .foregroundStyle(unread > 0 ? Theme.text : Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if client.mutedKeys.contains(conv.id) {
                Image(systemName: "bell.slash.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if client.pinnedKeys.contains(conv.id) && unread == 0 {
                Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if unread > 0 {
                Text(unread > 99 ? "99+" : "\(unread)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .frame(minWidth: 22)
                    .background(client.mutedKeys.contains(conv.id) ? Theme.muted : Theme.accent, in: .capsule)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PeopleTab: View {
    @Bindable var client: ChatClient

    var body: some View {
        NavigationStack {
            Group {
                let others = client.onlineUsers.filter { $0 != client.myName }
                if others.isEmpty {
                    ContentUnavailableView("Nobody Else Online", systemImage: "person.2.slash")
                } else {
                    List {
                        ForEach(others, id: \.self) { user in
                            NavigationLink(value: Conversation.key(dm: user)) {
                                HStack(spacing: 12) {
                                    avatar(user, size: 40)
                                    Text(user).font(.system(size: 15.5)).foregroundStyle(Theme.text)
                                    Spacer()
                                    Circle().fill(.green).frame(width: 9, height: 9)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg)
            .navigationTitle("People")
            .navigationDestination(for: String.self) { key in
                ChatView(client: client, convKey: key)
            }
        }
    }
}

private struct ProfileTab: View {
    @Bindable var client: ChatClient
    @State private var photoItem: PhotosPickerItem?
    @State private var showStatusEditor = false
    @State private var showPrivacyInfo = false
    @State private var uploadingPhoto = false
    @AppStorage("ember.appearance") private var appearance = "system"
    @AppStorage("ember.haptics") private var hapticsOn = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            ZStack {
                                avatar(client.myName, size: 88, url: client.myAvatarURL)
                                if uploadingPhoto {
                                    Circle().fill(.black.opacity(0.4))
                                    ProgressView().tint(.white)
                                } else {
                                    Circle().stroke(Theme.bg, lineWidth: 3).frame(width: 28, height: 28)
                                        .background(Circle().fill(Theme.accent).frame(width: 28, height: 28))
                                        .overlay { Image(systemName: "camera.fill").font(.system(size: 11)).foregroundStyle(.white) }
                                        .frame(width: 88, height: 88, alignment: .bottomTrailing)
                                }
                            }
                        }
                        .onChange(of: photoItem) { _, item in Task { await uploadPhoto(item) } }

                        Text(client.myName).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                Section("About") {
                    Button {
                        showStatusEditor = true
                    } label: {
                        HStack {
                            Text(client.myStatus?.isEmpty == false ? client.myStatus! : "Set a status")
                                .foregroundStyle(client.myStatus?.isEmpty == false ? Theme.text : Theme.muted)
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        StarredMessagesView(client: client)
                    } label: {
                        Label("Starred Messages", systemImage: "star.fill")
                    }
                }

                if !client.blockedUsers.isEmpty {
                    Section("Blocked") {
                        ForEach(client.blockedUsers.sorted(), id: \.self) { user in
                            HStack {
                                Label(user, systemImage: "hand.raised.fill").foregroundStyle(Theme.text)
                                Spacer()
                                Button("Unblock") { client.toggleBlock(user) }
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                    }
                }

                Section("Appearance") {
                    Picker(selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        Label("Theme", systemImage: "circle.lefthalf.filled")
                    }
                    Toggle(isOn: $hapticsOn) {
                        Label("Haptics", systemImage: "iphone.radiowaves.left.and.right")
                    }
                }

                Section("Privacy") {
                    Button {
                        showPrivacyInfo = true
                    } label: {
                        HStack {
                            Label("Encryption", systemImage: "lock.fill")
                            Spacer()
                            Text("DMs only").font(.system(size: 13)).foregroundStyle(Theme.muted)
                            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        client.disconnect()
                    } label: {
                        Text("Log Out").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("You")
            .sheet(isPresented: $showStatusEditor) { StatusEditorView(client: client) }
            .sheet(isPresented: $showPrivacyInfo) { PrivacyInfoView() }
        }
    }

    private func uploadPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        uploadingPhoto = true
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try? data.write(to: tmpURL)
        await client.uploadAvatarOnly(fileURL: tmpURL)
        uploadingPhoto = false
        photoItem = nil
    }
}

private struct StatusEditorView: View {
    @Bindable var client: ChatClient
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""

    // Same preset list WhatsApp ships with -- familiar, and covers the
    // common cases without making everyone type their own every time.
    private let presets = [
        "Available", "Busy", "At work", "At school", "At the gym",
        "In a meeting", "At the movies", "Sleeping", "Urgent calls only",
        "Battery about to die 🔋",
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Type a custom status", text: $custom)
                }
                Section("Or choose one") {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            client.setStatus(preset)
                            dismiss()
                        } label: {
                            Text(preset).foregroundStyle(Theme.text)
                        }
                    }
                }
            }
            .navigationTitle("Set Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        client.setStatus(custom)
                        dismiss()
                    }
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PrivacyInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Direct messages are end-to-end encrypted", systemImage: "lock.fill")
                        .foregroundStyle(Theme.text)
                    Text("Each device generates its own private key, which never leaves it. Messages are encrypted before they're sent, and the server only ever stores or relays ciphertext it can't read.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Section {
                    Label("Global chat and groups are not end-to-end encrypted", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.text)
                    Text("Multi-party encryption needs a different, more complex scheme than a 1:1 DM. Traffic is still protected in transit (TLS), but the server can read these messages.")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
            }
            .navigationTitle("Encryption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

/// Shows the real photo when a URL is available, same initials-on-color
/// fallback everywhere else in the app when it isn't (no avatar set, or
/// still loading).
private func avatar(_ name: String, size: CGFloat, url: String? = nil) -> some View {
    ZStack {
        Circle().fill(Theme.avatarColor(for: name))
        if let url, let imageURL = URL(string: url) {
            AsyncImage(url: imageURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    initials(name, size: size)
                }
            }
            .clipShape(.circle)
        } else {
            initials(name, size: size)
        }
    }
    .frame(width: size, height: size)
}

private func initials(_ name: String, size: CGFloat) -> some View {
    Text(String(name.prefix(1)).uppercased())
        .font(.system(size: size * 0.4, weight: .semibold))
        .foregroundStyle(.white)
}

struct NewGroupView: View {
    @Bindable var client: ChatClient
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                TextField("Group name", text: $name)
                Section("Add online users") {
                    ForEach(client.onlineUsers.filter { $0 != client.myName }, id: \.self) { user in
                        Button {
                            if selected.contains(user) { selected.remove(user) } else { selected.insert(user) }
                        } label: {
                            HStack {
                                Text(user).foregroundStyle(Theme.text)
                                Spacer()
                                if selected.contains(user) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        client.createGroup(name: name, invite: Array(selected))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// Every message you've starred that this session has loaded.
private struct StarredMessagesView: View {
    @Bindable var client: ChatClient

    var body: some View {
        Group {
            let items = client.starredMessages
            if items.isEmpty {
                ContentUnavailableView("No Starred Messages", systemImage: "star", description: Text("Long-press a message and choose Star to keep it here."))
            } else {
                List(items, id: \.message.id) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.message.out ? "You" : item.message.from)
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                            Spacer()
                            Text(client.conversations[item.convKey]?.title ?? "")
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        }
                        Text(item.message.isImageMessage ? "📷 Photo" : item.message.isAudioMessage ? "🎤 Voice message" : item.message.isDocumentMessage ? "📄 \(item.message.documentName)" : item.message.text)
                            .font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(4)
                    }
                    .padding(.vertical, 3)
                    .swipeActions {
                        Button(role: .destructive) { client.toggleStar(item.message.id) } label: {
                            Label("Unstar", systemImage: "star.slash")
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Starred")
        .navigationBarTitleDisplayMode(.inline)
    }
}
