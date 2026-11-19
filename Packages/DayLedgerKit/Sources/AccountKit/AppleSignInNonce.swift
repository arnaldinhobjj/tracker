import CryptoKit
import Foundation
import Networking

/// Sign in with Apple nonce: the request carries `sha256(raw)`, Supabase gets `raw` and checks
/// that Apple's identity token contains its hash, so a stolen token can't be replayed.
public enum AppleSignInNonce {
    private static let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

    /// A random nonce from the system's cryptographically secure generator.
    public static func makeRawNonce(length: Int = 32) -> String {
        precondition(length > 0)
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset.randomElement(using: &generator)! })
    }

    /// Lower-case hex SHA-256, the format Apple and Supabase expect.
    public static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// PKCE helpers (RFC 7636) for Supabase's `grant_type=pkce`.
enum SupabasePKCE {
    static func makeVerifier() -> String {
        OAuthCallback.randomURLSafeString(length: 64)
    }

    /// S256 challenge: base64url(SHA256(verifier)) without padding.
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
