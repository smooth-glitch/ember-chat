import Foundation
import CryptoKit
import Security

/// Real end-to-end encryption for DMs -- X25519 key agreement + AES-GCM,
/// both from Apple's own CryptoKit (no hand-rolled crypto). Scope is
/// deliberately DM-only: group/global E2EE needs per-recipient encryption
/// or a shared-key-with-rotation scheme (what Signal's whole protocol is
/// for), which is a much bigger, easier-to-get-subtly-wrong undertaking --
/// see project notes for why that line was drawn here.
///
/// The server only ever sees a base64 public key (on `/pubkey`) and opaque
/// ciphertext (as ordinary DM message text) -- it cannot decrypt DMs
/// between two clients that both have a key pair.
enum CryptoBox {
    private static let keychainAccount = "ember.identity.privatekey"
    private static let keychainService = "com.ember.chat.app"

    /// Loads this device's identity key pair from the Keychain, generating
    /// and persisting a new one on first launch. Kept in the Keychain (not
    /// UserDefaults/a plain file) since this is the one secret this
    /// feature's whole security property rests on.
    static func loadOrCreateIdentity() -> Curve25519.KeyAgreement.PrivateKey {
        if let data = readKeychain(), let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        writeKeychain(key.rawRepresentation)
        return key
    }

    static func publicKeyBase64(_ privateKey: Curve25519.KeyAgreement.PrivateKey) -> String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Derives the same symmetric key both parties independently arrive at
    /// -- X25519 shared secrets are commutative (A's secret with B's
    /// pubkey == B's secret with A's pubkey), then HKDF-stretched into an
    /// AES key. `salt` is fixed and public (not a secret) -- it just
    /// domain-separates this derivation from any other use of the same
    /// shared secret.
    static func symmetricKey(myPrivate: Curve25519.KeyAgreement.PrivateKey, theirPublicBase64: String) -> SymmetricKey? {
        guard let theirData = Data(base64Encoded: theirPublicBase64),
              let theirKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirData),
              let shared = try? myPrivate.sharedSecretFromKeyAgreement(with: theirKey)
        else { return nil }
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("ember-dm-v1".utf8), sharedInfo: Data(), outputByteCount: 32)
    }

    /// Ciphertext is base64 of AES-GCM's combined (nonce+tag+ciphertext)
    /// representation, prefixed so a plaintext fallback (recipient with no
    /// published key yet) is never mistaken for real ciphertext on the
    /// receiving end.
    static let wirePrefix = "ember-e2e:"

    static func encrypt(_ plaintext: String, key: SymmetricKey) -> String? {
        guard let data = plaintext.data(using: .utf8),
              let sealed = try? AES.GCM.seal(data, using: key),
              let combined = sealed.combined
        else { return nil }
        return wirePrefix + combined.base64EncodedString()
    }

    static func decrypt(_ wireText: String, key: SymmetricKey) -> String? {
        guard wireText.hasPrefix(wirePrefix) else { return nil }
        let b64 = String(wireText.dropFirst(wirePrefix.count))
        guard let data = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: key)
        else { return nil }
        return String(data: opened, encoding: .utf8)
    }

    // MARK: - Keychain

    private static func readKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func writeKeychain(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
