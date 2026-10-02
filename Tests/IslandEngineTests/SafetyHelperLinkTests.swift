import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

/// "Hook helper · Update" (the owner's click) goes through `ProfileHookManager.syncHelperIfPresent`, which must keep
/// helper sync's rule (`HelperSync`, spec §3.5): a managed helper that is a symbolic link is never followed or replaced
/// (safety boost S2). Scratch files only.
@MainActor
struct SafetyHelperLinkTests {
    @Test
    func theUpdateClickLeavesALinkedHelperAlone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-safety-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundle/OpenIslandHooks")
        let elsewhere = root.appendingPathComponent("elsewhere/OpenIslandHooks")
        let managed = root.appendingPathComponent("managed/bin/OpenIslandHooks")
        for url in [bundled, elsewhere, managed] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        try Data("#!/bin/sh\n# another build's helper\nexit 0\n".utf8).write(to: elsewhere)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: elsewhere.path)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: elsewhere)

        let suite = "SafetyHelperLinkTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ProfileHookManager(bundledHelperURL: bundled, managedHelperURL: managed,
                                         intents: ProfileHookIntentStore(defaults: defaults), codexFeatureKey: { .current },
                                         isOpenIslandAppRunning: { false })

        let replaced = try? manager.syncHelperIfPresent()
        #expect(replaced != true)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: managed.path)) == elsewhere.path)
        #expect(try String(contentsOf: elsewhere, encoding: .utf8).contains("another build's helper"))
    }
}
