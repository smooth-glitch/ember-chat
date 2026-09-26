import SwiftUI
import UIKit
import PhotosUI
import Photos
import CoreLocation
import UniformTypeIdentifiers

struct ChatView: View {
    @Bindable var client: ChatClient
    let convKey: String
    @State private var draft = ""
    @State private var showMembers = false
    @State private var actionSheetMessage: ChatMessage?
    @State private var replyingTo: ChatMessage?
    @State private var showMediaPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var recorder = AudioRecorder()
    @FocusState private var composerFocused: Bool
    @State private var isAtBottom = true
    /// Messages that arrived while the user was scrolled up reading history;
    /// shown on the scroll-to-bottom button instead of yanking the view away.
    @State private var missedCount = 0
    @State private var sendCount = 0
    @State private var viewerItem: ViewerItem?
    @State private var profileUser: UserRef?
    @State private var highlightID: Int?
    @AppStorage("ember.haptics") private var hapticsOn = true
    @State private var editingMessage: ChatMessage?
    @State private var forwardBatch: ForwardBatch?
    @State private var selectionMode = false
    @State private var selectedIDs: Set<Int> = []
    @State private var showDeleteConfirm = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showFileImporter = false
    @State private var locationFetcher = LocationFetcher()
    @State private var sharingLocation = false
    @State private var searchActive = false
    @State private var searchText = ""
    @State private var searchIndex = 0
    @FocusState private var searchFocused: Bool

    private var conversation: Conversation? { client.conversations[convKey] }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(Array((conversation?.messages ?? []).enumerated()), id: \.element.id) { index, message in
                                if let day = dayDivider(at: index) {
                                    Text(day)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Theme.muted)
                                        .padding(.horizontal, 12).padding(.vertical, 4)
                                        .glassEffect(.regular, in: .capsule)
                                        .padding(.vertical, 6)
                                }
                                MessageBubbleView(
                                    message: message,
                                    lookupMessage: client.lookupMessage,
                                    avatarURL: client.profiles[message.from]?.avatar,
                                    onLongPress: { actionSheetMessage = message },
                                    onSwipeReply: { replyingTo = message },
                                    onOpenImage: { viewerItem = ViewerItem(url: $0) },
                                    onTapQuote: { id in jump(to: id, proxy: proxy) },
                                    onTapAvatar: { profileUser = UserRef(name: $0) },
                                    highlighted: highlightID == message.id,
                                    starred: client.starredIDs.contains(message.id)
                                )
                                .overlay {
                                    if selectionMode && message.kind == .chat {
                                        Color.clear.contentShape(.rect)
                                            .onTapGesture { toggleSelected(message.id) }
                                    }
                                }
                                .overlay(alignment: .leading) {
                                    if selectionMode && message.kind == .chat {
                                        Image(systemName: selectedIDs.contains(message.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 22))
                                            .foregroundStyle(selectedIDs.contains(message.id) ? Theme.accent : Theme.muted)
                                            .offset(x: -6)
                                    }
                                }
                                .id(message.id)
                                .onAppear { client.fetchProfile(for: message.from) }
                                .padding(.horizontal, 14)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geo in
                        // Distance from the last message to the top of the composer
                        // (contentInsets.bottom is the composer/safe-area inset).
                        geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height - geo.contentInsets.bottom
                    } action: { _, distance in
                        let atBottom = distance <= 80
                        isAtBottom = atBottom
                        if atBottom { missedCount = 0 }
                    }
                    // Start pinned to the bottom (no scroll animation at all on open).
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: conversation?.messages.count) { old, new in
                        guard let last = conversation?.messages.last else { return }
                        if isAtBottom || last.out {
                            // Animate only a single new message arriving; a bulk
                            // history load jumps, since animating a scroll across
                            // thousands of points loads every GIF and link card
                            // on the way and stalls the UI.
                            if let old, let new, new == old + 1 {
                                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                            } else {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        } else {
                            missedCount += 1
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !isAtBottom {
                            scrollToBottomButton {
                                guard let last = conversation?.messages.last else { return }
                                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                            .padding(.trailing, 14).padding(.bottom, 10)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.3, bounce: 0.2), value: isAtBottom)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if searchActive { searchBar(proxy: proxy) }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 8) {
                            if selectionMode {
                                selectionBar
                            } else {
                                if let editingMessage {
                                    editBanner(for: editingMessage)
                                } else if let replyingTo {
                                    replyBanner(for: replyingTo)
                                }
                                composer
                            }
                        }
                    }
            }

            if let actionSheetMessage {
                MessageActionOverlay(
                    message: actionSheetMessage,
                    onReact: { emoji in
                        client.sendReaction(in: convKey, messageID: actionSheetMessage.id, emoji: emoji)
                        self.actionSheetMessage = nil
                    },
                    onReply: {
                        replyingTo = actionSheetMessage
                        self.actionSheetMessage = nil
                    },
                    onCopy: {
                        UIPasteboard.general.string = actionSheetMessage.text
                        self.actionSheetMessage = nil
                    },
                    onEdit: {
                        editingMessage = actionSheetMessage
                        replyingTo = nil
                        draft = actionSheetMessage.text
                        composerFocused = true
                        self.actionSheetMessage = nil
                    },
                    onForward: {
                        forwardBatch = ForwardBatch(messages: [actionSheetMessage])
                        self.actionSheetMessage = nil
                    },
                    onStar: {
                        client.toggleStar(actionSheetMessage.id)
                        self.actionSheetMessage = nil
                    },
                    isStarred: client.starredIDs.contains(actionSheetMessage.id),
                    onSelect: {
                        selectedIDs = [actionSheetMessage.id]
                        withAnimation(.spring(duration: 0.3)) { selectionMode = true }
                        self.actionSheetMessage = nil
                    },
                    onDelete: {
                        client.deleteMessage(in: convKey, messageID: actionSheetMessage.id)
                        self.actionSheetMessage = nil
                    },
                    onDismiss: { self.actionSheetMessage = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: actionSheetMessage != nil)
        .navigationTitle(conversation?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if selectionMode {
                    Text("\(selectedIDs.count) selected").font(.system(size: 15, weight: .semibold))
                } else {
                    VStack(spacing: 1) {
                        Text(conversation?.title ?? "").font(.system(size: 15, weight: .semibold))
                        Text(topbarSubtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if selectionMode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { exitSelection() }
                }
            } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.spring(duration: 0.3)) { searchActive.toggle() }
                    if searchActive { searchFocused = true } else { searchText = "" }
                } label: { Image(systemName: searchActive ? "xmark" : "magnifyingglass") }
            }
            }
            if conversation?.kind == .group && !selectionMode {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMembers = true } label: { Image(systemName: "person.2.fill") }
                }
            }
        }
        .toolbarBackground(Theme.header, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $forwardBatch) { ForwardSheet(client: client, messages: $0.messages) { exitSelection() } }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                Task { await uploadPhotoData(data) }
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            Task { await uploadDocument(url) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .confirmationDialog("Delete \(deletableSelected.count) message\(deletableSelected.count == 1 ? "" : "s") for everyone?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete for Everyone", role: .destructive) {
                for m in deletableSelected { client.deleteMessage(in: convKey, messageID: m.id) }
                exitSelection()
            }
        }
        .fullScreenCover(item: $viewerItem) { ImageViewerView(url: $0.url) }
        .sheet(item: $profileUser) { ProfileCardView(client: client, user: $0.name) }
        .sheet(isPresented: $showMembers) {
            if let conversation { membersSheet(for: conversation) }
        }
        .sensoryFeedback(trigger: sendCount) { _, _ in hapticsOn ? .impact(weight: .light) : nil }
        .sensoryFeedback(trigger: actionSheetMessage?.id) { _, _ in hapticsOn ? .selection : nil }
        .onDisappear {
            if client.activeConvKey == convKey { client.setActive(nil) }
            client.drafts[convKey] = draft.isEmpty ? nil : draft
        }
        .onAppear {
            client.setActive(convKey)
            if draft.isEmpty, let saved = client.drafts[convKey] { draft = saved }
            // Keyed off convKey directly, not `conversation?.kind` -- a DM
            // opened fresh from the People tab has no conversation entry
            // yet (PeopleTab just pushes the key string, it doesn't call
            // openDM first), so gating on the conversation already
            // existing-as-a-DM was a chicken-and-egg bug: it silently
            // never fired for exactly the case that most needs it (a
            // brand-new DM), while doing nothing for one already in the
            // chat list (where it's redundant but harmless).
            if let user = convKey.hasPrefix("dm:") ? String(convKey.dropFirst(3)) : nil {
                client.openDM(with: user)
            }
        }
        .alert("Upload Failed", isPresented: .init(get: { client.uploadError != nil }, set: { if !$0 { client.uploadError = nil } })) {
            Button("OK") { client.uploadError = nil }
        } message: {
            Text(client.uploadError ?? "")
        }
    }

    private var topbarSubtitle: String {
        let typers = client.typingUsers[convKey] ?? []
        if !typers.isEmpty {
            return "\(typers.sorted().joined(separator: ", ")) \(typers.count == 1 ? "is" : "are") typing…"
        }
        switch conversation?.kind {
        case .global: return "\(client.onlineUsers.count) online"
        case .group: return "\(conversation?.members.count ?? 0) members"
        default: return "online"
        }
    }

    private func replyBanner(for message: ChatMessage) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.accent).frame(width: 3).clipShape(.rect(cornerRadius: 2))
            VStack(alignment: .leading, spacing: 2) {
                Text(message.out ? client.myName : message.from)
                    .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.accent)
                Text(message.isImageMessage ? "Photo" : message.isDocumentMessage ? "📄 \(message.documentName)" : message.text)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Button { replyingTo = nil } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
        // Without this, the accent Rectangle has no height constraint of
        // its own, and a Shape with unconstrained height expands to fill
        // whatever space it's offered -- which cascades up through the
        // HStack and stretches the whole banner to fill all the way down
        // to the composer (confirmed live: exactly this symptom).
        // fixedSize pins the HStack to its content's intrinsic height
        // instead of accepting an unbounded one, so the Rectangle settles
        // back to matching the two-line text stack next to it.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 10)
    }

    /// "Today" / "Yesterday" / a date, shown above the first message of each
    /// calendar day (only for messages the server timestamped).
    private func dayDivider(at index: Int) -> String? {
        let messages = conversation?.messages ?? []
        guard let time = messages[index].time else { return nil }
        let cal = Calendar.current
        if index > 0, let prev = messages[index - 1].time, cal.isDate(prev, inSameDayAs: time) { return nil }
        if cal.isDateInToday(time) { return "Today" }
        if cal.isDateInYesterday(time) { return "Yesterday" }
        return time.formatted(.dateTime.weekday(.wide).month().day())
    }

    private var searchMatches: [Int] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return (conversation?.messages ?? [])
            .filter { $0.kind == .chat && !$0.deleted && !$0.isImageMessage && !$0.isAudioMessage && $0.text.localizedCaseInsensitiveContains(q) }
            .map(\.id)
    }

    private func searchBar(proxy: ScrollViewProxy) -> some View {
        let matches = searchMatches
        let hasQuery = !searchText.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField("Search in chat", text: $searchText)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onChange(of: searchText) {
                    searchIndex = max(0, searchMatches.count - 1) // newest match first
                    if let id = searchMatches[safe: searchIndex] { jump(to: id, proxy: proxy) }
                }
            if hasQuery {
                Text(matches.isEmpty ? "No results" : "\(searchIndex + 1) of \(matches.count)")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.muted)
                Button { stepSearch(-1, matches: matches, proxy: proxy) } label: { Image(systemName: "chevron.up") }
                    .disabled(matches.count < 2)
                Button { stepSearch(1, matches: matches, proxy: proxy) } label: { Image(systemName: "chevron.down") }
                    .disabled(matches.count < 2)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 12).padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func stepSearch(_ delta: Int, matches: [Int], proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        searchIndex = (searchIndex + delta + matches.count) % matches.count
        jump(to: matches[searchIndex], proxy: proxy)
    }

    private func jump(to id: Int, proxy: ScrollViewProxy) {
        guard conversation?.messages.contains(where: { $0.id == id }) == true else { return }
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
        highlightID = id
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            if highlightID == id { highlightID = nil }
        }
    }

    private func editBanner(for message: ChatMessage) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Editing message").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.accent)
                Text(message.text).font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            Button {
                editingMessage = nil
                draft = ""
            } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 10)
    }

    private func scrollToBottomButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .overlay(alignment: .topTrailing) {
            if missedCount > 0 {
                Text("\(missedCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent, in: .capsule)
                    .offset(x: 6, y: -6)
            }
        }
        .accessibilityLabel(missedCount > 0 ? "Scroll to bottom, \(missedCount) new" : "Scroll to bottom")
    }

    private var composer: some View {
        GlassEffectContainer(spacing: 10) {
        HStack(spacing: 10) {
            if recorder.isRecording {
                recordingBar
            } else {
                Button {
                    showMediaPicker = true
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showMediaPicker) {
                    MediaPickerView(client: client) { url in
                        client.sendMessage(in: convKey, text: url)
                    } onPickEmoji: { emoji in
                        draft += emoji
                    }
                }

                Menu {
                    Button { showPhotoPicker = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: { Label("Camera", systemImage: "camera") }
                    }
                    Button { showFileImporter = true } label: { Label("Document (PDF)", systemImage: "doc.fill") }
                    Button { Task { await shareLocation() } } label: { Label("Location", systemImage: "location.fill") }
                } label: {
                    Image(systemName: sharingLocation ? "location.fill" : "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .buttonStyle(.plain)
                .onChange(of: photoItem) { _, item in
                    Task { await uploadPickedPhoto(item) }
                }

                TextField("Type a message", text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...5)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))
                    .onChange(of: draft) { if !draft.isEmpty { client.sendTypingPing(in: convKey) } }

                let hasDraft = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    if hasDraft { send() } else { startRecording() }
                } label: {
                    Image(systemName: hasDraft ? "arrow.up" : "mic.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .circle)
                }
                .buttonStyle(.plain)
            }
        }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.danger).frame(width: 10, height: 10)
            Text(formatted(recorder.elapsed)).font(.system(size: 14, weight: .medium).monospacedDigit())
            waveformView
            Button {
                _ = recorder.stop(discard: true)
            } label: {
                Image(systemName: "trash").foregroundStyle(Theme.muted)
            }
            Button {
                if let url = recorder.stop() {
                    // The server's ALLOWED_UPLOAD_TYPES only recognizes
                    // "audio/mp4" (an m4a file's real container format --
                    // it maps that Content-Type to a saved ".m4a" file
                    // itself, so this still round-trips as .m4a on the
                    // wire; "audio/m4a" isn't in its allowlist at all and
                    // was rejected outright).
                    Task { await client.uploadAndSend(fileURL: url, filename: "voice.m4a", mimeType: "audio/mp4", in: convKey) }
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    /// Bars driven by AudioRecorder.levels, which is the recorder's own
    /// live metering -- moves in real time with actual mic input rather
    /// than a canned animation.
    private var waveformView: some View {
        HStack(spacing: 3) {
            ForEach(Array(recorder.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Theme.danger)
                    .frame(width: 3, height: 4 + level * 20)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .animation(.easeOut(duration: 0.08), value: recorder.levels)
    }

    private func formatted(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func startRecording() {
        recorder.requestPermissionAndStart()
    }

    private func uploadDocument(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Copy out of the security-scoped location before the async upload.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        guard (try? FileManager.default.copyItem(at: url, to: tmp)) != nil else {
            client.uploadError = "Couldn't read that file."
            return
        }
        await client.uploadAndSend(fileURL: tmp, filename: url.lastPathComponent, mimeType: "application/pdf", in: convKey)
    }

    private func uploadPhotoData(_ data: Data) async {
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try? data.write(to: tmpURL)
        await client.uploadAndSend(fileURL: tmpURL, filename: "photo.jpg", mimeType: "image/jpeg", in: convKey)
    }

    /// Sends a Maps link (rendered as a tappable link in the bubble), the
    /// same way the web client would see any other URL.
    private func shareLocation() async {
        sharingLocation = true
        defer { sharingLocation = false }
        guard let loc = await locationFetcher.fetch() else {
            client.uploadError = "Couldn't get your location. Check Location access in Settings."
            return
        }
        let lat = String(format: "%.5f", loc.coordinate.latitude)
        let lon = String(format: "%.5f", loc.coordinate.longitude)
        client.sendMessage(in: convKey, text: "📍 My location https://maps.apple.com/?ll=\(lat),\(lon)&q=My%20Location")
    }

    private var selectedMessages: [ChatMessage] {
        (conversation?.messages ?? []).filter { selectedIDs.contains($0.id) }
    }

    private var deletableSelected: [ChatMessage] { selectedMessages.filter { $0.out && !$0.deleted } }

    private func toggleSelected(_ id: Int) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        if selectedIDs.isEmpty { exitSelection() }
    }

    private func exitSelection() {
        withAnimation(.spring(duration: 0.3)) { selectionMode = false }
        selectedIDs = []
    }

    private var selectionBar: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                Button { forwardBatch = ForwardBatch(messages: selectedMessages.filter { !$0.deleted }) } label: {
                    Label("Forward", systemImage: "arrowshape.turn.up.right.fill")
                }
                Button {
                    UIPasteboard.general.string = selectedMessages.filter { !$0.deleted }.map(\.text).joined(separator: "\n")
                    exitSelection()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc.fill")
                }
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash.fill")
                }
                .disabled(deletableSelected.isEmpty)
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 28).padding(.vertical, 14)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.bottom, 6)
    }

    private func uploadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try? data.write(to: tmpURL)
        await client.uploadAndSend(fileURL: tmpURL, filename: "photo.jpg", mimeType: "image/jpeg", in: convKey)
        photoItem = nil
    }

    private func membersSheet(for conv: Conversation) -> some View {
        let iAmOwner = conv.owner == client.myName
        let addable = client.onlineUsers.filter { $0 != client.myName && !conv.members.contains($0) }
        return NavigationStack {
            List {
                Section("\(conv.members.count) members") {
                    ForEach(conv.members, id: \.self) { user in
                        HStack(spacing: 12) {
                            Circle().fill(Theme.avatarColor(for: user)).frame(width: 32, height: 32)
                                .overlay { Text(String(user.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
                            Text(user == client.myName ? "\(user) (you)" : user)
                            Spacer()
                            if user == conv.owner {
                                Text("Owner")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Theme.accentSoft, in: .capsule)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if iAmOwner && user != conv.owner {
                                Button(role: .destructive) {
                                    client.removeMember(user, fromGroup: conv.title)
                                } label: {
                                    Label("Remove", systemImage: "person.fill.xmark")
                                }
                            }
                        }
                    }
                }
                if !addable.isEmpty {
                    Section("Add people") {
                        ForEach(addable, id: \.self) { user in
                            Button {
                                client.addMember(user, toGroup: conv.title)
                            } label: {
                                HStack(spacing: 12) {
                                    Circle().fill(Theme.avatarColor(for: user)).frame(width: 32, height: 32)
                                        .overlay { Text(String(user.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
                                    Text(user).foregroundStyle(Theme.text)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Leave Group", role: .destructive) {
                        client.leaveGroup(conv.title)
                        showMembers = false
                    }
                }
            }
            .navigationTitle(conv.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showMembers = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() {
        let text = draft
        draft = ""
        sendCount += 1
        if let editing = editingMessage {
            editingMessage = nil
            if text.trimmingCharacters(in: .whitespacesAndNewlines) != editing.text {
                client.editMessage(in: convKey, messageID: editing.id, newText: text)
            }
            return
        }
        client.sendMessage(in: convKey, text: text, replyTo: replyingTo?.id)
        replyingTo = nil
    }
}

private struct ViewerItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct UserRef: Identifiable {
    let name: String
    var id: String { name }
}

/// Full-screen photo/GIF viewer: pinch to zoom, double-tap to reset, with
/// Liquid Glass close and share controls floating over the image.
private struct ImageViewerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var saveState: SaveState = .idle

    private enum SaveState { case idle, saving, saved, failed }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if url.isLikelyAnimated {
                    AnimatedGIFView(url: url).aspectRatio(contentMode: .fit)
                } else {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().aspectRatio(contentMode: .fit)
                        case .failure: Image(systemName: "photo").font(.largeTitle).foregroundStyle(.white.opacity(0.6))
                        default: ProgressView().tint(.white)
                        }
                    }
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { scale = max(1, baseScale * $0.magnification) }
                    .onEnded { _ in
                        baseScale = scale
                        if scale <= 1.01 { reset() }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { if scale > 1 { offset = CGSize(width: baseOffset.width + $0.translation.width, height: baseOffset.height + $0.translation.height) } }
                    .onEnded { _ in baseOffset = offset }
            )
            .onTapGesture(count: 2) { withAnimation(.spring(duration: 0.3)) { if scale > 1 { reset() } else { scale = 2.5; baseScale = 2.5 } } }
        }
        .overlay(alignment: .top) {
            GlassEffectContainer(spacing: 12) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    Spacer()
                    Button { Task { await save() } } label: {
                        Group {
                            switch saveState {
                            case .idle: Image(systemName: "arrow.down.to.line")
                            case .saving: ProgressView().tint(.white)
                            case .saved: Image(systemName: "checkmark")
                            case .failed: Image(systemName: "exclamationmark.triangle")
                            }
                        }
                        .font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                    .disabled(saveState == .saving || saveState == .saved)
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 15, weight: .semibold)).frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.top, 8)
        }
        .statusBarHidden()
    }

    /// Saves the original bytes (so GIFs stay animated) to the photo library.
    private func save() async {
        saveState = .saving
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { saveState = .failed; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            saveState = .saved
        } catch {
            saveState = .failed
        }
    }

    private func reset() {
        withAnimation(.spring(duration: 0.3)) {
            scale = 1; baseScale = 1; offset = .zero; baseOffset = .zero
        }
    }
}

/// Tap an avatar in a chat to see who that is: photo, status, online state.
private struct ProfileCardView: View {
    @Bindable var client: ChatClient
    let user: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let profile = client.profiles[user]
        let isOnline = client.onlineUsers.contains(user)
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.avatarColor(for: user))
                if let avatar = profile?.avatar, let url = URL(string: avatar) {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Text(String(user.prefix(1)).uppercased()).font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                        }
                    }
                    .clipShape(.circle)
                } else {
                    Text(String(user.prefix(1)).uppercased()).font(.system(size: 40, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 100, height: 100)

            Text(user == client.myName ? "\(user) (you)" : user)
                .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)

            HStack(spacing: 6) {
                Circle().fill(isOnline ? .green : Theme.muted).frame(width: 8, height: 8)
                Text(isOnline ? "Online" : "Offline").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }

            if user != client.myName {
                Button(role: client.blockedUsers.contains(user) ? nil : .destructive) {
                    client.toggleBlock(user)
                } label: {
                    Label(client.blockedUsers.contains(user) ? "Unblock" : "Block \(user)", systemImage: client.blockedUsers.contains(user) ? "hand.raised.slash" : "hand.raised.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            }

            if let status = profile?.status, !status.isEmpty {
                Text(status)
                    .font(.system(size: 15)).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 28).padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(340), .medium])
        .presentationDragIndicator(.visible)
        .onAppear { client.fetchProfile(for: user) }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Pick one or more chats to forward a message to. Sent as a normal message
/// (DMs are still encrypted by ChatClient.sendMessage).
private struct ForwardSheet: View {
    @Bindable var client: ChatClient
    let messages: [ChatMessage]
    var onSent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List(client.conversationOrder, id: \.self) { key in
                if let conv = client.conversations[key] {
                    Button {
                        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
                    } label: {
                        HStack(spacing: 12) {
                            Circle().fill(conv.kind == .dm ? Theme.avatarColor(for: conv.title) : Theme.accent)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if conv.kind == .dm {
                                        Text(String(conv.title.prefix(1)).uppercased()).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                    } else {
                                        Image(systemName: conv.kind == .global ? "globe" : "person.3.fill").font(.system(size: 14)).foregroundStyle(.white)
                                    }
                                }
                            Text(conv.title).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: selected.contains(key) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(key) ? Theme.accent : Theme.muted)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Forward to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    Button {
                        for key in client.conversationOrder where selected.contains(key) {
                            for message in messages { client.sendMessage(in: key, text: message.text) }
                        }
                        onSent()
                        dismiss()
                    } label: {
                        Label("Send to \(selected.count)", systemImage: "paperplane.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .padding(.horizontal, 20).padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: selected.isEmpty)
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ForwardBatch: Identifiable {
    let id = UUID()
    let messages: [ChatMessage]
}

/// Camera capture via the system picker (only offered on devices that have one).
private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
                parent.onImage(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// One-shot "where am I" lookup for sharing a location message.
@MainActor
private final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func fetch() async -> CLLocation? {
        manager.delegate = self
        return await withCheckedContinuation { c in
            continuation = c
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            default: finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.continuation != nil else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.requestLocation()
            } else if status != .notDetermined {
                self.finish(nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
