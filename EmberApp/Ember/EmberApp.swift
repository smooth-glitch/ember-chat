import SwiftUI

@main
struct EmberApp: App {
    @State private var client = ChatClient()

    var body: some Scene {
        WindowGroup {
            RootView(client: client)
        }
    }
}

struct RootView: View {
    @Bindable var client: ChatClient
    @AppStorage("ember.appearance") private var appearance = "system"

    private var scheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some View {
        Group {
            if client.state == .connected || client.state == .reconnecting {
                ConversationListView(client: client)
                    // Bottom, above the tab bar, and only on list screens: an open
                    // chat shows "Reconnecting…" in its own header instead.
                    .overlay(alignment: .bottom) {
                        if client.state == .reconnecting && client.activeConvKey == nil {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reconnecting…").font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                            .padding(.bottom, 96)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.3), value: client.state == .reconnecting)
            } else {
                LoginView(client: client)
            }
        }
        .animation(.default, value: client.state == .connected)
        .preferredColorScheme(scheme)
        .alert("Ember", isPresented: .init(get: { client.notice != nil }, set: { if !$0 { client.notice = nil } })) {
            Button("OK") { client.notice = nil }
        } message: {
            Text(client.notice ?? "")
        }
        // Standard env-var-driven test hook, same pattern UI tests use --
        // lets a screenshot/verification pass skip manually typing a
        // username, with zero effect on a real launch from the Home
        // Screen (this key is never set outside `simctl launch --env` or
        // an Xcode scheme's env vars). Not a visible feature.
        .task {
            if let name = ProcessInfo.processInfo.environment["EMBER_AUTOJOIN"], client.state == .disconnected {
                client.connect(as: name)
            }
        }
    }
}
