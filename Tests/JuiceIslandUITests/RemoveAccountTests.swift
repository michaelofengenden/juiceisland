import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// P362 on `LiveUsageModel`'s fakes: Remove account takes a login out of the app. Every folder of its provider holding
/// it is forgotten where Forget may ("+" names it back) and switched off otherwise (the provider's own folder, which Add
/// brings back). Nothing is signed out, no folder or file is touched, and the login keeps its record. Fictional folders
/// and emails only, in a temp home.
@MainActor
@Suite(.serialized)
struct RemoveAccountTests {
    typealias F = LiveFakes

    static let a = "a@example.com", b = "b@example.com"

    private static func listing(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
    }

    /// `~/.claude`, `~/.claude-lab` and `~/.claude-work` all hold A (`~/.claude-work` switched off), `~/.claude-studio`
    /// holds B: A's Remove forgets the lab and work folders, switches `~/.claude` off, and leaves B as it was.
    @Test func removeForgetsWhatItMayAndStopsTheRest() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let fm = FileManager.default
        for name in [".claude", ".claude-lab", ".claude-work", ".claude-studio"] {
            try fm.createDirectory(atPath: home + "/" + name, withIntermediateDirectories: false)
            try "kept".write(toFile: home + "/" + name + "/notes.txt", atomically: true, encoding: .utf8)
        }
        let main = Account(provider: .claude, folder: home + "/.claude", alias: "Main")
        let lab = Account(provider: .claude, folder: home + "/.claude-lab", alias: "Lab")
        let work = Account(provider: .claude, folder: home + "/.claude-work", alias: "Work")
        let studio = Account(provider: .claude, folder: home + "/.claude-studio", alias: "Studio")
        try fakes.writeStore(accounts: [main, lab, work, studio])
        for folder in [main, lab, work] { fakes.claude(folder, Self.a, stamp: nil) }
        fakes.claude(studio, Self.b, stamp: nil)
        fakes.discovered = [main, lab, work, studio].map {
            DiscoveredProfile(provider: $0.provider, folder: $0.folder, suggestedAlias: $0.alias)
        }
        let model = fakes.model()
        model.start()
        await model.look()
        await model.settle()
        model.stopMonitoring(work.id)
        model.refreshDiscovery()
        await model.discovery?.value
        let idA = LoginsStore.id(provider: .claude, email: Self.a), idB = LoginsStore.id(provider: .claude, email: Self.b)
        #expect(model.list(.claude)?.logins.map(\.id) == [idA, idB])
        #expect(model.loginsStore.state(of: work.id) == .signedIn(login: idA))
        let recordA = try #require(model.loginsStore.logins[idA]?.record)
        let asked = fakes.entries.count, readsBefore = fakes.reads.count

        model.removeAccount(login: idA)
        // One row, one battery, one read target left: B's.
        #expect(model.list(.claude)?.logins.map(\.id) == [idB] && model.list(.claude)?.folders.isEmpty == true)
        #expect(model.claudeRow?.batteries.map(\.id) == [idB])
        #expect(model.accounts.map(\.id) == [main.id, studio.id] && model.account(id: main.id)?.monitored == false)
        #expect(model.forgottenStore.contains(lab.id) && model.forgottenStore.contains(work.id) && !model.forgottenStore.contains(main.id))
        // `~/.claude` is offered with Add again; the forgotten ones are not.
        #expect(model.discovered.map(\.id) == [main.id])
        // It only hides: the login keeps its record, nothing was asked or run, and every folder and file is as it was.
        #expect(model.loginsStore.logins[idA]?.record == recordA)
        #expect(fakes.entries.count == asked)
        #expect(Self.listing(home) == [".claude", ".claude-lab", ".claude-studio", ".claude-work"])
        for name in [".claude", ".claude-lab", ".claude-work"] {
            #expect(try String(contentsOfFile: home + "/" + name + "/notes.txt", encoding: .utf8) == "kept")
        }
        // No read of A after it, on the clock or on Refresh all.
        fakes.clock.now += 3_600
        model.refreshAll()
        await model.look()
        await model.settle()
        let later = Array(fakes.reads.dropFirst(readsBefore))
        #expect(!later.isEmpty && later.allSatisfy { $0 == "read \(studio.id)" })
        model.stop()

        // After a relaunch it stays removed; "+" names a forgotten folder back, and it rejoins A.
        let again = fakes.model()
        defer { again.stop() }
        again.start()
        await again.settle()
        again.refreshDiscovery()
        await again.discovery?.value
        #expect(again.list(.claude)?.logins.map(\.id) == [idB] && again.discovered.map(\.id) == [main.id])
        #expect(again.checkNewAccount("lab", provider: .claude) == .forgotten(folder: lab.folder))
        _ = try again.addAccount("lab", provider: .claude).get()
        await again.look()
        await again.settle()
        #expect(again.list(.claude)?.logins.map(\.id) == [idB, idA])
        #expect(again.list(.claude)?.logins.last?.folders.map(\.id) == [lab.id])
    }

    /// Nothing to remove while standalone Juice runs (the list is only shown), or for a login no folder holds.
    @Test func removeDoesNothingWhileTheListCannotBeEdited() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side])
        fakes.codex(F.side, Self.a, stamp: nil)
        let model = fakes.model()
        defer { model.stop() }
        model.start()
        await model.settle()
        let idA = LoginsStore.id(provider: .codex, email: Self.a)
        model.removeAccount(login: LoginsStore.id(provider: .codex, email: Self.b))
        #expect(model.list(.codex)?.logins.map(\.id) == [idA])
        fakes.running = [LiveFakes.juiceApp]
        model.tick()
        #expect(!model.canEdit)
        model.removeAccount(login: idA)
        #expect(model.accounts == [F.side] && !model.forgottenStore.contains(F.side.id))
    }

    /// The confirmation built into the row: a first press arms it, only a second one within 3 s removes, and a press after
    /// the 3 s arms it again.
    @Test func removeAsksOnceMoreInTheRowForThreeSeconds() {
        let t0 = DemoClock.now
        var confirm = RemoveConfirmation()
        let first = confirm.press(at: t0)
        #expect(!first && confirm.armedAt == t0 && confirm.isArmed(at: t0 + 2.9))
        let second = confirm.press(at: t0 + 2.9)
        #expect(second && confirm.armedAt == nil)
        let afresh = confirm.press(at: t0 + 10), late = confirm.press(at: t0 + 13)
        #expect(!afresh && !late && confirm.armedAt == t0 + 13)
        confirm.disarm()
        #expect(!confirm.isArmed(at: t0 + 13.5))
        // A clock set back never confirms.
        #expect(!RemoveConfirmation(armedAt: t0).isArmed(at: t0 - 1))
    }
}
