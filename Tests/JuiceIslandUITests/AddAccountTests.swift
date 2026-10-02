import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Settings › Accounts' "+", Stop Monitoring and Forget, on `LiveFakes` with a temp home folder: fake login CLIs (never a
/// real login), fictional folders and example.com emails. The folders made are the only files written outside the temp
/// store, and they are inside it too.
@MainActor
@Suite(.serialized)
struct AddAccountTests {
    typealias F = LiveFakes

    private static func listing(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    /// The path the CLI is handed, as `CLIEnvironment.make` normalises it.
    private static func handed(_ folder: String) -> String {
        URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A login CLI that writes its arguments and both folder variables to `record`, then finishes.
    private static func recordingLogin(_ fakes: LiveFakes, _ name: String, record: String, then script: String = "exit 0") throws -> URL {
        try fakes.loginCLI(name, """
            printf '%s|%s|%s\\n' "$*" "${CLAUDE_CONFIG_DIR:-none}" "${CODEX_HOME:-none}" > '\(record)'
            \(script)
            """)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// "+" makes the empty folder, owner-only, adds it and runs `claude auth login` there with `CLAUDE_CONFIG_DIR`
    /// pointing at it (and the island skip switches, which every fake checks). The CLI's check names the account, and
    /// the folder becomes its row.
    @Test func plusMakesAClaudeFolderAndSignsInThere() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let record = fakes.directory.appendingPathComponent("login.txt").path
        fakes.located = [.claude: try Self.recordingLogin(fakes, "claude", record: record), .codex: URL(fileURLWithPath: "/fake/bin/codex")]
        try fakes.writeStore(accounts: [])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(model.canAddAccount(.claude) && model.list(.claude) == nil)
        model.newAccount = NewAccountDraft(provider: .claude, name: "demo")
        #expect(model.checkNewAccount("Demo", provider: .claude) == .new(folder: home + "/.claude-demo"))

        let account = try model.addAccount("Demo", provider: .claude).get()
        let folder = home + "/.claude-demo"
        #expect(account == Account(provider: .claude, folder: folder, alias: "demo"))
        #expect(model.newAccount == nil && model.added == [account.id] && model.signingIn == [account.id])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o700)
        let stored = AccountsStore(fileURL: fakes.directory.appendingPathComponent("accounts.json"))
        stored.load()
        #expect(stored.accounts == [account])
        // One flow at a time: another "+" waits for this sign-in.
        #expect(!model.canAddAccount(.codex) && model.addUnavailableReason(.codex) == "A sign-in is running")

        #expect(await Self.waitUntil { model.signingIn.isEmpty })
        #expect(model.signInCoordinator.phase == .done(email: "demo@example.com"))
        #expect(try String(contentsOfFile: record, encoding: .utf8) == "auth login|\(Self.handed(folder))|none\n")
        #expect(Self.listing(folder).isEmpty)                                 // the app wrote nothing inside it
        let claude = try #require(model.list(.claude))
        #expect(claude.logins.map(\.email) == ["demo@example.com"] && claude.logins[0].folders.map(\.id) == [account.id])
        #expect(claude.folders.isEmpty)
    }

    /// A new Codex home runs `codex login` with `CODEX_HOME`, and gets no `config.toml` or anything else from the app, so
    /// its hooks stay off. It signs in to an account the app already reads, so it joins that account's row.
    @Test func aNewCodexHomeSignedInToAKnownAccountJoinsItsRow() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let record = fakes.directory.appendingPathComponent("login.txt").path
        fakes.located = [.claude: URL(fileURLWithPath: "/fake/bin/claude"), .codex: try Self.recordingLogin(fakes, "codex", record: record)]
        let side = Account(provider: .codex, folder: home + "/.codex-side", alias: "side")
        let spare = Account(provider: .codex, folder: home + "/.codex-spare", alias: "spare")
        fakes.codex(spare, "side@example.com", stamp: nil)
        try fakes.writeStore(accounts: [side])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(model.list(.codex)?.logins.map(\.email) == ["side@example.com"])

        #expect(try model.addAccount("spare", provider: .codex).get() == spare)
        #expect(await Self.waitUntil { model.signingIn.isEmpty })
        #expect(model.signInCoordinator.phase == .done(email: "side@example.com"))
        #expect(try String(contentsOfFile: record, encoding: .utf8) == "login|none|\(Self.handed(spare.folder))\n")
        #expect(Self.listing(spare.folder).isEmpty)                           // no config.toml: hooks stay off
        let codex = try #require(model.list(.codex))
        #expect(codex.logins.count == 1 && codex.logins[0].folders.map(\.id) == [side.id, spare.id] && codex.folders.isEmpty)
        #expect(model.codexRow?.batteries.count == 1)                         // one account, one battery
    }

    /// A name that is taken, odd or reserved makes nothing and starts nothing; the row keeps the reason until the name
    /// changes. A folder the account list has but the disk lost still takes its name.
    @Test func plusRefusesTakenOrOddNamesAndMakesNothing() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        try FileManager.default.createDirectory(atPath: home + "/.claude-work", withIntermediateDirectories: false)
        let gone = Account(provider: .claude, folder: home + "/.claude-gone", alias: "gone")
        try fakes.writeStore(accounts: [gone])
        fakes.claude(gone, nil, stamp: nil)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let cases: [(String, NewProfileFolder.Problem)] = [("work", .exists), ("WORK", .exists), ("Gone", .exists), ("../x", .invalid),
                                                           ("a/b", .invalid), (".x", .invalid), ("db1", .reserved), ("  ", .empty)]
        let before = Self.listing(home)
        for (name, problem) in cases {
            #expect(model.checkNewAccount(name, provider: .claude) == .problem(problem), "\(name)")
            #expect(model.addAccount(name, provider: .claude) == .failure(problem), "\(name)")
        }
        #expect(Self.listing(home) == before && model.accounts == [gone] && model.signingIn.isEmpty && model.added.isEmpty)
        model.newAccount = NewAccountDraft(provider: .claude, name: "work")
        model.addAccount("work", provider: .claude)
        #expect(model.newAccount == NewAccountDraft(provider: .claude, name: "work", failure: .exists))
        #expect(NewAccountText.word(.exists) == "Exists" && NewAccountText.word(.empty) == nil)
    }

    /// With no CLI to sign in with, or while standalone Juice runs, "+" cannot act and nothing is made.
    @Test func plusNeedsTheCLIAndTheEditableList() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        fakes.located = [.codex: URL(fileURLWithPath: "/fake/bin/codex")]
        try fakes.writeStore(accounts: [])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(model.isMissingCLI(.claude) && !model.isMissingCLI(.codex))
        #expect(model.addUnavailableReason(.claude) == "Claude CLI not found" && model.canAddAccount(.codex))
        #expect(model.addAccount("demo", provider: .claude) == .failure(.failed) && Self.listing(home).isEmpty)
        fakes.running = [F.juiceApp]
        model.tick()
        #expect(!model.canEdit && model.addUnavailableReason(.codex) == LiveUsageModel.juiceRunningText)
        #expect(model.addAccount("spare", provider: .codex) == .failure(.failed) && Self.listing(home).isEmpty)
    }

    /// A sign-in that is cancelled leaves the folder where it is, listed and signed out (Sign In again, or Forget).
    @Test func aCancelledSignInKeepsTheFolderListed() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let record = fakes.directory.appendingPathComponent("login.txt").path
        fakes.located = [.claude: try Self.recordingLogin(fakes, "claude", record: record, then: "read -r never")]
        let demo = Account(provider: .claude, folder: home + "/.claude-demo", alias: "demo")
        fakes.claude(demo, nil, stamp: nil)
        try fakes.writeStore(accounts: [])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(try model.addAccount("demo", provider: .claude).get() == demo)
        #expect(await Self.waitUntil { if case .inBrowser? = model.signInPhase(for: demo.id) { true } else { false } })
        model.signInCoordinator.cancel()
        #expect(model.signingIn.isEmpty && model.accounts == [demo])
        await model.look()
        #expect(model.list(.claude)?.folders == [LooseFolder(folder: demo, state: .signedOut)])
        #expect(FileManager.default.fileExists(atPath: demo.folder))
    }

    /// Forget hides a folder (found or listed) from the list and from Add, after a relaunch too, and touches nothing on
    /// the disk; naming it again under "+" brings it back as it was, with no new folder and no sign-in.
    @Test func forgetHidesAFolderForGoodAndPlusBringsItBack() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let fm = FileManager.default
        for name in [".claude-demo", ".codex-spare", ".claude-lab"] { try fm.createDirectory(atPath: home + "/" + name, withIntermediateDirectories: false) }
        try "kept".write(toFile: home + "/.claude-demo/notes.txt", atomically: true, encoding: .utf8)
        let demo = DiscoveredProfile(provider: .claude, folder: home + "/.claude-demo", suggestedAlias: "demo")
        let spare = DiscoveredProfile(provider: .codex, folder: home + "/.codex-spare", suggestedAlias: "spare")
        let lab = Account(provider: .claude, folder: home + "/.claude-lab", alias: "lab")
        fakes.discovered = [demo, spare]
        try fakes.writeStore(accounts: [lab])
        let model = fakes.model()
        model.start()
        await model.settle()
        model.refreshDiscovery()
        await model.discovery?.value
        #expect(model.discovered.map(\.id) == [demo.id, spare.id] && model.list(.claude)?.logins.first?.folders.map(\.id) == [lab.id])

        model.forget(demo.id)
        model.forget(lab.id)
        #expect(model.discovered.map(\.id) == [spare.id] && model.accounts.isEmpty && model.list(.claude) == nil)
        #expect(Self.listing(home) == [".claude-demo", ".claude-lab", ".codex-spare"])
        #expect(try String(contentsOfFile: home + "/.claude-demo/notes.txt", encoding: .utf8) == "kept")
        model.stop()

        let again = fakes.model()
        defer { again.stop() }
        again.start()
        await again.settle()
        again.refreshDiscovery()
        await again.discovery?.value
        #expect(again.discovered.map(\.id) == [spare.id] && again.accounts.isEmpty)
        #expect(again.checkNewAccount("Demo", provider: .claude) == .forgotten(folder: demo.folder))
        #expect(again.checkNewAccount("lab", provider: .claude) == .forgotten(folder: lab.folder))
        let restored = try again.addAccount("demo", provider: .claude).get()
        #expect(restored.folder == demo.folder && restored.monitored && again.signingIn.isEmpty && again.added.isEmpty)
        #expect(!again.forgottenStore.contains(demo.id) && again.forgottenStore.contains(lab.id))
        #expect(Self.listing(home + "/.claude-demo") == ["notes.txt"])
        // A forgotten folder gone from the disk is made again instead.
        try fm.removeItem(atPath: lab.folder)
        #expect(again.checkNewAccount("lab", provider: .claude) == .new(folder: lab.folder))
    }

    /// Forget is only for a folder "+" can name again: the provider's own folder and one no name makes are never
    /// forgotten, so no account is hidden for good (Stop Monitoring and Add still work for them), and one an earlier
    /// build forgot is offered with Add again.
    @Test func forgetNeverHidesAFolderPlusCannotNameBack() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        for name in [".claude", ".codex", ".codex-my.side"] {
            try FileManager.default.createDirectory(atPath: home + "/" + name, withIntermediateDirectories: false)
        }
        let main = Account(provider: .claude, folder: home + "/.claude", alias: "default")
        let codex = DiscoveredProfile(provider: .codex, folder: home + "/.codex", suggestedAlias: "default")
        let odd = DiscoveredProfile(provider: .codex, folder: home + "/.codex-my.side", suggestedAlias: "my.side")
        fakes.discovered = [codex, odd]
        try fakes.writeStore(accounts: [main])
        let earlier = ForgottenFoldersStore(fileURL: fakes.directory.appendingPathComponent("forgotten.json"))
        earlier.forget(codex.id)
        try earlier.save()
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        model.refreshDiscovery()
        await model.discovery?.value
        #expect(model.discovered.map(\.id) == [codex.id, odd.id])
        #expect(!model.canForget(provider: .claude, folder: main.folder) && !model.canForget(provider: .codex, folder: codex.folder))
        #expect(!model.canForget(provider: .codex, folder: odd.folder) && model.canForget(provider: .codex, folder: home + "/.codex-side"))

        model.forget(main.id)
        model.forget(odd.id)
        #expect(model.accounts == [main] && model.discovered.map(\.id) == [codex.id, odd.id])
        #expect(!model.forgottenStore.contains(main.id) && !model.forgottenStore.contains(odd.id))
        model.stopMonitoring(main.id)
        #expect(model.discovered.map(\.id) == [codex.id, odd.id, main.id])
        model.add(try #require(model.discovered.last))
        #expect(model.account(id: main.id)?.monitored == true)
    }

    /// Stop Monitoring keeps the folder in the list, switched off and offered with Add, even when discovery does not find
    /// it (a folder "+" made that never signed in); Add switches it on again.
    @Test func stopMonitoringKeepsTheFolderOfferedWithAdd() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let lab = Account(provider: .claude, folder: home + "/.claude-lab", alias: "lab")
        try fakes.writeStore(accounts: [lab])
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        #expect(model.list(.claude)?.logins.map(\.email) == ["lab@example.com"])
        model.stopMonitoring(lab.id)
        #expect(model.account(id: lab.id)?.monitored == false && model.list(.claude) == nil)
        #expect(model.discovered.map(\.id) == [lab.id] && model.discovered.first?.suggestedAlias == "lab")
        model.add(try #require(model.discovered.first))
        #expect(model.account(id: lab.id)?.monitored == true && model.discovered.isEmpty)
    }
}
