import SwiftUI
import PhotosUI

/// Background gradients for text status updates (the server stores the index).
enum StatusPalette {
    static let gradients: [[Color]] = [
        [Color(hex: 0x58_56D6), Color(hex: 0x7A_78E0)],
        [Color(hex: 0xFF_2D55), Color(hex: 0xFF_9500)],
        [Color(hex: 0x0E_8A9E), Color(hex: 0x24_8A3D)],
        [Color(hex: 0xAF_52DE), Color(hex: 0x5E_5CE6)],
        [Color(hex: 0x00_7AFF), Color(hex: 0x5A_C8FA)],
        [Color(hex: 0xC7_6A00), Color(hex: 0xFF_CC00)],
        [Color(hex: 0x1C_1C2A), Color(hex: 0x2A_2860)],
        [Color(hex: 0xFF_3B30), Color(hex: 0x8E_0E00)],
    ]

    static func background(_ index: Int) -> LinearGradient {
        let colors = gradients[((index % gradients.count) + gradients.count) % gradients.count]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private func statusTimeText(_ date: Date) -> String {
    let time = date.formatted(.dateTime.hour().minute())
    if Calendar.current.isDateInToday(date) { return "Today, \(time)" }
    if Calendar.current.isDateInYesterday(date) { return "Yesterday, \(time)" }
    return date.formatted(.dateTime.month().day().hour().minute())
}

/// Profile photo (or initial) with a segmented ring: one arc per post, accent
/// for unseen, grey for seen -- same idea as WhatsApp's status ring.
private struct StatusAvatar: View {
    let name: String
    let avatarURL: String?
    let size: CGFloat
    var segments = 0
    var seen = 0

    var body: some View {
        ZStack {
            if segments > 0 { ring }
            ZStack {
                Circle().fill(Theme.avatarColor(for: name))
                if let avatarURL, let url = URL(string: avatarURL) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            initial
                        }
                    }
                    .clipShape(.circle)
                } else {
                    initial
                }
            }
            .frame(width: size - (segments > 0 ? 10 : 0), height: size - (segments > 0 ? 10 : 0))
        }
        .frame(width: size, height: size)
    }

    private var initial: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
    }

    private var ring: some View {
        ZStack {
            ForEach(0..<segments, id: \.self) { i in
                let gap = segments > 1 ? 0.03 : 0.0
                let span = 1.0 / Double(segments)
                Circle()
                    .trim(from: Double(i) * span + gap / 2, to: Double(i + 1) * span - gap / 2)
                    .stroke(i < seen ? Theme.muted.opacity(0.6) : Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(1.5)
    }
}

// MARK: - Updates tab

struct UpdatesTab: View {
    @Bindable var client: ChatClient
    @State private var showTextComposer = false
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var viewer: ViewerStart?
    @State private var uploading = false

    private struct ViewerStart: Identifiable {
        let id = UUID()
        let users: [String]
        let index: Int
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    myStatusRow
                }

                Section("Recent updates") {
                    let groups = client.statusGroups
                    if groups.isEmpty {
                        Text("No updates yet. When someone posts a status, it shows up here for 24 hours.")
                            .font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    ForEach(Array(groups.enumerated()), id: \.element.user) { index, group in
                        Button {
                            viewer = ViewerStart(users: groups.map(\.user), index: index)
                        } label: {
                            HStack(spacing: 12) {
                                StatusAvatar(
                                    name: group.user, avatarURL: client.profiles[group.user]?.avatar, size: 54,
                                    segments: group.posts.count,
                                    seen: group.posts.filter { client.viewedStatusIDs.contains($0.id) }.count
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.user).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.text)
                                    Text(statusTimeText(group.posts.last?.time ?? .now))
                                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onAppear { client.fetchProfile(for: group.user) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Updates")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showTextComposer = true } label: { Label("Text", systemImage: "textformat") }
                        Button { showPhotoPicker = true } label: { Label("Photo", systemImage: "photo") }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showTextComposer) { TextStatusComposer(client: client) }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in Task { await postPhoto(item) } }
            .fullScreenCover(item: $viewer) { start in
                StoryViewer(client: client, users: start.users, startIndex: start.index)
            }
            .task {
                // Test hook: EMBER_STORY=<user> opens that user's story once statuses arrive.
                guard let name = ProcessInfo.processInfo.environment["EMBER_STORY"] else { return }
                for _ in 0..<30 where client.statusGroups.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                let users = client.statusGroups.map(\.user)
                if let i = users.firstIndex(of: name) { viewer = ViewerStart(users: users, index: i) }
            }
        }
    }

    private var myStatusRow: some View {
        let mine = client.myStatuses
        return Button {
            if mine.isEmpty { showTextComposer = true } else { viewer = ViewerStart(users: [client.myName], index: 0) }
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    StatusAvatar(name: client.myName, avatarURL: client.myAvatarURL, size: 54, segments: mine.count, seen: mine.count)
                    if mine.isEmpty {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Theme.accent, in: .circle)
                            .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("My Status").font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(uploading ? "Uploading…" : mine.isEmpty ? "Tap to add a status update" : "\(mine.count) update\(mine.count == 1 ? "" : "s") · \(statusTimeText(mine.last?.time ?? .now))")
                        .font(.system(size: 13)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if uploading { ProgressView() }
            }
            .padding(.vertical, 2)
        }
    }

    private func postPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        uploading = true
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try? data.write(to: tmp)
        await client.postImageStatus(fileURL: tmp)
        uploading = false
        photoItem = nil
    }
}

// MARK: - Composer

private struct TextStatusComposer: View {
    @Bindable var client: ChatClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var bg = Int.random(in: 0..<StatusPalette.gradients.count)
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            StatusPalette.background(bg).ignoresSafeArea()

            TextField("Type a status", text: $text, axis: .vertical)
                .focused($focused)
                .font(.system(size: 30, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .tint(.white)
                .lineLimit(1...12)
                .padding(.horizontal, 28)
                .onChange(of: text) { _, new in if new.count > 700 { text = String(new.prefix(700)) } }
        }
        .overlay(alignment: .top) {
            GlassEffectContainer(spacing: 12) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) { bg = (bg + 1) % StatusPalette.gradients.count }
                    } label: {
                        Image(systemName: "paintpalette.fill").font(.system(size: 16)).frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                client.postTextStatus(text, bg: bg)
                dismiss()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .padding(20)
        }
        .onAppear { focused = true }
    }
}

// MARK: - Viewer

/// Full-screen story player: segmented progress, tap right/left to skip,
/// hold to pause, swipe down to close. Plays each author's posts in turn,
/// then moves on to the next author.
struct StoryViewer: View {
    @Bindable var client: ChatClient
    let users: [String]
    @State private var userIndex: Int
    @State private var postIndex = 0
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var showViewers = false
    @Environment(\.dismiss) private var dismiss

    private let duration: Double = 5

    init(client: ChatClient, users: [String], startIndex: Int) {
        self.client = client
        self.users = users
        self._userIndex = State(initialValue: startIndex)
    }

    private var user: String { users[min(userIndex, users.count - 1)] }
    private var posts: [StatusPost] { client.statuses(by: user) }
    private var post: StatusPost? { posts.indices.contains(postIndex) ? posts[postIndex] : nil }
    private var isMine: Bool { user == client.myName }
    private var paused: Bool { holding || showViewers }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let post {
                content(for: post)
                    .id(post.id)
                    .transition(.opacity)
            }

            // Tap zones: left third goes back, the rest goes forward.
            HStack(spacing: 0) {
                Color.clear.contentShape(.rect).onTapGesture { back() }.frame(maxWidth: .infinity)
                Color.clear.contentShape(.rect).onTapGesture { advance() }.frame(maxWidth: .infinity).layoutPriority(1)
            }
            .onLongPressGesture(minimumDuration: 0.15, pressing: { holding = $0 }, perform: {})
        }
        .overlay(alignment: .top) { header }
        .overlay(alignment: .bottom) { if isMine, let post { ownerBar(for: post) } }
        .gesture(DragGesture().onEnded { if $0.translation.height > 120 { dismiss() } })
        .statusBarHidden()
        .task(id: "\(userIndex)-\(post?.id ?? -1)") { await play() }
        .sheet(isPresented: $showViewers) { viewersSheet }
        .onChange(of: posts.count) { _, count in
            // The post being watched was deleted (or expired) under us.
            if count == 0 { dismiss() } else if postIndex >= count { postIndex = count - 1 }
        }
    }

    // MARK: pieces

    @ViewBuilder
    private func content(for post: StatusPost) -> some View {
        switch post.kind {
        case .text:
            ZStack {
                StatusPalette.background(post.bg).ignoresSafeArea()
                Text(post.content)
                    .font(.system(size: 30, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
            }
        case .image:
            if let url = URL(string: post.content) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fit)
                    case .failure: Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                    default: ProgressView().tint(.white)
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<max(posts.count, 1), id: \.self) { i in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white)
                                .frame(width: geo.size.width * (i < postIndex ? 1 : i == postIndex ? progress : 0))
                        }
                    }
                    .frame(height: 3)
                }
            }
            HStack(spacing: 10) {
                StatusAvatar(name: user, avatarURL: isMine ? client.myAvatarURL : client.profiles[user]?.avatar, size: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text(isMine ? "My Status" : user).font(.system(size: 14, weight: .semibold))
                    if let post { Text(statusTimeText(post.time)).font(.system(size: 11.5)).opacity(0.8) }
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.top, 8)
        .shadow(color: .black.opacity(0.35), radius: 6)
    }

    private func ownerBar(for post: StatusPost) -> some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                Button { showViewers = true } label: {
                    Label("\(post.views?.count ?? 0)", systemImage: "eye.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                }
                .glassEffect(.regular.interactive(), in: .capsule)

                Button {
                    client.deleteStatus(post.id)
                } label: {
                    Image(systemName: "trash.fill").font(.system(size: 16)).frame(width: 46, height: 46)
                }
                .glassEffect(.regular.interactive(), in: .circle)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.bottom, 14)
    }

    private var viewersSheet: some View {
        NavigationStack {
            List {
                let views = post?.views ?? []
                if views.isEmpty {
                    Text("No views yet").foregroundStyle(Theme.muted)
                }
                ForEach(views, id: \.self) { name in
                    HStack(spacing: 12) {
                        StatusAvatar(name: name, avatarURL: client.profiles[name]?.avatar, size: 36)
                        Text(name).foregroundStyle(Theme.text)
                    }
                }
            }
            .navigationTitle("Viewed by")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showViewers = false } } }
        }
        .presentationDetents([.medium])
    }

    // MARK: playback

    private func play() async {
        guard let post else { return }
        progress = 0
        client.viewStatus(post)
        client.fetchProfile(for: post.user)
        let step: CGFloat = 0.05
        while progress < 1 {
            try? await Task.sleep(for: .milliseconds(50))
            if Task.isCancelled { return }
            if !paused { progress += step / duration }
        }
        advance()
    }

    private func advance() {
        if postIndex + 1 < posts.count {
            postIndex += 1
        } else if userIndex + 1 < users.count {
            userIndex += 1
            postIndex = 0
        } else {
            dismiss()
        }
    }

    private func back() {
        if postIndex > 0 {
            postIndex -= 1
        } else if userIndex > 0 {
            userIndex -= 1
            postIndex = 0
        } else {
            progress = 0
        }
    }
}
