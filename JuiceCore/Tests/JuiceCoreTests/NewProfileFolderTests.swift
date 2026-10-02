import Foundation
import Testing
@testable import JuiceCore

/// Settings › Accounts' "+": the folder a short name makes, checked before anything is made, in a temp home folder with
/// fictional profiles.
struct NewProfileFolderTests {
    private static func home() throws -> String {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("juice-new-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home.path
    }

    private static func listing(_ home: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).sorted()
    }

    @Test func aNameMakesItsProvidersFolderInTheHomeFolder() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        #expect(NewProfileFolder.check("demo", provider: .claude, home: home) == .success(home + "/.claude-demo"))
        #expect(NewProfileFolder.check("  Spare ", provider: .codex, home: home) == .success(home + "/.codex-spare"))
        #expect(NewProfileFolder.check("night_2-b", provider: .codex, home: home) == .success(home + "/.codex-night_2-b"))
        #expect(NewProfileFolder.check(String(repeating: "a", count: 32), provider: .claude, home: home).isSuccess)
        #expect(Self.listing(home).isEmpty)                                   // a check makes nothing
    }

    /// Only a folder a name makes has a name to bring it back by: never the provider's own folder.
    @Test func aFolderHasANameOnlyWhenANameMakesIt() {
        let home = "/h"
        #expect(NewProfileFolder.name(of: "/h/.claude-work", provider: .claude, home: home) == "work")
        #expect(NewProfileFolder.name(of: "/h/.Claude-Lab", provider: .claude, home: home) == "lab")
        #expect(NewProfileFolder.name(of: "/h/.codex-side/", provider: .codex, home: home) == "side")
        #expect(NewProfileFolder.name(of: "/h/x/../.codex-fresh", provider: .codex, home: "/h/") == "fresh")
        let none: [(String, Provider)] = [
            ("/h/.claude", .claude), ("/h/.codex", .codex), ("/h/.claude-", .claude), ("/h/.claude-work", .codex),
            ("/h/.claude-my.work", .claude), ("/h/.claude-_x", .claude), ("/h/.codex-has space", .codex),
            ("/h/.codex-" + String(repeating: "a", count: 33), .codex), ("/elsewhere/.claude-work", .claude),
            ("/h/sub/.codex-side", .codex), ("/h/.claude-db-bench", .claude), ("/h/.claudework", .claude),
        ]
        for (folder, provider) in none {
            #expect(NewProfileFolder.name(of: folder, provider: provider, home: home) == nil, "\(folder)")
        }
    }

    @Test func aNameCanNeverNameAPathOfItsOwn() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for name in ["", "   "] {
            #expect(NewProfileFolder.check(name, provider: .claude, home: home) == .failure(.empty))
        }
        let tricks = ["../x", "..", "a/b", "/tmp", "x/../../y", ".hidden", "-x", "_x", "has space", "tab\tname", "ünï",
                      "a.b", "~", "$HOME", "a:b", "é", "name\u{0}", String(repeating: "a", count: 33)]
        for name in tricks {
            #expect(NewProfileFolder.check(name, provider: .codex, home: home) == .failure(.invalid), "\(name)")
            #expect(NewProfileFolder.check(name, provider: .claude, home: home) == .failure(.invalid), "\(name)")
        }
        #expect(Self.listing(home).isEmpty)
    }

    /// Discovery passes over `.claude-db…` and `.claude-samplebench…`, so a Claude name that makes one is refused; a
    /// Codex home may use it.
    @Test func aClaudeNameDiscoverySkipsIsReserved() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        for name in ["db", "dbx", "db-2", "samplebench", "samplebench-token"] {
            #expect(NewProfileFolder.check(name, provider: .claude, home: home) == .failure(.reserved), "\(name)")
        }
        #expect(NewProfileFolder.check("db", provider: .codex, home: home) == .success(home + "/.codex-db"))
        #expect(NewProfileFolder.check("d", provider: .claude, home: home).isSuccess)
    }

    /// Those two prefixes are only the private app's (P858): the public flavor passes over no Claude folder, so it
    /// reserves no name either.
    @Test func thePublicFlavorReservesNoClaudeName() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let flavor = AppFlavor(info: ["JIFlavor": "public", "CFBundleIdentifier": "io.github.example.juice"])
        #expect(flavor.isPublic && ProfileDiscovery.ignoredClaudePrefixes(for: flavor).isEmpty)
        #expect(ProfileDiscovery.ignoredClaudePrefixes(for: .private) == ProfileDiscovery.ignoredClaudePrefixes)
        #expect(!ProfileDiscovery.ignoredClaudePrefixes(for: .private).isEmpty)
        for name in ["db", "dbt", "db-team", "samplebench"] {
            #expect(NewProfileFolder.check(name, provider: .claude, home: home, flavor: flavor) == .success(home + "/.claude-" + name))
            #expect(NewProfileFolder.validate(name, provider: .claude, flavor: flavor) == nil)
        }
    }

    /// A folder, a file, a dangling link or a name that differs only in case takes the name, and so does a folder the
    /// account list has that is gone from the disk.
    @Test func anythingAlreadyThereTakesTheName() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.claude-work", withIntermediateDirectories: false)
        try "x".write(toFile: home + "/.codex-file", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: home + "/.codex-link", withDestinationPath: home + "/nowhere")
        try fm.createDirectory(atPath: home + "/.codex-SIDE", withIntermediateDirectories: false)
        #expect(NewProfileFolder.check("work", provider: .claude, home: home) == .failure(.exists))
        #expect(NewProfileFolder.check("WORK", provider: .claude, home: home) == .failure(.exists))
        #expect(NewProfileFolder.check("file", provider: .codex, home: home) == .failure(.exists))
        #expect(NewProfileFolder.check("link", provider: .codex, home: home) == .failure(.exists))
        #expect(NewProfileFolder.check("side", provider: .codex, home: home) == .failure(.exists))
        #expect(NewProfileFolder.check("gone", provider: .claude, home: home, known: [home + "/.claude-GONE"]) == .failure(.exists))
        #expect(NewProfileFolder.check("work", provider: .codex, home: home).isSuccess)   // another provider's name is free
    }

    @Test func createMakesOnlyAnEmptyOwnerOnlyFolderAndNeverTwice() throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let folder = try NewProfileFolder.check("spare", provider: .codex, home: home).get()
        try NewProfileFolder.create(folder)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue)
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o700)
        #expect(Self.listing(folder).isEmpty)                                 // no config.toml, nothing inside
        #expect(throws: NewProfileFolder.Problem.exists) { try NewProfileFolder.create(folder) }
        #expect(NewProfileFolder.check("spare", provider: .codex, home: home) == .failure(.exists))
        // A missing home folder is never made.
        let nowhere = home + "/missing/.codex-spare"
        #expect(throws: NewProfileFolder.Problem.failed) { try NewProfileFolder.create(nowhere) }
        #expect(!FileManager.default.fileExists(atPath: home + "/missing"))
    }
}

@MainActor
struct ForgottenFoldersStoreTests {
    @Test func forgottenFoldersSurviveAReloadAndComeBackByName() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("juice-forgotten-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ForgottenFoldersStore(fileURL: file)
        store.load()                                                          // no file yet: nothing forgotten
        #expect(store.ids.isEmpty)
        let demo = Account.id(provider: .claude, folder: "/h/.claude-demo")
        store.forget(demo)
        store.forget(Account.id(provider: .codex, folder: "/h/.codex-spare"))
        try store.save()
        let reloaded = ForgottenFoldersStore(fileURL: file)
        reloaded.load()
        #expect(reloaded.ids == store.ids && reloaded.contains(demo))
        #expect(reloaded.forgotten(provider: .claude, folder: "/h/.claude-DEMO") == demo)
        #expect(reloaded.forgotten(provider: .codex, folder: "/h/.claude-demo") == nil)
        reloaded.restore(demo)
        #expect(!reloaded.contains(demo) && reloaded.ids.count == 1)
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { true } else { false } }
}
