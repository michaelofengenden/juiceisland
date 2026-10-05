import Foundation
import IslandEngine
import IslandHookNotes
import JuiceCore

/// Settings › Diagnostics › Report a Bug, the public flavor's (P1065 to P1067): the public repository's bug form
/// (`.github/ISSUE_TEMPLATE/bug.yml`) opened in the browser with its Agent, Terminal, macOS and version fields filled and
/// Copy Report's redacted text in its Report field. Nothing is sent: the owner reads the form in the browser and sends it
/// there, or not. A report too long for a link is cut by whole lines, with one line saying the whole of it was copied,
/// and the whole of it goes to the clipboard. The private app keeps Copy Report alone. Pure, so the link is tested.
enum BugReport {
    /// The longest link it opens, in bytes: GitHub refuses much longer ones (about 8 KB), and some browsers cut them.
    static let maxLength = 7_000
    /// The form's file in the public repository (`docs/public/github/ISSUE_TEMPLATE/bug.yml`).
    static let template = "bug.yml"
    /// The line that ends a cut report.
    static let cutLine = "The report was cut to fit. The whole of it was copied: paste it here in place of this one."

    /// The form's Agent option for the session the owner worked in last: its exact words, else "Another agent"; with no
    /// session at all, the form's "None" option.
    static func agentOption(_ agent: GlyphPalette.Agent?) -> String {
        guard let agent else { return "None (usage, money or the app itself)" }
        let kind: AgentKind
        switch agent {
        case .claude: kind = .claude
        case .codex: kind = .codex
        case let .other(tool): kind = AgentKind(tool: tool)
        case let .kind(own): kind = own
        }
        switch kind {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .copilot: return "Copilot CLI"
        case .cursor: return "Cursor"
        case .qwen: return "Qwen Code"
        case .devin: return "Devin"
        case .kilo: return "Kilo"
        case .qoder: return "Qoder"
        case .codebuddy: return "CodeBuddy"
        case .factory: return "Factory Droid"
        case .kimi: return "Kimi Code"
        // Every other agent of the table by its row's name, as the form lists it (P979).
        default: return AgentHookTable.spec(kind)?.name ?? "Another agent"
        }
    }

    /// The form's Terminal option for that session's host tag ("iTerm" is the form's "iTerm2"); a host the form does not
    /// list is "Another one", no session "Does not matter here".
    static func terminalOption(host: String?, hasSession: Bool) -> String {
        guard hasSession else { return "Does not matter here" }
        guard let host else { return "Another one" }
        let options = ["Terminal", "iTerm2", "Ghostty", "Warp", "WezTerm", "cmux", "VS Code", "Cursor", "Zed"]
        if host == "iTerm" { return "iTerm2" }
        return options.first { $0.caseInsensitiveCompare(host) == .orderedSame } ?? "Another one"
    }

    /// "26.1, Apple silicon", as the form's placeholder has it.
    static func macOSLine(_ version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                          appleSilicon: Bool = Self.isAppleSilicon) -> String {
        let number = version.patchVersion > 0 ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
                                              : "\(version.majorVersion).\(version.minorVersion)"
        return number + (appleSilicon ? ", Apple silicon" : ", Intel")
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// The session the owner worked in last (the newest row), whose agent and terminal the form gets.
    static func lastSession(_ rows: [SessionRow]) -> SessionRow? { rows.max { $0.updatedAt < $1.updatedAt } }

    /// The link to open, and whether the report was cut (then the whole of it goes to the clipboard).
    struct Link: Equatable {
        var url: URL
        var cut: Bool
    }

    /// The bug form of `repo` (`owner/name`) with its fields filled. The report is cut by whole lines, keeping its
    /// start, so the link stays within `maxLength`; a cut report ends with `cutLine`.
    static func link(repo: String, agent: String, terminal: String, macOS: String, version: String?, report: String,
                     maxLength: Int = maxLength) -> Link? {
        guard AppFlavor.isRepo(repo) else { return nil }
        var fields: [(String, String)] = [("template", template), ("agent", agent), ("terminal", terminal), ("macos", macOS)]
        if let version, !version.isEmpty { fields.append(("version", version)) }
        let base = "https://github.com/\(repo)/issues/new?" + fields.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        let room = maxLength - base.utf8.count - "&report=".utf8.count
        var text = report, cut = false
        if encode(text).utf8.count > room {
            cut = true
            var kept: [Substring] = []
            for line in report.split(separator: "\n", omittingEmptySubsequences: false) {
                let next = (kept + [line]).joined(separator: "\n") + "\n\n" + cutLine
                guard encode(next).utf8.count <= room else { break }
                kept.append(line)
            }
            text = (kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n\n") + cutLine
        }
        guard let url = URL(string: base + "&report=" + encode(text)) else { return nil }
        return Link(url: url, cut: cut)
    }

    /// Percent-encoding for a query value: only unreserved characters stay, so `&`, `=`, `+` and `#` in a report never
    /// break the link or turn into spaces.
    static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)..<Unicode.Scalar(128)))
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
