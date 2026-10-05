import Foundation

/// What sits at OpenCode's plugin path (`OpenCodePluginInstaller.pluginURL`), read without running anything.
public enum OpenCodePluginFile: Equatable, Sendable {
    case missing
    /// Juice Island's plugin at this revision.
    case ours(revision: Int)
    /// Open Island's plugin (a bare function): OpenCode 1 loads it, OpenCode 2 refuses it (P480).
    case openIsland
    /// Somebody else's file under that name: never replaced or removed.
    case foreign
    /// A symbolic link: a write would replace the link, not its target (P24), so nothing is written.
    case linked
    /// There, but not readable: nothing is written.
    case unreadable

    /// The file's kind from its first line.
    public static func of(contents: Data) -> OpenCodePluginFile {
        let head = String(decoding: contents.prefix(256), as: UTF8.self)
        let firstLine = head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        for marker in [OpenCodePlugin.marker, OpenCodePlugin.olderMarker] where firstLine.hasPrefix(marker) {
            let digits = firstLine.dropFirst(marker.count).prefix { $0.isNumber }
            return Int(digits).map { .ours(revision: $0) } ?? .foreign
        }
        if firstLine.hasPrefix(OpenCodePlugin.openIslandMarker) { return .openIsland }
        return .foreign
    }

    /// Juice Island's or Open Island's: a click may replace or remove it.
    public var isIslandPlugin: Bool {
        switch self {
        case .ours, .openIsland: true
        default: false
        }
    }
}

/// The installed OpenCode's version, from the first line of `opencode --version` ("1.18.33", "2.0.18", or with a name
/// before it).
public struct OpenCodeVersion: Equatable, Sendable, Comparable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(output: String) {
        let line = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        for token in line.split(whereSeparator: { $0.isWhitespace }) {
            var text = Substring(token)
            if text.first == "v" { text = text.dropFirst() }
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { continue }
            let patch = parts.count > 2 ? Int(parts[2].prefix { $0.isNumber }) ?? 0 : 0
            self.init(major: major, minor: minor, patch: patch)
            return
        }
        return nil
    }

    public var text: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: OpenCodeVersion, rhs: OpenCodeVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The one button Setup's OpenCode row may show.
public enum OpenCodePluginAction: Equatable, Sendable {
    case install, update, remove
}

/// Setup's OpenCode row from the file and the installed version (nil when `opencode` was not found or not asked yet):
/// its word, whether it is a problem, its button, or why it has none. Pure.
public struct OpenCodePluginChoice: Equatable, Sendable {
    public var word: String
    public var amber: Bool
    public var action: OpenCodePluginAction?
    /// Why there is no button, in a few words; nil when there is one.
    public var refusal: String?

    /// Juice's plugin has a file of its own (P934): Open Island running refuses nothing here.
    public static func of(_ file: OpenCodePluginFile, version: OpenCodeVersion?) -> OpenCodePluginChoice {
        let choice: OpenCodePluginChoice
        switch file {
        case .missing:
            choice = OpenCodePluginChoice(word: "Not installed", amber: false, action: .install)
        case let .ours(revision) where revision == OpenCodePlugin.revision:
            choice = OpenCodePluginChoice(word: "Installed", amber: false, action: .remove)
        case let .ours(revision) where revision < OpenCodePlugin.revision:
            // It works with both APIs; this build's has what was fixed since.
            choice = OpenCodePluginChoice(word: "Older than this build", amber: false, action: .update)
        case .ours:
            choice = OpenCodePluginChoice(word: "Newer than this build", amber: false, action: .remove)
        case .openIsland:
            // Open Island's plugin works with OpenCode 1 only: under OpenCode 2 nothing reaches the island (P480).
            let other = (version?.major ?? 1) >= 2
            choice = OpenCodePluginChoice(word: other ? "For OpenCode 1" : "Open Island's", amber: other, action: .update)
        case .foreign:
            choice = OpenCodePluginChoice(word: "Another plugin's file", amber: true, action: nil, refusal: "Another plugin's file")
        case .linked:
            choice = OpenCodePluginChoice(word: "Linked file", amber: true, action: nil, refusal: "Linked file")
        case .unreadable:
            choice = OpenCodePluginChoice(word: "Unreadable file", amber: true, action: nil, refusal: "Unreadable file")
        }
        return choice
    }

    init(word: String, amber: Bool, action: OpenCodePluginAction?, refusal: String? = nil) {
        self.word = word
        self.amber = amber
        self.action = action
        self.refusal = refusal
    }
}
