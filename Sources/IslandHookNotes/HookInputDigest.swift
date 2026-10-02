import CryptoKit
import Foundation

/// A short digest of a hook's `tool_input` (note version 2, the request broker): the first 16 hex digits of a SHA-256
/// over its canonical JSON (keys sorted, slashes unescaped). It lets the engine tell that a PreToolUse, a
/// PermissionRequest and a PostToolUse are about the same call without the input ever leaving the helper in a note.
/// The helper computes it for both the note and the broker's request, so both sides use this one encoding.
public enum HookInputDigest {
    public static func of(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) else { return nil }
        return of(canonical: data)
    }

    public static func of(canonical data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
