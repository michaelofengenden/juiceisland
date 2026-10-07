import AppKit
@testable import IslandEngine
import IslandHookNotes
import JuiceCore
import OpenIslandCore
import Testing
@testable import JuiceIslandUI

/// Wave 3's app lane: Settings › Accounts › Add Folder… (P1055 to P1057), Settings › Diagnostics › Report a Bug in the
/// public flavor (P1065 to P1067), and the motion A/B knobs hidden from the public flavor (P1060, P1061). Temporary homes,
/// fixture folders and the fake readers only: no CLI runs, nothing is opened or sent.
@MainActor
@Suite(.serialized)
struct AddFolderTests {
    typealias F = LiveFakes

    /// A folder at `path` holding the given files (names only; each file empty).
    static func folder(_ path: String, _ files: [String]) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        for file in files { FileManager.default.createFile(atPath: path + "/" + file, contents: Data()) }
    }

    /// The found folders' rule, at any path: which files exist, nothing opened. A folder found by name in the home folder is
    /// told from one only Add Folder… brings in.
    @Test func aFolderAnywhereIsAProfileByTheFoundFoldersRule() throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let fork = home + "/tools/claude-fork", second = home + "/work/codex-second", both = home + "/both", empty = home + "/empty"
        try Self.folder(fork, [".claude.json"])
        try Self.folder(second, ["config.toml"])
        try Self.folder(both, [".claude.json", "config.toml"])
        try Self.folder(empty, [])
        #expect(ProfileFolderDiscovery.providers(ofFolderAt: fork) == [.claude])
        #expect(ProfileFolderDiscovery.providers(ofFolderAt: second) == [.codex])
        #expect(ProfileFolderDiscovery.providers(ofFolderAt: both) == [.claude, .codex])
        #expect(ProfileFolderDiscovery.providers(ofFolderAt: empty).isEmpty)
        #expect(ProfileFolderDiscovery.providers(ofFolderAt: home + "/missing").isEmpty)
        #expect(ProfileFolderDiscovery.providers(ofFolderAt: fork + "/.claude.json").isEmpty)
        #expect(ProfileFolderDiscovery.isFoundByName(home + "/.claude-work", home: home))
        #expect(ProfileFolderDiscovery.isFoundByName(home + "/.codex", home: home))
        #expect(!ProfileFolderDiscovery.isFoundByName(fork, home: home))
        #expect(!ProfileFolderDiscovery.isFoundByName(home + "/other/.claude-work", home: home))
    }

    /// Add Folder… keeps the folder by its path in the account list, and only that: it is asked who is signed in and read
    /// as any folder, offers its session hooks' Install, and can be stopped, forgotten and added back. A folder that is
    /// neither, both, or listed already is refused with a word; nothing is added while standalone Juice runs.
    @Test func addFolderKeepsAFolderAnywhereByItsPath() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let fork = home + "/tools/claude-fork", both = home + "/both", empty = home + "/empty"
        try Self.folder(fork, [".claude.json"])
        try Self.folder(both, [".claude.json", "auth.json"])
        try Self.folder(empty, [])
        try fakes.writeStore(accounts: [F.work])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()

        #expect(model.addFolder(at: empty) == .failure(.notAProfile))
        #expect(model.addFolder(at: both) == .failure(.both))
        let added = try model.addFolder(at: fork + "/").get()
        #expect(added.provider == .claude && added.folder == fork && added.alias == "claude-fork" && added.monitored)
        #expect(added.knownEmail == nil && model.added.contains(added.id))
        #expect(model.addFolder(at: fork) == .failure(.listed))
        let stored = AccountsStore(fileURL: fakes.directory.appendingPathComponent("accounts.json"))
        stored.load()
        #expect(stored.accounts.map(\.folder) == [F.work.folder, fork])
        // Only the path and its alias are kept: nothing read from inside the folder.
        let bytes = try String(contentsOf: fakes.directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(!bytes.contains("claude.json") && !bytes.contains("token"))
        await model.settle()
        #expect(fakes.entries.contains("auth \(fork)"))

        #expect(model.canForget(provider: .claude, folder: fork))
        model.forget(added.id)
        #expect(model.account(id: added.id) == nil && !model.discovered.contains { $0.folder == fork })
        #expect(try model.addFolder(at: fork).get().id == added.id)
        #expect(model.account(id: added.id)?.monitored == true)
        model.stopMonitoring(added.id)
        #expect(model.discovered.contains { $0.folder == fork })
        #expect(try model.addFolder(at: fork).get().monitored)

        #expect(LiveAccountsText.addFolder(.notAProfile) == "No Claude or Codex files there")
        #expect(LiveAccountsText.addFolder(.both) == "Holds both Claude and Codex files")
        #expect(LiveAccountsText.addFolder(.listed) == "Already in the list")
    }

    /// W3R-2: Claude Code keeps its default config at `~/.claude.json`, in the home folder itself, so the home folder
    /// passes the found folders' rule. The panel opens there, and Add with nothing picked returns it. It is refused, as
    /// is any folder above it, so no read or sign-in ever runs with CLAUDE_CONFIG_DIR set to the home folder.
    @Test func addFolderRefusesTheHomeFolderAndAnyFolderAboveIt() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        try Self.folder(home, [".claude.json"])
        #expect(ProfileFolderDiscovery.providers(ofFolderAt: home) == [.claude])
        try fakes.writeStore(accounts: [F.work])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()

        #expect(model.addFolder(at: home) == .failure(.home))
        #expect(model.addFolder(at: home + "/") == .failure(.home))
        #expect(model.addFolder(at: home + "/tools/..") == .failure(.home))
        let above = (home as NSString).deletingLastPathComponent
        try Self.folder(above, [".claude.json"])
        #expect(model.addFolder(at: above) == .failure(.aboveHome))
        #expect(model.addFolder(at: "/") == .failure(.aboveHome))
        #expect(!model.accounts.contains { $0.folder == home || $0.folder == above })
        #expect(LiveAccountsText.addFolder(.home) == "That is your home folder, not a config folder")
        #expect(LiveAccountsText.addFolder(.aboveHome) == "That holds your home folder, not a config folder")
        // A folder inside the home folder is still taken.
        let fork = home + "/tools/claude-fork"
        try Self.folder(fork, [".claude.json"])
        #expect(try model.addFolder(at: fork).get().folder == fork)
    }
}

@MainActor
@Suite(.serialized)
struct ReportBugTests {
    static let repo = "someone/juice-app"

    /// The form's own options, word for word: the agent and terminal of the session the owner worked in last.
    @Test func theFieldsAreTheFormsOwnOptions() {
        #expect(BugReport.agentOption(.claude) == "Claude Code")
        #expect(BugReport.agentOption(.codex) == "Codex")
        #expect(BugReport.agentOption(.other(.openCode)) == "OpenCode")
        #expect(BugReport.agentOption(.other(.cursor)) == "Cursor")
        #expect(BugReport.agentOption(.other(.qwenCode)) == "Qwen Code")
        #expect(BugReport.agentOption(.kind(.copilot)) == "Copilot CLI")
        #expect(BugReport.agentOption(.kind(.devin)) == "Devin")
        #expect(BugReport.agentOption(.kind(.kilo)) == "Kilo")
        #expect(BugReport.agentOption(.other(.geminiCLI)) == "Gemini CLI")
        // Any agent neither the form nor the table lists is "Another agent".
        for tool in AgentTool.allCases where ![.claudeCode, .codex, .openCode].contains(tool) && AgentHookTable.spec(AgentKind(tool: tool)) == nil {
            #expect(BugReport.agentOption(.other(tool)) == "Another agent", "\(tool)")
        }
        #expect(BugReport.agentOption(nil) == "None (usage, money or the app itself)")
        #expect(BugReport.terminalOption(host: "Ghostty", hasSession: true) == "Ghostty")
        #expect(BugReport.terminalOption(host: "iTerm", hasSession: true) == "iTerm2")
        #expect(BugReport.terminalOption(host: "Codex.app", hasSession: true) == "Another one")
        #expect(BugReport.terminalOption(host: nil, hasSession: true) == "Another one")
        #expect(BugReport.terminalOption(host: nil, hasSession: false) == "Does not matter here")
        #expect(BugReport.macOSLine(OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0), appleSilicon: true)
                == "26.1, Apple silicon")
        #expect(BugReport.macOSLine(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 2), appleSilicon: false)
                == "27.0.2, Intel")
        // Every option it can give is one the public form lists.
        let form = (try? String(contentsOf: ReadmeAgentGridTests.issueForms.appendingPathComponent("bug.yml"), encoding: .utf8)) ?? ""
        for option in ["Claude Code", "Codex", "OpenCode", "Copilot CLI", "Cursor", "Qwen Code", "Devin", "Kilo", "Another agent",
                       "None (usage, money or the app itself)", "Ghostty", "iTerm2", "Another one", "Does not matter here"] {
            #expect(form.contains("        - \(option)\n"), "\(option)")
        }
        for id in ["id: agent", "id: terminal", "id: macos", "id: version", "id: report"] { #expect(form.contains(id), "\(id)") }
    }

    /// The link: the public repository's bug form, its fields filled, every value encoded so `&`, `=`, `+` and `#` in a
    /// report stay text; nothing else.
    @Test func theLinkFillsTheBugForm() throws {
        let report = "Juice · Build 1a2b3c4\nBridge: on & listening = yes + #1"
        let link = try #require(BugReport.link(repo: Self.repo, agent: "Claude Code", terminal: "iTerm2", macOS: "26.1, Apple silicon",
                                               version: "0.4.0", report: report))
        #expect(!link.cut)
        let parts = try #require(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https" && parts.host == "github.com" && parts.path == "/someone/juice-app/issues/new")
        let fields = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(fields == ["template": "bug.yml", "agent": "Claude Code", "terminal": "iTerm2", "macos": "26.1, Apple silicon",
                           "version": "0.4.0", "report": report])
        #expect(BugReport.link(repo: "not a repo", agent: "", terminal: "", macOS: "", version: nil, report: "") == nil)
    }

    /// A report too long for a link is cut by whole lines from its end, with the line that says the whole was copied;
    /// the link stays within its length.
    @Test func aLongReportIsCutByWholeLinesWithALineSayingItWasCopied() throws {
        let lines = (1...400).map { "  Claude Work \($0): read 12:00, next 12:05, status fine" }
        let report = lines.joined(separator: "\n")
        let link = try #require(BugReport.link(repo: Self.repo, agent: "Codex", terminal: "Ghostty", macOS: "26.1, Apple silicon",
                                               version: "0.4.0", report: report))
        #expect(link.cut && link.url.absoluteString.utf8.count <= BugReport.maxLength)
        let parts = try #require(URLComponents(url: link.url, resolvingAgainstBaseURL: false))
        let sent = try #require(parts.queryItems?.first { $0.name == "report" }?.value)
        #expect(sent.hasSuffix("\n\n" + BugReport.cutLine) && sent.hasPrefix(lines[0] + "\n"))
        let kept = sent.dropLast(BugReport.cutLine.count + 2).split(separator: "\n").map(String.init)
        #expect(!kept.isEmpty && kept == Array(lines.prefix(kept.count)))
        #expect(BugReport.cutLine == "The report was cut to fit. The whole of it was copied: paste it here in place of this one.")
    }

    /// Public flavor only, and only when the build names its repository; the private app keeps Copy Report alone.
    @Test func onlyThePublicFlavorReportsABug() {
        #expect(DiagnosticsText.reportBugRepo(.private) == nil)
        #expect(DiagnosticsText.reportBugRepo(PublicFlavorTests.publicFlavor) == "michaelofengenden/juiceisland")
        let noRepo = AppFlavor(kind: .public, productName: "Juice", bundleIdentifier: PublicFlavorTests.publicID)
        #expect(DiagnosticsText.reportBugRepo(noRepo) == nil)
        let rows = [DStub.row("a", .codex, .done), DStub.row("b", .claude, .running)]
        var newest = rows
        newest[1].updatedAt = rows[0].updatedAt.addingTimeInterval(60)
        #expect(BugReport.lastSession(newest)?.id == "b" && BugReport.lastSession([]) == nil)
    }
}

/// P1060, P1061: Island › Motion and Diagnostics' motion tools are the owner's A/B knobs. The private flavor keeps them as
/// they are; the public flavor shows neither and runs on their defaults; Hover stays in both.
@MainActor
@Suite(.serialized)
struct PublicMotionKnobsTests {
    @Test func thePrivateFlavorKeepsTheKnobsAndThePublicOneHidesThem() throws {
        #expect(IslandPaneText.showsMotionRow(reduceMotion: false, flavor: .private))
        #expect(!IslandPaneText.showsMotionRow(reduceMotion: true, flavor: .private))
        #expect(!IslandPaneText.showsMotionRow(reduceMotion: false, flavor: PublicFlavorTests.publicFlavor))
        #expect(DiagnosticsText.showsMotionTools(.private))
        #expect(!DiagnosticsText.showsMotionTools(PublicFlavorTests.publicFlavor))

        let suite = "ji-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(MotionFeel.liquid.rawValue, forKey: AppSettings.Key.islandMotion)
        defaults.set(true, forKey: AppSettings.Key.recordIslandMotion)
        defaults.set(true, forKey: AppSettings.Key.paceIslandMotion)
        defaults.set(IslandOutline.swiftUI.rawValue, forKey: AppSettings.Key.islandOutline)
        defaults.set(HoverFeel.calm.rawValue, forKey: AppSettings.Key.islandHover)
        let mine = AppSettings(defaults: defaults, identity: .development, domain: suite, flavor: .private)
        #expect(mine.islandMotion == .liquid && mine.recordIslandMotion && mine.paceIslandMotion && mine.islandOutline == .swiftUI)
        let theirs = AppSettings(defaults: defaults, identity: .development, domain: suite, flavor: PublicFlavorTests.publicFlavor)
        #expect(theirs.islandMotion == .refined && !theirs.recordIslandMotion && !theirs.paceIslandMotion)
        #expect(theirs.islandOutline == AppSettings.defaultOutline)
        // Hover is the public flavor's too.
        #expect(mine.islandHover == .calm && theirs.islandHover == .calm)
    }
}
