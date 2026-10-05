import Foundation

/// Juice's hook entries in an agent's JSON config, read and edited in place (P916): every edit adds or takes out one of
/// Juice's own entries (or a member Juice added for them) and leaves every other byte as it was, so Connect then
/// Remove gives the file back byte for byte. Strict JSON only: a file with comments, a trailing comma or anything else
/// that is not JSON is refused (`JSONSpanDocument.Problem`), and its row offers "Add by hand" instead (P25, P938).
/// Pure: data in, data out. `AgentHookInstaller` and `ProfileHookManager` do the reading, backups and writing.
public enum HookFileEdits {
    public enum Problem: Error, Equatable, Sendable {
        case comments
        case invalid
        /// Read, but never written: a file Juice could not give back exactly as it was (Kimi's `config.toml` without a
        /// final newline, say; P1130). Add by hand.
        case unwritable
    }

    /// Which commands are whose.
    public struct Owners: Sendable {
        /// Juice's own command for this agent.
        public var isOurs: @Sendable (String) -> Bool
        /// Juice's older entries on Open Island's helper for this agent: replaced by Move, taken by Remove (P903). Only a
        /// Claude or Codex profile Juice set up before its own helper has any (P932).
        public var isOld: @Sendable (String) -> Bool

        /// An entry that is Juice's is never also Open Island's, whatever its helper's file name.
        public init(isOurs: @escaping @Sendable (String) -> Bool, isOld: @escaping @Sendable (String) -> Bool = { _ in false }) {
            self.isOurs = isOurs
            self.isOld = { !isOurs($0) && isOld($0) }
        }
    }

    /// What one file holds of Juice's: the expected entries that are there as Juice writes them, how many of Juice's
    /// entries are there at all (right or not), how many of Juice's older ones, and how many of anyone else's, Vibe
    /// Island's among them.
    public struct Reading: Equatable, Sendable {
        public var complete: [HookEntrySpec] = []
        public var ours = 0
        public var old = 0
        public var others = 0
        /// Of `others`, the entries whose command names Vibe Island's bridge: Connect waits until they are gone, as a profile's Install does (P904, P933).
        public var vibe = 0
        /// The file has a `"hooks"` object (Add by hand then gives the whole member to put in its place, P938).
        public var hasHooks = false

        public init(complete: [HookEntrySpec] = [], ours: Int = 0, old: Int = 0, others: Int = 0, vibe: Int = 0, hasHooks: Bool = false) {
            self.complete = complete
            self.ours = ours
            self.old = old
            self.others = others
            self.vibe = vibe
            self.hasHooks = hasHooks
        }
    }

    /// Whether a command runs Vibe Island's bridge, by the rule the profiles' inspector counts and Switch to Juice takes
    /// out by (`VibeIslandHooks.isBridge`, P955), so an entry that holds Connect back is one the switch removes.
    public static func isVibeIsland(_ command: String) -> Bool { VibeIslandHooks.isBridge(command) }

    // MARK: Entries

    /// One entry as the layout writes it: Claude's group with one hook, Copilot's command, Cursor's command.
    public static func entry(_ spec: HookEntrySpec, command: String, layout: AgentHookSpec.Layout) -> JSONFragment {
        switch layout {
        case .claudeGroups, .plugin, .claudeEvents, .kimiToml:
            var hook: [(String, JSONFragment)] = [("type", .string("command")), ("command", .string(command))]
            if let timeout = spec.timeout { hook.append(("timeout", .int(timeout))) }
            var group: [(String, JSONFragment)] = []
            if let matcher = spec.matcher { group.append(("matcher", .string(matcher))) }
            group.append(("hooks", .array([.object(hook)])))
            return .object(group)
        case .copilot:
            var hook: [(String, JSONFragment)] = [("type", .string("command")), ("bash", .string(command))]
            if let timeout = spec.timeout { hook.append(("timeoutSec", .int(timeout))) }
            return .object(hook)
        case .cursor:
            return .object([("command", .string(command))])
        case .antigravity:
            // A tool event's entry is a group with a matcher; PreInvocation's, PostInvocation's and Stop's is the handler
            // itself, and agy drops a group there (google-antigravity/antigravity-cli#925, P1105).
            var hook: [(String, JSONFragment)] = [("type", .string("command")), ("command", .string(command))]
            if let timeout = spec.timeout { hook.append(("timeout", .int(timeout))) }
            guard let matcher = spec.matcher else { return .object(hook) }
            return .object([("matcher", .string(matcher)), ("hooks", .array([.object(hook)]))])
        }
    }

    /// The `"hooks"` object with every entry, in the table's order: what a new file gets, and Add by hand's lines.
    public static func hooksObject(_ entries: [HookEntrySpec], command: String, layout: AgentHookSpec.Layout) -> JSONFragment {
        var events: [(String, JSONFragment)] = []
        for spec in entries {
            if let index = events.firstIndex(where: { $0.0 == spec.event }), case let .array(items) = events[index].1 {
                events[index].1 = .array(items + [entry(spec, command: command, layout: layout)])
            } else {
                events.append((spec.event, .array([entry(spec, command: command, layout: layout)])))
            }
        }
        return .object(events)
    }

    /// What Connect begins a file that is not there with, before its entries.
    static let newFile = Data("{}\n".utf8)

    /// Whether the layout's files carry `"version": 1` beside `"hooks"`.
    static func hasVersion(_ layout: AgentHookSpec.Layout) -> Bool { layout == .copilot || layout == .cursor }

    // MARK: Reading

    /// The entries of one file. A missing file reads as empty.
    /// `key`: the member Juice's entries sit under (`AgentHookSpec.hooksKey`): `"hooks"`, or Antigravity CLI's hook name.
    public static func read(_ data: Data?, layout: AgentHookSpec.Layout, expected: [HookEntrySpec], owners: Owners,
                            key: String = "hooks") throws -> Reading {
        if layout == .kimiToml { return try TOMLHookEdits.read(data, expected: expected, owners: owners) }
        guard let data else { return Reading() }
        let document = try parse(data)
        var reading = Reading()
        if layout == .antigravity { reading.vibe = vibeEntries(in: document.root, besides: key) }
        guard let hooks = hooksNode(document, layout: layout, key: key), hooks.kind == .object else { return reading }
        reading.hasHooks = layout != .claudeEvents || !hooks.members.isEmpty
        for member in hooks.members where member.value.kind == .array {
            for item in member.value.elements {
                for found in commands(in: item, layout: layout) {
                    if owners.isOurs(found.command) {
                        reading.ours += 1
                    } else if owners.isOld(found.command) {
                        reading.old += 1
                    } else {
                        reading.others += 1
                        if isVibeIsland(found.command) { reading.vibe += 1 }
                    }
                }
            }
        }
        reading.complete = expected.filter { spec in
            hooks.member(spec.event).map { array in
                array.kind == .array && array.elements.contains { isCorrect($0, spec: spec, layout: layout, owners: owners) }
            } ?? false
        }
        return reading
    }

    // MARK: Edits

    /// Adds Juice's entries that are missing, takes out Juice's entries that are wrong or not in `expected` and Juice's
    /// older ones on Open Island's helper, and leaves the rest. A missing file starts from `{}` and a newline, with
    /// `"version": 1` where the layout has one; a file that is there gets no `"version"` it did not have, so Remove gives
    /// it back as it was (P916).
    public static func installing(_ data: Data?, layout: AgentHookSpec.Layout, expected: [HookEntrySpec], command: String,
                                  owners: Owners, key: String = "hooks") throws -> Data {
        if layout == .kimiToml { return try TOMLHookEdits.installing(data, expected: expected, command: command, owners: owners) }
        let isNew = data == nil
        var data = data ?? newFile
        var emptied: Set<String> = []
        for _ in 0..<4_096 {
            let document = try parse(data)
            let root = document.root
            if isNew, hasVersion(layout), root.member("version") == nil {
                data = document.adding(key: "version", value: .int(1), to: root)
                continue
            }
            guard let hooks = hooksNode(document, layout: layout, key: key) else {
                data = document.adding(key: key, value: hooksObject(expected, command: command, layout: layout), to: root)
                continue
            }
            guard hooks.kind == .object else { throw Problem.invalid }
            if let next = removingFirst(in: document, hooks: hooks, layout: layout, emptied: &emptied, where: { item, event, found in
                owners.isOld(found) || (owners.isOurs(found) && !expected.contains { spec in
                    spec.event == event && isCorrect(item, spec: spec, layout: layout, owners: owners)
                })
            }) {
                data = next
                continue
            }
            if let member = hooks.members.firstIndex(where: { emptied.contains($0.key) && $0.value.kind == .array && $0.value.elements.isEmpty }) {
                emptied.remove(hooks.members[member].key)
                data = document.removing(member: member, of: hooks)
                continue
            }
            guard let missing = expected.first(where: { spec in
                !(hooks.member(spec.event).map { $0.kind == .array && $0.elements.contains { isCorrect($0, spec: spec, layout: layout, owners: owners) } } ?? false)
            }) else { return data }
            let fragment = entry(missing, command: command, layout: layout)
            if let array = hooks.member(missing.event) {
                guard array.kind == .array else { throw Problem.invalid }
                data = document.appending(fragment, to: array)
            } else {
                data = document.adding(key: missing.event, value: .array([fragment]), to: hooks)
            }
        }
        throw Problem.invalid
    }

    /// Takes out every entry of Juice's, its older ones on Open Island's helper included when `owners` counts them as
    /// Juice's (P932), and an event list or `"hooks"` left empty by that; never another's. nil: nothing of the file is
    /// left but a `"version"` Juice wrote with it, so it goes (it was Juice's from the start). Factory Droid's
    /// `hooks.json`, whose events are the whole file, is left as `{}`: whether it goes is `AgentHookInstaller`'s call,
    /// since an empty one switches off the hooks Droid would read after it (P1188).
    public static func removing(_ data: Data, layout: AgentHookSpec.Layout, owners: Owners, key: String = "hooks") throws -> Data? {
        if layout == .kimiToml { return try TOMLHookEdits.removing(data, owners: owners) }
        var data = data
        var emptied: Set<String> = []
        var changed = false
        for _ in 0..<4_096 {
            let document = try parse(data)
            let root = document.root
            guard let hooks = hooksNode(document, layout: layout, key: key), hooks.kind == .object else { break }
            if let next = removingFirst(in: document, hooks: hooks, layout: layout, emptied: &emptied, where: { _, _, found in
                owners.isOurs(found) || owners.isOld(found)
            }) {
                data = next
                changed = true
                continue
            }
            if let member = hooks.members.firstIndex(where: { emptied.contains($0.key) && $0.value.kind == .array && $0.value.elements.isEmpty }) {
                emptied.remove(hooks.members[member].key)
                data = document.removing(member: member, of: hooks)
                continue
            }
            if changed, layout != .claudeEvents, hooks.members.isEmpty, let index = root.members.firstIndex(where: { $0.key == key }) {
                data = document.removing(member: index, of: root)
            }
            break
        }
        guard changed else { return data }
        if layout == .claudeEvents { return data }
        let root = try parse(data).root
        let left = root.members.filter { !(hasVersion(layout) && $0.key == "version" && $0.value.int == 1) }
        return left.isEmpty ? nil : data
    }

    // MARK: Pieces

    /// The object the events sit in: `"hooks"`, or the whole file where the events are its top level (Factory Droid's
    /// `hooks.json`, P1126).
    static func hooksNode(_ document: JSONSpanDocument, layout: AgentHookSpec.Layout, key: String = "hooks") -> JSONSpanDocument.Node? {
        layout == .claudeEvents ? document.root : document.root.member(key)
    }

    static func parse(_ data: Data) throws -> JSONSpanDocument {
        do {
            let document = try JSONSpanDocument(data: data)
            guard document.root.kind == .object else { throw Problem.invalid }
            return document
        } catch let problem as JSONSpanDocument.Problem {
            throw problem == .comments ? Problem.comments : Problem.invalid
        }
    }

    /// The commands an entry runs, with where each sits: a Claude group's hooks (by index), Copilot's `bash` (or its
    /// `command` fallback), Cursor's `command`.
    static func commands(in item: JSONSpanDocument.Node, layout: AgentHookSpec.Layout) -> [(hook: Int?, command: String)] {
        guard item.kind == .object else { return [] }
        switch layout {
        case .claudeGroups, .plugin, .claudeEvents, .kimiToml:
            guard let hooks = item.member("hooks"), hooks.kind == .array else { return [] }
            return hooks.elements.enumerated().compactMap { index, hook in
                hook.member("command")?.text.map { (index, $0) }
            }
        case .copilot:
            return [item.member("bash")?.text ?? item.member("command")?.text].compactMap { $0.map { (nil, $0) } }
        case .cursor:
            return [item.member("command")?.text].compactMap { $0.map { (nil, $0) } }
        case .antigravity:
            if let hooks = item.member("hooks"), hooks.kind == .array {
                return hooks.elements.enumerated().compactMap { index, hook in hook.member("command")?.text.map { (index, $0) } }
            }
            return [item.member("command")?.text].compactMap { $0.map { (nil, $0) } }
        }
    }

    /// Entries naming Vibe Island's bridge under any other hook name of an Antigravity CLI `hooks.json`: agy runs every
    /// name's hooks, so they hold Connect back as they would beside Juice's own (P933, P1105).
    static func vibeEntries(in root: JSONSpanDocument.Node, besides key: String) -> Int {
        var count = 0
        for block in root.members where block.key != key && block.value.kind == .object {
            for member in block.value.members where member.value.kind == .array {
                for item in member.value.elements {
                    count += commands(in: item, layout: .antigravity).filter { isVibeIsland($0.command) }.count
                }
            }
        }
        return count
    }

    /// The entry is Juice's, for this spec, as Juice writes it: the command, the matcher and the timeout.
    static func isCorrect(_ item: JSONSpanDocument.Node, spec: HookEntrySpec, layout: AgentHookSpec.Layout, owners: Owners) -> Bool {
        guard item.kind == .object else { return false }
        switch layout {
        case .claudeGroups, .plugin, .claudeEvents, .kimiToml:
            guard item.member("matcher")?.text == spec.matcher, let hooks = item.member("hooks"), hooks.kind == .array else { return false }
            return hooks.elements.contains { hook in
                hook.member("command")?.text.map(owners.isOurs) == true && hook.member("timeout")?.int == spec.timeout
            }
        case .copilot:
            let command = item.member("bash")?.text ?? item.member("command")?.text
            return command.map(owners.isOurs) == true && item.member("timeoutSec")?.int == spec.timeout
        case .cursor:
            return item.member("command")?.text.map(owners.isOurs) == true
        case .antigravity:
            if let matcher = spec.matcher {
                guard item.member("matcher")?.text == matcher, let hooks = item.member("hooks"), hooks.kind == .array else { return false }
                return hooks.elements.contains { hook in
                    hook.member("command")?.text.map(owners.isOurs) == true && hook.member("timeout")?.int == spec.timeout
                }
            }
            return item.member("hooks") == nil && item.member("command")?.text.map(owners.isOurs) == true
                && item.member("timeout")?.int == spec.timeout
        }
    }

    /// Takes out the first entry (or, in a Claude group with other hooks too, the first hook) whose command `matches`;
    /// nil when there is none. An event list it leaves empty is noted in `emptied`.
    static func removingFirst(in document: JSONSpanDocument, hooks: JSONSpanDocument.Node, layout: AgentHookSpec.Layout,
                              emptied: inout Set<String>,
                              where matches: (JSONSpanDocument.Node, String, String) -> Bool) -> Data? {
        for member in hooks.members where member.value.kind == .array {
            let array = member.value
            for (index, item) in array.elements.enumerated() {
                for found in commands(in: item, layout: layout) where matches(item, member.key, found.command) {
                    if let hook = found.hook, let group = item.member("hooks"), group.elements.count > 1 {
                        return document.removing(element: hook, of: group)
                    }
                    if array.elements.count == 1 { emptied.insert(member.key) }
                    return document.removing(element: index, of: array)
                }
            }
        }
        return nil
    }
}
