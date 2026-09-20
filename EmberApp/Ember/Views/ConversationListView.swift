import SwiftUI
import PhotosUI

/// Root post-login navigation. iOS 26's TabView *is* the floating Liquid
/// Glass pill bar by default now (no custom material/blur needed to get
/// that look) -- three tabs maps this app's actual surface (chats, people
/// to DM, your own account) rather than approximating a 5-tab layout this
/// app doesn't have destinations for.
struct ConversationListView: View {
    @Bindable var client: ChatClient

    var body: some View {
        TabView {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill") {
                ChatsTab(client: client)
            }
            Tab("People", systemImage: "person.2.fill") {
                PeopleTab(client: client)
            }
            Tab("You", systemImage: "person.crop.circle.fill") {
                ProfileTab(client: client)
            }
        }
        .tint(Theme.accent)
    }
}

private struct ChatsTab: View {
    @Bindable var client: ChatClient
    @State private var showNewGroup = false
    @State private var search = ""

    private var filteredKeys: [String] {
        guard !search.isEmpty else { return client.conversationOrder }
        return client.conversationOrder.filter {
            client.conversations[$0]?.title.localizedCaseInsensitiveContains(search) ?? false
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if client.conversationOrder.isEmpty {
                    ContentUnavailableView("No Chats Yet", systemImage: "bubble.left.and.bubble.right", description: Text("Start a conversation from the People tab."))
                } else if filteredKeys.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    List {
                        ForEach(filteredKeys, id: \.self) { key in
                            if let conv = client.conversations[key] {
                                NavigationLink(value: key) { row(for: conv) }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .navigationDestination(for: String.self) { key in
                ChatView(client: client, convKey: key)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewGroup = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .sheet(isPresented: $showNewGroup) { NewGroupView(client: client) }
        }
    }

    private func row(for conv: Conversation) -> some View {
        HStack(spacing: 12) {
            switch conv.kind {
            case .group:
                Circle().fill(Theme.accent).frame(width: 44, height: 44)
                    .overlay { Image(systemName: "person.3.fill").font(.system(size: 16)).foregroundStyle(.white) }
            case .global:
                Circle().fill(Theme.accentGradient).frame(width: 44, height: 44)
                    .overlay { Image(systemName: "globe").font(.system(size: 16)).foregroundStyle(.white) }
            case .dm:
                avatar(conv.title, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(conv.title).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(conv.messages.last?.text ?? " ")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
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
