import Foundation
import IslandEngine
import JuiceCore
import OpenIslandCore

/// "Add by hand" (P938): the exact lines Connect would have written into a file Juice will not edit (a link, or JSON
/// with comments), built by the same installer from an empty file, so they match what Connect writes. Nothing is read.
enum AgentSnippets {
    /// The lines for `file` in a Claude or Codex folder: the `"hooks"` member of settings.json or hooks.json, ready to
    /// paste inside the file's outer braces, or Codex's feature switch for config.toml. nil for a file it does not know.
    static func profile(_ provider: Provider, file: String, helperPath: String) -> String? {
        switch (provider, file) {
        case (.claude, "settings.json"), (.codex, "hooks.json"):
            // The entries Connect writes (`HookFileEdits`, P916), with the command Connect writes.
            let quoted = AgentHookTable.shellQuote(helperPath)
            let command = provider == .claude ? "\(quoted) --source claude" : quoted
            let hooks = HookFileEdits.hooksObject(ExpectedHookEntries.entries(for: provider), command: command, layout: .claudeGroups)
            return JSONFragment.quoted("hooks") + ": " + hooks.render(indent: "  ")
        case (.codex, "config.toml"):
            return "[features]\n\(CodexHooksFeatureFlagKey.current.rawValue) = true"
        default:
            return nil
        }
    }

    /// `{ "hooks" : { … } }` as its one member, `"hooks" : { … }`, two spaces less indented. Written again with its
    /// slashes plain (`/Users/…`, not `\/Users\/…`), which reads the same to any JSON reader and is what a person types.
    static func member(_ data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any],
              let plain = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: plain, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        guard lines.first == "{", lines.last == "}", lines.count > 2 else { return nil }
        lines.removeFirst()
        lines.removeLast()
        return lines.map { $0.hasPrefix("  ") ? String($0.dropFirst(2)) : $0 }.joined(separator: "\n")
    }
}
