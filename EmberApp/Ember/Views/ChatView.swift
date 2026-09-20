import SwiftUI
import UIKit
import PhotosUI

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

    private var conversation: Conversation? { client.conversations[convKey] }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(conversation?.messages ?? []) { message in
                                MessageBubbleView(
                                    message: message,
                                    lookupMessage: client.lookupMessage,
                                    onLongPress: { actionSheetMessage = message },
                                    onSwipeReply: { replyingTo = message }
                                )
                                .id(message.id)
                                .padding(.horizontal, 14)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: conversation?.messages.count) {
                        guard let last = conversation?.messages.last else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }

                if let replyingTo {
                    replyBanner(for: replyingTo)
                }

                composer
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
                VStack(spacing: 1) {
                    Text(conversation?.title ?? "").font(.system(size: 15, weight: .semibold))
                    Text(topbarSubtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if conversation?.kind == .group {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showMembers = true } label: { Image(systemName: "person.2.fill") }
                }
            }
        }
        .toolbarBackground(Theme.header, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showMembers) {
            if let conversation { membersSheet(for: conversation) }
        }
        .onAppear {
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
                Text(message.isImageMessage ? "Photo" : message.text)
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
        .background(Theme.bg)
    }

    private var composer: some View {
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
                        .frame(width: 36, height: 36)
                }
                .sheet(isPresented: $showMediaPicker) {
                    MediaPickerView(client: client) { url in
                        client.sendMessage(in: convKey, text: url)
                    } onPickEmoji: { emoji in
                        draft += emoji
                    }
                }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 19))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 36, height: 36)
                }
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
                        .background(Theme.accentGradient, in: .circle)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.bg)
    }

    private var recordingBar: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.danger).frame(width: 10, height: 10)
            Text(formatted(recorder.elapsed)).font(.system(size: 14, weight: .medium).monospacedDigit())
            Spacer()
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

    private func formatted(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func startRecording() {
        recorder.requestPermissionAndStart()
    }

    private func uploadPickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self) else { return }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try? data.write(to: tmpURL)
        await client.uploadAndSend(fileURL: tmpURL, filename: "photo.jpg", mimeType: "image/jpeg", in: convKey)
        photoItem = nil
    }

    private func membersSheet(for conv: Conversation) -> some View {
        NavigationStack {
            List {
                ForEach(conv.members, id: \.self) { user in
                    HStack(spacing: 12) {
                        Circle().fill(Theme.avatarColor(for: user)).frame(width: 32, height: 32)
                            .overlay { Text(String(user.prefix(1)).uppercased()).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white) }
                        Text(user == client.myName ? "\(user) (you)" : user)
                    }
                }
                Button("Leave Group", role: .destructive) {
                    client.leaveGroup(conv.title)
                    showMembers = false
                }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showMembers = false } } }
        }
        .presentationDetents([.medium])
    }

    private func send() {
        let text = draft
        draft = ""
        client.sendMessage(in: convKey, text: text, replyTo: replyingTo?.id)
        replyingTo = nil
    }
}
