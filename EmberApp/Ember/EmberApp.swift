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
            if client.state == .connected {
                ConversationListView(client: client)
            } else {
                LoginView(client: client)
            }
        }
        .animation(.default, value: client.state == .connected)
        .preferredColorScheme(scheme)
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
