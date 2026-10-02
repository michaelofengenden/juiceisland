import Foundation
import Testing
@testable import JuiceCore

/// Juice Island spec §7 amendment 10: a CLI credential file is refused before it is opened; keys are read per request
/// and never stored. Temporary folders and fake keys only.
@Suite struct MoneyKeyFileTests {
    @Test func moneyKeyFileRefusesCLICredentialFiles() throws {
        let home = try MoneyTempDir()
        let account = try home.write("accounts/lab/keep.txt", "x")
        let fence = home.fence(accountFolders: [(account as NSString).deletingLastPathComponent])
        let refused = [
            try home.write("keys/auth.json", FakeKeys.openRouter),
            try home.write("keys/.credentials.json", FakeKeys.openRouter),
            try home.write("keys/.claude.json", FakeKeys.openRouter),
            try home.write("keys/credentials.env", FakeKeys.openRouter),
            try home.write("keys/AUTH.JSON", FakeKeys.openRouter),
            try home.write(".claude-work/openrouter.key", FakeKeys.openRouter),
            try home.write(".codex-side/key", FakeKeys.openRouter),
            try home.write(".claude/key", FakeKeys.openRouter),
            try home.write(".codex/deep/key", FakeKeys.openRouter),
            try home.write("accounts/lab/other-name.key", FakeKeys.openRouter),
            try home.write(".config/harborlog/key", FakeKeys.openRouter),
            try home.write("Library/Keychains/key", FakeKeys.openRouter),
        ]
        for path in refused {
            #expect(MoneyKeyFile.refusal(path, guard: fence) != nil, "\(path)")
            #expect(throws: MoneyReadError.self) { try MoneyKeyFile.read(path, guard: fence) }
            do {
                _ = try MoneyKeyFile.read(path, guard: fence)
            } catch {
                guard case .keyFileRefused = error else { Issue.record("\(path): \(error)"); continue }
            }
        }
        // A key file with a harmless name that is a symbolic link to a Claude credential file: refused.
        let target = try home.write(".claude-work/.credentials.json", "{}")
        let link = home.url.appendingPathComponent("keys/anthropic.key")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(MoneyKeyFile.refusal(link.path, guard: fence) != nil)
        #expect(throws: MoneyReadError.keyFileRefused("a CLI credential file")) { try MoneyKeyFile.read(link.path, guard: fence) }
        // A link into a monitored account's folder, and a tilde path into a refused folder.
        let intoAccount = home.url.appendingPathComponent("keys/runpod.key")
        try FileManager.default.createSymbolicLink(atPath: intoAccount.path, withDestinationPath: refused[9])
        #expect(throws: MoneyReadError.keyFileRefused("inside a monitored account's folder")) {
            try MoneyKeyFile.read(intoAccount.path, guard: fence)
        }
        #expect(MoneyKeyFile.refusal("~/.claude-lab/key", guard: fence) != nil)
        #expect(MoneyKeyFile.refusal("~/.config/harborlog/anything", guard: fence) != nil)
        // A hard link with a harmless name to a credential file: no path check can see it, so the link count refuses it
        // before a byte is read.
        let credential = try home.write(".codex-side/auth.json", FakeKeys.openRouter)
        let hardLink = home.url.appendingPathComponent("keys/openai.key")
        try FileManager.default.linkItem(atPath: credential, toPath: hardLink.path)
        #expect(throws: MoneyReadError.keyFileRefused("a hard link")) { try MoneyKeyFile.read(hardLink.path, guard: fence) }
    }

    @Test func refusedFilesAreNeverOpened() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        // Unreadable permissions: opening would fail with a different error, so a refusal proves it was never opened.
        let path = try home.write(".codex-fresh/auth.json", "{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
        #expect(throws: MoneyReadError.keyFileRefused("a CLI credential file")) { try MoneyKeyFile.read(path, guard: fence) }
    }

    @Test func aKeyIsOneLine() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        #expect(try MoneyKeyFile.read(try home.write("a/key", FakeKeys.openRouter + "\n"), guard: fence).value == FakeKeys.openRouter)
        #expect(try MoneyKeyFile.read(try home.write("b/key", "  \(FakeKeys.hetzner)\r\n"), guard: fence).value == FakeKeys.hetzner)
        for (index, text) in ["", "\n", "two\nlines", "has space", "tab\tinside", "ünicode"].enumerated() {
            let path = try home.write("bad\(index)/key", text)
            #expect(throws: MoneyReadError.keyNotUsable) { try MoneyKeyFile.read(path, guard: fence) }
        }
        #expect(throws: MoneyReadError.keyFileUnreadable("missing")) { try MoneyKeyFile.read(home.path + "/none/key", guard: fence) }
        try FileManager.default.createDirectory(atPath: home.path + "/dir/key", withIntermediateDirectories: true)
        #expect(throws: MoneyReadError.keyFileUnreadable("not a file")) { try MoneyKeyFile.read(home.path + "/dir/key", guard: fence) }
        let big = try home.write("big/key", String(repeating: "a", count: 5_000))
        #expect(throws: MoneyReadError.keyFileUnreadable("too large")) { try MoneyKeyFile.read(big, guard: fence) }
        // A key is never printed.
        let key = MoneyKey(FakeKeys.openRouter)
        #expect(!"\(key)".contains("sk-") && !String(reflecting: key).contains("sk-") && Mirror(reflecting: key).children.isEmpty)
    }

    @Test func defaultLookupFindsTheProviderFolderOnly() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        #expect(MoneyKeyFile.path(for: .openRouter, picked: nil, guard: fence) == nil)
        try home.write(".config/openrouter/key", FakeKeys.openRouter)
        try home.write(".config/hcloud/token", FakeKeys.hetzner)
        try home.write(".config/anthropic/admin-key", FakeKeys.anthropicAdmin)
        #expect(MoneyKeyFile.path(for: .openRouter, picked: nil, guard: fence) == "~/.config/openrouter/key")
        #expect(MoneyKeyFile.path(for: .hetzner, picked: nil, guard: fence) == "~/.config/hcloud/token")
        #expect(MoneyKeyFile.path(for: .anthropic, picked: nil, guard: fence) == "~/.config/anthropic/admin-key")
        #expect(MoneyKeyFile.path(for: .runPod, picked: nil, guard: fence) == nil)
        #expect(MoneyKeyFile.path(for: .runPod, picked: "~/keys/runpod", guard: fence) == "~/keys/runpod")
        #expect(try MoneyKeyFile.read("~/.config/openrouter/key", guard: fence).value == FakeKeys.openRouter)
        #expect(MoneyKeyFile.displayName("~/.config/openrouter/key") == "key")
    }
}
