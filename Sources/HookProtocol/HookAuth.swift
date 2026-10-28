import CryptoKit
import Foundation

/// Mutual authentication between `claudenotch-hook` and the app, over plain HTTP on 127.0.0.1.
///
/// Both sides know a secret (a 0600 file in the user's Application Support), and neither ever sends it.
/// The helper signs each request (endpoint, time, a fresh nonce, the body). The app signs its reply to that
/// nonce. So another process that grabs the port while the app isn't running learns nothing it can use,
/// and the helper ignores anything it says. The app also rejects stale or replayed requests.
public enum HookAuth {
    public static let port: UInt16 = 47852
    public static let nonceHeader = "X-ClaudeNotch-Nonce"
    public static let timeHeader = "X-ClaudeNotch-Time"
    public static let signatureHeader = "X-ClaudeNotch-Signature"
    public static let proofHeader = "X-ClaudeNotch-Proof"
    /// How far apart the two clocks may be (same machine, so mostly scheduling delay).
    public static let maxAge: TimeInterval = 60

    public static var secretFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeNotch/token")
    }

    public static func loadSecret() -> String? {
        guard let text = try? String(contentsOf: secretFile, encoding: .utf8) else { return nil }
        let secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return secret.count >= 32 ? secret : nil
    }

    public static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return hex(bytes)
    }

    /// What the helper sends with a request.
    public static func requestSignature(secret: String, path: String, time: Int, nonce: String, body: Data) -> String {
        sign(secret, "request|\(path)|\(time)|\(nonce)|\(digest(body))")
    }

    /// What the app sends back, so the helper knows the answer is genuine.
    public static func responseProof(secret: String, nonce: String, status: Int, body: Data) -> String {
        sign(secret, "response|\(nonce)|\(status)|\(digest(body))")
    }

    /// Constant-time comparison of two signatures.
    public static func matches(_ given: String?, _ expected: String) -> Bool {
        guard let given, given.utf8.count == expected.utf8.count else { return false }
        return zip(given.utf8, expected.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func sign(_ secret: String, _ message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return hex(Array(code))
    }

    private static func digest(_ data: Data) -> String {
        hex(Array(SHA256.hash(data: data)))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
