import Darwin
import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Settings › Money's Add key, Replace and Remove through the app's money model: the key becomes its source's key file
/// (0600, in a 0700 folder) and is read once through the stub; nothing else the app keeps or shows ever holds it (Settings,
/// money.json, Diagnostics, the rows, any other file under the home). A temporary home, fake keys and the stub only.
@MainActor
@Suite(.serialized) struct MoneyKeyTests {
    static let openRouterKey = "sk-or-v1-" + String(repeating: "2", count: 64)
    static let secondKey = "sk-or-v1-" + String(repeating: "3", count: 64)
    static let claudeToken = "sk-ant-oat01-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE-0000000000AA"

    /// A temporary home with its own settings, money.json and money model (started, as the release build's is).
    @MainActor
    final class Harness {
        let home: URL
        let suite = "ji.test.\(UUID().uuidString)"
        nonisolated(unsafe) let defaults: UserDefaults
        let settings: AppSettings
        let storeURL: URL
        let money: LiveMoneyModel
        let usage: MoneyUsageModel

        /// `earlier` sets up what an earlier run left (settings, files under the home) before the model starts.
        init(routes: [String: String] = [:], mirrorsOnly: Bool = false, earlier: (UserDefaults, URL) throws -> Void = { _, _ in }) throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("money-keys-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defaults = try #require(UserDefaults(suiteName: suite))
            try earlier(defaults, home)
            settings = AppSettings(defaults: defaults)
            storeURL = home.appendingPathComponent("Library/Application Support/Juice Island/money.json")
            let agent = AppMoneyStub.register(routes)
            money = LiveMoneyModel(settings: settings, client: MoneyHTTPClient(protocolClasses: [AppMoneyStub.self], userAgent: agent),
                                   store: MoneyStore(url: storeURL), home: home.path, mirrorsOnly: mirrorsOnly)
            usage = MoneyUsageModel(base: DemoUsageModel(), money: money)
        }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }

        func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }

        func mode(_ relative: String) -> mode_t? {
            var info = stat()
            guard lstat(path(relative), &info) == 0 else { return nil }
            return info.st_mode & 0o777
        }

        /// Every file under the home that holds `text`, by path relative to the home.
        func files(holding text: String) -> [String] {
            guard let walker = FileManager.default.enumerator(atPath: home.path) else { return [] }
            return walker.compactMap { $0 as? String }.filter { relative in
                guard let data = FileManager.default.contents(atPath: path(relative)) else { return false }
                return String(decoding: data, as: UTF8.self).contains(text)
            }
        }

        /// Starts the readers and waits for the launch's first read, OpenRouter's at once (the others follow 2 s
        /// apart), which finds no key and sends nothing. A key saved before that read ran could be read by it first,
        /// and the key change after it would drop that reading and wait out the 30 s floor, past the test's wait.
        func start(sourceLocation: SourceLocation = #_sourceLocation) async throws {
            money.start()
            try await wait(sourceLocation: sourceLocation) { money.records[.openRouter]?.lastAttemptAt != nil }
        }

        func waitForReading(_ account: MoneyAccount, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            try await wait(sourceLocation: sourceLocation) { money.records[account]?.lastGood != nil }
        }

        /// Waits for `done`, for 300 s worth of looks at most (`Looks`), and records an issue if it never holds. Alone
        /// it takes milliseconds. The looks are counted, not the clock: the suite's first test starts with the whole
        /// parallel run, whose main actor (the launch read's every hop, and each look) was held so long that 300 s of
        /// wall clock passed before the read's three hops had their turns (P1253).
        func wait(sourceLocation: SourceLocation, _ done: () -> Bool) async throws {
            guard await Looks.until(300, done) else {
                Issue.record("looked \(Looks.count(300)) times in vain", sourceLocation: sourceLocation)
                return
            }
        }
    }

    static let openRouterRoutes = [
        "/api/v1/key": #"{"data":{"usage":10,"usage_daily":1.5,"usage_monthly":10,"limit":null,"limit_remaining":null}}"#,
        "/api/v1/credits": #"{"data":{"total_credits":100,"total_usage":10}}"#,
    ]

    @Test func saveWritesTheKeyFileReadsOnceAndTheKeyIsNowhereElse() async throws {
        let harness = try Harness(routes: Self.openRouterRoutes)
        let money = harness.money
        try await harness.start()
        defer { money.stop() }
        #expect(money.editsKeys && money.keyFiles[.openRouter] == nil)

        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(money.keyFiles[.openRouter] == "~/.config/openrouter/key")
        #expect(harness.mode(".config/openrouter/key") == 0o600)
        #expect(harness.mode(".config/openrouter") == 0o700 && harness.mode(".config") == 0o700)
        try await harness.waitForReading(.openRouter)
        #expect(harness.usage.panel.money.map(\.id) == ["OpenRouter"])
        #expect(harness.usage.panel.money.first?.amount == "$90.00")
        #expect(harness.usage.moneyDetails["OpenRouter"]?.status == "Connected")
        #expect(money.requests.map(\.line).contains("GET openrouter.ai/api/v1/key · 200"))

        // The key file holds the key; nothing else does: not Settings, not money.json, not a row, a detail, a request
        // line or the Diagnostics report.
        #expect(harness.files(holding: Self.openRouterKey) == [".config/openrouter/key"])
        #expect(harness.files(holding: "sk-or-v1") == [".config/openrouter/key"])
        #expect(FileManager.default.fileExists(atPath: harness.storeURL.path))
        let report = DiagnosticsText.report(lines: [], money: harness.usage.panel.money.map { ($0.name, harness.usage.moneyDetails[$0.id]?.status ?? "") })
        let shown = [
            "\(harness.defaults.persistentDomain(forName: harness.suite) ?? [:])",
            "\(harness.usage.panel.money)", "\(harness.usage.moneyDetails)", "\(money.records)", String(reflecting: money.records),
            money.requests.map(\.line).joined(separator: "\n"), report, "\(money.keyFiles)",
        ]
        for text in shown { #expect(!text.contains(Self.openRouterKey) && !text.contains("sk-or-v1")) }
    }

    @Test func replaceSwapsTheWholeFile() throws {
        let harness = try Harness()
        #expect(harness.money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(harness.money.saveKey(Self.secondKey, for: .openRouter) == nil)
        let text = try String(contentsOfFile: harness.path(".config/openrouter/key"), encoding: .utf8)
        #expect(text == Self.secondKey + "\n")
        #expect(harness.files(holding: Self.openRouterKey).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: harness.path(".config/openrouter")) == ["key"])
    }

    @Test func aKeyTheSourceMayNotSendIsRefusedAndNothingIsWritten() throws {
        let harness = try Harness()
        #expect(harness.money.saveKey(Self.claudeToken, for: .openRouter) == .signInToken)
        #expect(harness.money.saveKey("sk-proj-FAKE", for: .anthropic) == .notAnAdminKey)
        #expect(harness.money.saveKey("two words", for: .hetzner) == .notAKey)
        #expect(!FileManager.default.fileExists(atPath: harness.path(".config")))
        #expect(harness.money.keyFiles.isEmpty)
        #expect(harness.files(holding: "sk-").isEmpty)
        // What the pane says, never the key.
        #expect(MoneyKeyEditError.signInToken.message == "A sign-in token is never saved")
        #expect(MoneyKeyEditError.notAnAdminKey.message == "Needs an Admin key (sk-ant-admin…)")
    }

    @Test func removeDeletesTheKeyFileAndTheFiguresGoAtOnce() async throws {
        let harness = try Harness(routes: Self.openRouterRoutes)
        let money = harness.money
        try await harness.start()
        defer { money.stop() }
        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        try await harness.waitForReading(.openRouter)
        try "keep".write(toFile: harness.path(".config/openrouter/notes"), atomically: true, encoding: .utf8)
        #expect(money.removal(for: .openRouter) == .delete("~/.config/openrouter/key"))

        #expect(money.removeKey(for: .openRouter) == nil)
        #expect(!FileManager.default.fileExists(atPath: harness.path(".config/openrouter/key")))
        #expect(FileManager.default.fileExists(atPath: harness.path(".config/openrouter/notes")))
        #expect(money.keyFiles[.openRouter] == nil && money.removal(for: .openRouter) == nil)
        #expect(harness.usage.panel.money.isEmpty)
        #expect(money.records[.openRouter]?.lastGood == nil)
        #expect(MoneyStore(url: harness.storeURL).load()[.openRouter]?.lastGood == nil)
    }

    @Test func aFilePickedElsewhereIsForgottenAndStays() throws {
        let harness = try Harness()
        let picked = harness.path("keys/runpod.txt")
        try FileManager.default.createDirectory(atPath: harness.path("keys"), withIntermediateDirectories: true)
        try "rpa_FAKEFAKEFAKEFAKE".write(toFile: picked, atomically: true, encoding: .utf8)
        harness.settings.money.keyFiles[.runPod] = picked
        harness.money.refreshKeyFiles()
        #expect(harness.money.keyFiles[.runPod] == picked)
        #expect(harness.money.removal(for: .runPod) == .forget(picked))
        #expect(harness.money.removeKey(for: .runPod) == nil)
        #expect(FileManager.default.fileExists(atPath: picked))
        #expect(harness.settings.money.keyFiles[.runPod] == nil && harness.money.keyFiles[.runPod] == nil)
        // Save over a pick writes the source's own file and drops the pick.
        harness.settings.money.keyFiles[.runPod] = picked
        #expect(harness.money.saveKey("rpa_NEWNEWNEWNEWNEW", for: .runPod) == nil)
        #expect(harness.settings.money.keyFiles[.runPod] == nil)
        #expect(harness.money.keyFiles[.runPod] == "~/.config/runpod/key")
        #expect(try String(contentsOfFile: picked, encoding: .utf8) == "rpa_FAKEFAKEFAKEFAKE")
    }

    @Test func aDevBuildsMirrorNeverWritesOrDeletesAKey() throws {
        let harness = try Harness(mirrorsOnly: true)
        #expect(!harness.money.editsKeys)
        #expect(harness.money.saveKey(Self.openRouterKey, for: .openRouter) != nil)
        #expect(!FileManager.default.fileExists(atPath: harness.path(".config")))
        try FileManager.default.createDirectory(atPath: harness.path(".config/runpod"), withIntermediateDirectories: true)
        try "rpa_FAKEFAKEFAKEFAKE".write(toFile: harness.path(".config/runpod/key"), atomically: true, encoding: .utf8)
        harness.money.refreshKeyFiles()
        #expect(harness.money.keyFiles[.runPod] == "~/.config/runpod/key")
        #expect(harness.money.removeKey(for: .runPod) != nil)
        #expect(FileManager.default.fileExists(atPath: harness.path(".config/runpod/key")))
    }

    /// Add another: a second OpenRouter key is its own account (`OpenRouter 2`) with its own key file beside the first
    /// (`key-2`, 0600) and its own row, named by its label; Remove takes that account, its row and its settings away and
    /// leaves the first key.
    @Test func anotherKeyIsItsOwnAccountFileAndRow() async throws {
        let harness = try Harness(routes: Self.openRouterRoutes)
        let money = harness.money
        try await harness.start()
        defer { money.stop() }
        let second = MoneyAccount(.openRouter, slot: 2)
        #expect(money.nextAccount(for: .openRouter) == second)
        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(money.saveKey(Self.secondKey, for: second) == nil)
        #expect(harness.mode(".config/openrouter/key-2") == 0o600)
        #expect(money.accounts.filter { $0.source == .openRouter } == [.openRouter, second])
        #expect(money.keyFiles[second] == "~/.config/openrouter/key-2")
        #expect(money.nextAccount(for: .openRouter) == MoneyAccount(.openRouter, slot: 3))
        harness.settings.money.labels[second] = MoneySettings.cleanLabel("  Side project that is far too long \n")
        try await harness.waitForReading(.openRouter)
        try await harness.waitForReading(second)
        #expect(harness.usage.panel.money.map(\.id) == ["OpenRouter", "OpenRouter 2"])
        #expect(harness.usage.panel.money.map(\.name) == ["OpenRouter", "Side project that is far"])
        #expect(harness.defaults.string(forKey: "ji.money.label.OpenRouter 2") == "Side project that is far")
        #expect(harness.files(holding: Self.secondKey) == [".config/openrouter/key-2"])
        #expect(harness.files(holding: Self.openRouterKey) == [".config/openrouter/key"])
        // Two keys of one source keep their own Diagnostics lines.
        #expect(harness.usage.moneyDetails["OpenRouter 2"]?.requests.contains("GET openrouter.ai/api/v1/key · 200") == true)

        #expect(money.removal(for: second) == .delete("~/.config/openrouter/key-2"))
        #expect(money.removeKey(for: second) == nil)
        #expect(!money.accounts.contains(second) && money.keyFiles[second] == nil)
        #expect(harness.usage.panel.money.map(\.id) == ["OpenRouter"])
        #expect(harness.settings.money.labels[second] == nil && harness.defaults.object(forKey: "ji.money.label.OpenRouter 2") == nil)
        #expect(FileManager.default.fileExists(atPath: harness.path(".config/openrouter/key")))
        #expect(money.nextAccount(for: .openRouter) == second)
    }

    /// A further key's Show switch goes with its other settings: switched off, then Remove, then a key saved in the
    /// same place shows at once with no old name (P146). A further slot whose key file went while the app was not
    /// running is forgotten at launch the same way, except by a dev build's mirror, which never edits.
    @Test func aFurtherKeysShowSwitchAndNameGoWithIt() async throws {
        let harness = try Harness(routes: Self.openRouterRoutes)
        let money = harness.money
        try await harness.start()
        defer { money.stop() }
        let second = MoneyAccount(.openRouter, slot: 2)
        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(money.saveKey(Self.secondKey, for: second) == nil)
        harness.settings.moneyShown[second] = false
        harness.settings.money.labels[second] = "Old"
        #expect(money.removeKey(for: second) == nil)
        #expect(harness.settings.moneyShown[second] == true && harness.defaults.object(forKey: "ji.money.shown.OpenRouter 2") as? Bool != false)
        #expect(money.nextAccount(for: .openRouter) == second)
        #expect(money.saveKey(Self.secondKey, for: second) == nil)
        try await harness.waitForReading(.openRouter)
        try await harness.waitForReading(second)
        #expect(harness.usage.shownMoney(harness.settings).map(\.id) == ["OpenRouter", "OpenRouter 2"])
        #expect(harness.usage.panel.money.map(\.name) == ["OpenRouter", "OpenRouter 2"])

        func earlier(_ defaults: UserDefaults, _: URL) {
            defaults.set(false, forKey: "ji.money.shown.OpenRouter 2")
            defaults.set("Old side", forKey: "ji.money.label.OpenRouter 2")
            defaults.set(12.5, forKey: "ji.money.topUp.OpenRouter 2")
        }
        let relaunched = try Harness(routes: Self.openRouterRoutes, earlier: earlier)
        #expect(relaunched.settings.moneyShown[second] == true && relaunched.settings.money.labels[second] == nil)
        #expect(relaunched.defaults.object(forKey: "ji.money.label.OpenRouter 2") == nil
            && relaunched.defaults.object(forKey: "ji.money.topUp.OpenRouter 2") == nil)
        #expect(relaunched.money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(relaunched.money.saveKey(Self.secondKey, for: second) == nil)
        #expect(relaunched.settings.money.source(second) == MoneySourceSettings() && relaunched.settings.moneyShown[second] == true)
        let mirror = try Harness(mirrorsOnly: true, earlier: earlier)
        #expect(mirror.settings.moneyShown[second] == false && mirror.settings.money.labels[second] == "Old side")
    }

    /// A source whose first key went while a further one stayed is listed once, with its keys (no second `OpenRouter ·
    /// Add key…` line), and Add another on its first block adds the first key again.
    @Test func aSourceWhoseFirstKeyWentIsListedOnceWithAddAnother() throws {
        let harness = try Harness()
        let money = harness.money
        let second = MoneyAccount(.openRouter, slot: 2)
        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(money.saveKey(Self.secondKey, for: second) == nil)
        #expect(money.removeKey(for: .openRouter) == nil)
        let listed = MoneyPane.listed(money: money, drawn: [])
        #expect(listed.keyed == [second] && !listed.unkeyed.contains(.openRouter) && listed.unkeyed.contains(.runPod))
        #expect(money.nextAccount(for: .openRouter) == .openRouter)
        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(MoneyPane.listed(money: money, drawn: []).keyed == [.openRouter, second])
        #expect(money.nextAccount(for: .openRouter) == MoneyAccount(.openRouter, slot: 3))
    }

    /// The id fields keep only an id (`Team ID`, `Account ID`): a key pasted there by mistake is refused and never
    /// reaches the defaults, Fireworks' `accounts/my-team` keeps `my-team`, and empty clears the field. An id kept by
    /// an earlier build that is not one reads `Team ID not valid`, never `not set` beside a filled field.
    @Test func anIDFieldKeepsOnlyAnID() async throws {
        let harness = try Harness()
        let money = harness.settings.money
        #expect(money.setAccountID(" \(Self.xAIKey) ", for: .xAI) == "Not a team ID")
        #expect(money.accountIDs[.xAI] == nil)
        #expect(!"\(harness.defaults.persistentDomain(forName: harness.suite) ?? [:])".contains(Self.xAIKey))
        #expect(money.setAccountID(Self.teamID.uppercased(), for: .xAI) == nil && money.accountIDs[.xAI] == Self.teamID)
        #expect(money.setAccountID("team-0000", for: .xAI) == "Not a team ID" && money.accountIDs[.xAI] == Self.teamID)
        #expect(money.setAccountID("accounts/my-team", for: .fireworks) == nil)
        #expect(harness.defaults.string(forKey: "ji.money.accountID.Fireworks") == "my-team")
        #expect(money.setAccountID("my_team", for: .fireworks) == "Not an account ID")
        #expect(money.setAccountID("  ", for: .xAI) == nil && money.accountIDs[.xAI] == nil)

        let earlier = try Harness { defaults, _ in defaults.set("team-00000000", forKey: "ji.money.accountID.xAI") }
        earlier.money.start()
        defer { earlier.money.stop() }
        #expect(earlier.money.saveKey(Self.xAIKey, for: .xAI) == nil)
        for _ in 0..<300 where earlier.money.records[.xAI]?.lastError == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(earlier.usage.moneyDetails["xAI"]?.status == "Team ID not valid")
        #expect(earlier.money.requests.isEmpty)
    }

    /// One key, one account: a key another key of the source already is is not saved again (both would read it, twice
    /// as often as its floor allows, and a 429 on one would not pause the other). Replace with the same key in its own
    /// place still saves.
    @Test func theSameKeyIsNotSavedForTwoKeysOfOneSource() throws {
        let harness = try Harness()
        let money = harness.money
        let second = MoneyAccount(.openRouter, slot: 2)
        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(money.saveKey(" \(Self.openRouterKey)\n", for: second) == .sameKey)
        #expect(!FileManager.default.fileExists(atPath: harness.path(".config/openrouter/key-2")) && !money.accounts.contains(second))
        #expect(money.saveKey(Self.secondKey, for: second) == nil)
        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(money.saveKey(Self.openRouterKey, for: MoneyAccount(.openRouter, slot: 3)) == .sameKey)
        #expect(money.saveKey(Self.secondKey, for: .openRouter) == .sameKey)
        #expect(harness.files(holding: Self.openRouterKey) == [".config/openrouter/key"])
        #expect(harness.files(holding: Self.secondKey) == [".config/openrouter/key-2"])
        #expect(MoneyKeyEditError.sameKey.message == "This key is already set")
    }

    /// A further key removed inside its 429 pause keeps the pause (and its failure) in the records and money.json, with
    /// no row, until it ends: the same place added again, or the next launch, waits it out (Retry-After + 900 s, P146).
    @Test func aFurtherKeysPauseOutlivesRemoveAddAndRelaunch() throws {
        let harness = try Harness(routes: Self.openRouterRoutes)
        let money = harness.money
        let second = MoneyAccount(.openRouter, slot: 2)
        #expect(money.saveKey(Self.openRouterKey, for: .openRouter) == nil)
        #expect(money.saveKey(Self.secondKey, for: second) == nil)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded())
        let until = now + 930
        let reading = MoneyReading(source: .openRouter, readAt: now - 60, figures: .balance(BalanceFigures(currency: .usd, amount: 12)))
        money.apply(second, MoneySourceRecord(lastGood: reading, lastError: .rateLimited(retryAfter: 30), lastErrorAt: now, lastAttemptAt: now,
                                              pausedUntil: until, consecutiveFailures: 1))
        let paused = MoneySourceRecord(lastError: .rateLimited(retryAfter: 30), lastErrorAt: now, lastAttemptAt: now, pausedUntil: until,
                                       consecutiveFailures: 1)
        #expect(money.removeKey(for: second) == nil)
        #expect(money.records[second] == paused && !money.accounts.contains(second))
        #expect(harness.usage.panel.money.map(\.id) == [])
        #expect(MoneyStore(url: harness.storeURL).load()[second] == paused)
        let relaunched = LiveMoneyModel(settings: harness.settings, client: money.client, store: MoneyStore(url: harness.storeURL),
                                        home: harness.home.path)
        #expect(relaunched.records[second] == paused)
        #expect(money.saveKey(Self.secondKey, for: second) == nil)
        #expect(money.records[second] == paused && money.accounts.contains(second))
        #expect(harness.usage.moneyDetails["OpenRouter 2"]?.status == "Rate limited")
        // A pause that is over is not kept.
        let later = LiveMoneyModel(settings: harness.settings, client: money.client, store: MoneyStore(url: harness.storeURL),
                                   home: harness.home.path, clock: { until + 1 })
        #expect(later.removeKey(for: second) == nil)
        #expect(later.records[second] == nil && MoneyStore(url: harness.storeURL).load()[second] == nil)
    }

    static let teamID = "00000000-0000-4000-8000-00000000000a"
    static let deepSeekKey = "sk-5555555555555555555555555555555555555555"
    static let xAIKey = "xai-token-6666666666666666666666666666666666666666"

    /// Two of the new sources through the app: DeepSeek's yuan, and xAI's balance once its team id is set (`Team ID not
    /// set` before, with nothing sent). Each key is in its own file only; the team id is in Settings but never in a
    /// Diagnostics line.
    @Test func newSourcesReadTheirFiguresAndTheirKeysAreNowhereElse() async throws {
        let harness = try Harness(routes: [
            "/user/balance": #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"}]}"#,
            "/v1/billing/teams/\(Self.teamID)/prepaid/balance": #"{"changes":[],"total":{"val":"-3725"}}"#,
        ])
        let money = harness.money
        money.start()
        defer { money.stop() }
        #expect(money.saveKey(Self.deepSeekKey, for: .deepSeek) == nil)
        #expect(money.saveKey(Self.xAIKey, for: .xAI) == nil)
        #expect(harness.mode(".config/deepseek/key") == 0o600 && harness.mode(".config/deepseek") == 0o700)
        #expect(harness.mode(".config/xai/management-key") == 0o600)
        try await harness.waitForReading(.deepSeek)
        #expect(harness.usage.panel.money.first { $0.id == "DeepSeek" }?.amount == "¥110")
        for _ in 0..<300 where money.records[.xAI]?.lastError == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(harness.usage.moneyDetails["xAI"]?.status == "Team ID not set")
        #expect(!money.requests.contains { $0.host == "management-api.x.ai" })

        harness.settings.money.accountIDs[.xAI] = Self.teamID.uppercased()
        try await harness.waitForReading(.xAI)
        #expect(harness.usage.panel.money.first { $0.id == "xAI" }?.amount == "$37.25")
        #expect(money.requests.map(\.line).contains("GET management-api.x.ai/v1/billing/teams/{id}/prepaid/balance · 200"))

        #expect(harness.files(holding: Self.deepSeekKey) == [".config/deepseek/key"])
        #expect(harness.files(holding: Self.xAIKey) == [".config/xai/management-key"])
        let report = DiagnosticsText.report(lines: [], money: harness.usage.panel.money.map { ($0.name, harness.usage.moneyDetails[$0.id]?.status ?? "") })
        let shown = [
            "\(harness.defaults.persistentDomain(forName: harness.suite) ?? [:])",
            "\(harness.usage.panel.money)", "\(harness.usage.moneyDetails)", "\(money.records)", String(reflecting: money.records),
            money.requests.map(\.line).joined(separator: "\n"), report, "\(money.keyFiles)",
            String(decoding: (try? Data(contentsOf: harness.storeURL)) ?? Data(), as: UTF8.self),
        ]
        for text in shown { #expect(!text.contains(Self.deepSeekKey) && !text.contains(Self.xAIKey)) }
        let diagnostics = money.requests.map(\.line).joined() + "\(harness.usage.moneyDetails)"
        #expect(!diagnostics.lowercased().contains(Self.teamID))
    }

    @Test func theKeyFieldAsksForTheRightKind() {
        #expect(MoneyKeyField.prompt(.anthropic) == "Admin key" && MoneyKeyField.prompt(.openAI) == "Admin key")
        #expect(MoneyKeyField.prompt(.hetzner) == "API token" && MoneyKeyField.prompt(.openRouter) == "API key")
        #expect(MoneyKeyField.prompt(.xAI) == "Management key" && MoneyKeyField.prompt(.fal) == "Admin key")
        #expect(MoneyKeyField.prompt(.digitalOcean) == "API token" && MoneyKeyField.prompt(.deepSeek) == "API key")
        #expect(MoneyKeyField.anotherPrompt(.openRouter) == "Another API key" && MoneyKeyField.anotherPrompt(.xAI) == "Another management key")
        #expect(MoneyKeyMode.addingAnother(error: "Why").error == "Why" && MoneyKeyMode.addingAnother(error: nil).isTyping)
        #expect(MoneyKeyField.isBlank(" \n") && !MoneyKeyField.isBlank("x"))
        #expect(MoneyKeyMode.adding(error: "Why").error == "Why" && MoneyKeyMode.confirmingRemove(error: nil).error == nil)
        #expect(MoneyKeyMode.idle.error == nil)
    }
}
