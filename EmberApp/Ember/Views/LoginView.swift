import SwiftUI
import AuthenticationServices
import UIKit

struct LoginView: View {
    @Bindable var client: ChatClient
    @State private var username = ""
    @State private var oauthNotice: String?
    @State private var webAuthSession: ASWebAuthenticationSession?
    @FocusState private var fieldFocused: Bool
    private let presentationAnchor = PresentationAnchor()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x1C_1C2A), Color(hex: 0x2A_2860), Color(hex: 0x0A_0A10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Theme.accentGradient)
                        .frame(width: 64, height: 64)
                    Text("🔥").font(.system(size: 28))
                }
                .shadow(color: Color(hex: 0x58_56D6).opacity(0.45), radius: 16, y: 8)

                VStack(spacing: 5) {
                    Text("Ember").font(.system(size: 23, weight: .bold)).foregroundStyle(.white)
                    Text("Pick a username to join the room.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                }

                VStack(spacing: 12) {
                    // Real native flow: opens Google's actual consent page
                    // in a secure system browser sheet
                    // (ASWebAuthenticationSession), hits the same
                    // chat_oauth.erl/oauth_config.erl backend the web app
                    // uses, and gets handed back a username via the
                    // "ember://" URL scheme once chat_web.erl's
                    // complete_login/5 finishes the exchange -- see its
                    // "IsNative" branch. Falls back to an honest message
                    // if the server isn't configured or the flow fails,
                    // rather than pretending either way.
                    Button(action: startGoogleSignIn) {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                            Text("Continue with Google").font(.system(size: 15, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.glass)

                    if let oauthNotice {
                        Text(oauthNotice)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                            .transition(.opacity)
                    }

                    HStack(spacing: 10) {
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                        Text("or continue as guest")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize()
                        Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                    }
                    .padding(.vertical, 2)

                    TextField("Username", text: $username)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 13)
                        .focused($fieldFocused)
                        .submitLabel(.go)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                        .onSubmit(join)

                    Button(action: join) {
                        Text("Join chat")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                    }
                    .buttonStyle(.glass)
                    .tint(Color(hex: 0x58_56D6))
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || client.state == .connecting)

                    if case .failed(let reason) = client.state {
                        Text(reason).font(.system(size: 13)).foregroundStyle(Theme.danger)
                    }
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 26))
            }
            .padding(32)
            .frame(maxWidth: 360)
            .animation(.easeOut(duration: 0.2), value: oauthNotice)
        }
    }

    private func join() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        fieldFocused = false
        client.connect(as: name)
    }

    private func startGoogleSignIn() {
        var components = client.httpOrigin
        components.path = "/auth/google/start"
        components.queryItems = [URLQueryItem(name: "client", value: "native")]
        guard let url = components.url else { return }

        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "ember") { callbackURL, error in
            if let error {
                let authError = error as NSError
                // User just closed the sheet -- not a failure worth a message.
                if authError.code != ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    oauthNotice = "Google sign-in failed: \(error.localizedDescription)"
                }
                return
            }
            guard
                let callbackURL,
                let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                let name = items.first(where: { $0.name == "username" })?.value
            else {
                oauthNotice = "Google sign-in didn't complete — use a guest username for now."
                return
            }
            client.connect(as: name)
        }
        session.presentationContextProvider = presentationAnchor
        session.prefersEphemeralWebBrowserSession = true
        webAuthSession = session
        session.start()
    }
}

/// ASWebAuthenticationSession needs a window to present its sheet from --
/// this just hands back the app's one active window, which is all a
/// single-window iOS app has anyway.
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}
