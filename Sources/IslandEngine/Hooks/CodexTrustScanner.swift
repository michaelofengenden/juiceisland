import Foundation

/// Reads which Codex hook entries the user has approved with `/hooks`. Codex records each approval as a
/// `[hooks.state."<hooks.json path>:<event>:<group>:<hook>"]` table holding a `trusted_hash` line. Only the table
/// names and the presence of that line are read: hash values are never read, compared or written.
enum CodexTrustScanner {
    static func trustedKeys(inConfig contents: String) -> Set<String> {
        var trusted: Set<String> = []
        var current: String?
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let prefix = "[hooks.state.\""
                let suffix = "\"]"
                if line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count {
                    current = String(line.dropFirst(prefix.count).dropLast(suffix.count))
                } else {
                    current = nil
                }
            } else if let key = current, line.hasPrefix("trusted_hash") {
                trusted.insert(key)
            }
        }
        return trusted
    }

    static func key(hooksFile: String, event: String, group: Int, hook: Int) -> String {
        "\(hooksFile):\(snakeCase(event)):\(group):\(hook)"
    }

    /// `PermissionRequest` → `permission_request`.
    static func snakeCase(_ event: String) -> String {
        var result = ""
        for character in event {
            if character.isUppercase, !result.isEmpty { result.append("_") }
            result.append(contentsOf: character.lowercased())
        }
        return result
    }
}
