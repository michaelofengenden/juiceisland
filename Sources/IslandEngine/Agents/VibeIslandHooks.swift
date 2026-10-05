import Foundation
import IslandHookNotes
import JuiceCore

/// Vibe Island's hooks in the agents' configs, found and, on Switch to Juice's click only, taken out (the owner's decision
/// B, P955 to P957). Vibe Island writes its bridge (`~/.vibe-island/bin/vibe-island-bridge`, run through `/bin/sh -c`)
/// into each agent's hooks and drops `vibe-island.js` into OpenCode's plugins. Reading never writes. Removing backs each
/// file up first, as `<name>.vibe-island-backup.<time>` beside it (never pruned, and never the name a Connect's own
/// backup takes, so the copy of the file as Vibe Island left it survives the Connect that follows), then takes out only
/// the entries whose command names its bridge and leaves every other byte; its OpenCode plugin file goes whole. A file
/// Juice will not edit (a link, comments, not JSON) is left as it is, and said.
public enum VibeIslandHooks {
    /// OpenCode's plugin Vibe Island drops, from the home folder.
    public static let openCodePlugin = ".config/opencode/plugins/vibe-island.js"

    /// A command that runs Vibe Island's bridge: its `vibe-island-bridge` by any path, or any program in its
    /// `~/.vibe-island/bin/`. Juice's own, Open Island's and anyone else's never match.
    public static func isBridge(_ command: String) -> Bool {
        let lower = command.lowercased()
        return lower.contains("vibe-island-bridge") || lower.contains("/.vibe-island/bin/")
    }

    /// Where to look: one config file, the agent it belongs to, and how its entries sit.
    public struct Place: Equatable, Sendable {
        /// The agent's name, as the first run shows it ("Claude Code", "Codex", "Cursor", "OpenCode").
        public var agent: String
        /// The agent's id in Settings › Agents ("claude", "codex", "opencode", the table's kinds).
        public var agentID: String
        public var url: URL
        /// How entries sit; `.plugin` is a file Vibe Island owns whole.
        public var layout: AgentHookSpec.Layout

        public init(agent: String, agentID: String, url: URL, layout: AgentHookSpec.Layout) {
            self.agent = agent
            self.agentID = agentID
            self.url = url
            self.layout = layout
        }
    }

    /// A file that holds Vibe Island's entries (or is its plugin).
    public struct Found: Equatable, Sendable {
        public var place: Place
        /// Its entries in the file; 1 for the plugin file.
        public var entries: Int
        /// Juice will not edit it (a link, comments, not JSON): left for the owner, never written.
        public var refused: Bool

        public init(place: Place, entries: Int, refused: Bool) {
            self.place = place
            self.entries = entries
            self.refused = refused
        }
    }

    /// Every place Vibe Island writes that Juice knows: each Claude and Codex profile's hook file, each shared file of
    /// the agents table (Cursor's `hooks.json`, Qwen's and Gemini CLI's `settings.json`, Devin's `config.json`,
    /// Antigravity CLI's `hooks.json`, …), every `.json` in Copilot's and Grok Build's hooks folders, and its OpenCode
    /// plugin. Lists names only; nothing is opened.
    public static func places(home: URL, profiles: [(provider: Provider, folder: String)],
                              fileManager: FileManager = .default) -> [Place] {
        var places: [Place] = profiles.map { profile in
            let file = profile.provider == .claude ? "settings.json" : "hooks.json"
            return Place(agent: profile.provider == .claude ? "Claude Code" : "Codex",
                         agentID: profile.provider == .claude ? "claude" : "codex",
                         url: URL(fileURLWithPath: profile.folder, isDirectory: true).appendingPathComponent(file), layout: .claudeGroups)
        }
        // Every place the agent reads, the older ones too (Factory Droid's `settings.json`, Kimi CLI's `config.toml`).
        for spec in AgentHookTable.wave1.flatMap({ [$0] + $0.elsewhere }) {
            guard case let .shared(file) = spec.place else { continue }
            places.append(Place(agent: spec.name, agentID: spec.kind.rawValue,
                                url: home.appendingPathComponent(spec.folder, isDirectory: true).appendingPathComponent(file), layout: spec.layout))
        }
        // Every `.json` in a hooks folder the agent loads whole (Copilot CLI's, Grok Build's, P1105).
        for spec in AgentHookTable.wave1 where spec.layout != .plugin {
            guard case let .owned(folder, fileExtension) = spec.place, fileExtension == "json" else { continue }
            let directory = home.appendingPathComponent(spec.folder, isDirectory: true).appendingPathComponent(folder, isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
                places.append(Place(agent: spec.name, agentID: spec.kind.rawValue, url: directory.appendingPathComponent(name),
                                    layout: spec.layout))
            }
        }
        places.append(Place(agent: "OpenCode", agentID: "opencode", url: home.appendingPathComponent(openCodePlugin), layout: .plugin))
        return places
    }

    /// Reads each place (1 MB at most) and keeps those holding Vibe Island's entries. Writes nothing.
    public static func scan(_ places: [Place]) -> [Found] {
        places.compactMap { place in
            var info = stat()
            guard lstat(place.url.path, &info) == 0 else { return nil }
            let linked = info.st_mode & S_IFMT == S_IFLNK
            if place.layout == .plugin {
                // Its plugin is its own file whole: there, it is Vibe Island's.
                return Found(place: place, entries: 1, refused: linked)
            }
            guard info.st_size <= 1 << 20, let data = try? Data(contentsOf: place.url) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            guard isBridge(text) else { return nil }
            do {
                let ours = try keys(data, layout: place.layout).reduce(0) { count, key in
                    count + (try HookFileEdits.read(data, layout: place.layout, expected: [], owners: owners, key: key)).ours
                }
                guard ours > 0 else { return nil }
                return Found(place: place, entries: ours, refused: linked)
            } catch {
                // Comments or not JSON: its lines are there, but Juice will not edit the file.
                return Found(place: place, entries: 1, refused: true)
            }
        }
    }

    /// The agents Vibe Island is connected to, by id, in the order found, each once.
    public static func agents(_ found: [Found]) -> [String] {
        var seen: Set<String> = []
        return found.map(\.place.agentID).filter { seen.insert($0).inserted }
    }

    /// What one file's removal did.
    public enum Outcome: Equatable, Sendable {
        /// Its entries came out (the plugin went); the backup holds the file as it was.
        case removed(backup: URL)
        /// Left as it was, with why in a few words.
        case left(String)
    }

    /// On Switch to Juice's click only: each file backed up, then Vibe Island's entries out (its plugin file goes whole),
    /// every other byte as it was. A file that changed into one Juice will not edit is left.
    public static func remove(_ found: [Found], now: Date = Date(), fileManager: FileManager = .default) -> [URL: Outcome] {
        var outcomes: [URL: Outcome] = [:]
        for item in found {
            let url = item.place.url
            guard !item.refused else {
                outcomes[url] = .left("Add by hand")
                continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            guard info.st_mode & S_IFMT == S_IFREG, let data = try? Data(contentsOf: url) else {
                outcomes[url] = .left("Add by hand")
                continue
            }
            let next: Data?
            if item.place.layout == .plugin {
                next = nil
            } else {
                do {
                    var left: Data? = data
                    for key in try keys(data, layout: item.place.layout) {
                        guard let current = left else { break }
                        left = try HookFileEdits.removing(current, layout: item.place.layout, owners: owners, key: key)
                    }
                    next = left
                } catch {
                    outcomes[url] = .left("Add by hand")
                    continue
                }
                if next == data { continue }
            }
            let backup = backupURL(for: url, now: now)
            do {
                try? fileManager.removeItem(at: backup)
                try fileManager.copyItem(at: url, to: backup)
                try ConfigFileWrite.write(next, to: url, backup: false, fileManager: fileManager, now: now)
                outcomes[url] = .removed(backup: backup)
            } catch {
                outcomes[url] = .left("Couldn't write it")
            }
        }
        return outcomes
    }

    /// `<name>.vibe-island-backup.<UTC time, ":" as "-">` beside the file. Never a name an agent loads: it ends in
    /// neither `.json` nor `.js`.
    public static func backupURL(for url: URL, now: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        return url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).vibe-island-backup.\(stamp)")
    }

    static let owners = HookFileEdits.Owners(isOurs: { isBridge($0) })

    /// The members whose entries are read: `"hooks"`, or every hook name of Antigravity CLI's `hooks.json`, which keeps
    /// each tool's hooks under a name of its own (P1105).
    static func keys(_ data: Data, layout: AgentHookSpec.Layout) throws -> [String] {
        guard layout == .antigravity else { return ["hooks"] }
        return try HookFileEdits.parse(data).root.members.filter { $0.value.kind == .object }.map(\.key)
    }
}
