import Darwin
import Foundation
import Testing
@testable import IslandEngine

/// `HelperSync.syncHelperIfPresent` on scratch files only: a managed helper and a bundled one in a temp folder. The
/// real managed helper is never read or written here.
struct HelperSyncTests {
    struct Scratch {
        let root: URL
        let bundled: URL
        let managed: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("helper-sync-\(UUID().uuidString)", isDirectory: true)
            bundled = root.appendingPathComponent("Juice Island.app/Contents/Helpers/OpenIslandHooks")
            managed = root.appendingPathComponent("OpenIsland/bin/OpenIslandHooks")
            try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: managed.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        func write(_ text: String, to url: URL, mode: mode_t = 0o755) throws {
            try Data(text.utf8).write(to: url)
            chmod(url.path, mode)
        }

        func contents(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

        var binFolderNames: [String] { (try? FileManager.default.contentsOfDirectory(atPath: managed.deletingLastPathComponent().path)) ?? [] }
    }

    @Test
    func theBundledHelperLivesInContentsHelpers() {
        let app = URL(fileURLWithPath: "/Applications/Juice Island.app")
        #expect(HelperSync.bundledHelperURL(appBundle: app).path == "/Applications/Juice Island.app/Contents/Helpers/OpenIslandHooks")
    }

    @Test
    func aDifferentHelperIsReplacedInPlace() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        try scratch.write("superset", to: scratch.bundled)
        try scratch.write("upstream", to: scratch.managed, mode: 0o700)
        var before = stat()
        stat(scratch.managed.path, &before)
        #expect(HelperSync.syncHelperIfPresent(bundled: scratch.bundled, managed: scratch.managed, isOpenIslandRunning: { false }) == .replaced)
        #expect(scratch.contents(scratch.managed) == "superset")
        var after = stat()
        stat(scratch.managed.path, &after)
        #expect(after.st_mode & 0o777 == 0o755)
        // Renamed into place: a new file, never the old one rewritten while a hook might run it.
        #expect(after.st_ino != before.st_ino)
        #expect(scratch.binFolderNames == ["OpenIslandHooks"])
        #expect(HelperSync.syncHelperIfPresent(bundled: scratch.bundled, managed: scratch.managed, isOpenIslandRunning: { false }) == .unchanged)
    }

    /// Refused while Open Island runs, before anything is written, and again right before the swap.
    @Test
    func refusedWhileOpenIslandRunsLeavingTheHelperByteIdentical() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        try scratch.write("superset", to: scratch.bundled)
        try scratch.write("upstream", to: scratch.managed)
        #expect(HelperSync.syncHelperIfPresent(bundled: scratch.bundled, managed: scratch.managed, isOpenIslandRunning: { true })
                == .refusedOpenIslandRunning)
        #expect(scratch.contents(scratch.managed) == "upstream")
        // Open Island starts while the copy is written: the staged copy is removed and nothing is swapped.
        let checks = EngineFixtures.Box(0)
        let result = HelperSync.syncHelperIfPresent(bundled: scratch.bundled, managed: scratch.managed, isOpenIslandRunning: {
            checks.update { $0 += 1 }
            return checks.current > 1
        })
        #expect(result == .refusedOpenIslandRunning)
        #expect(scratch.contents(scratch.managed) == "upstream")
        #expect(scratch.binFolderNames == ["OpenIslandHooks"])
    }

    /// No managed helper: nothing is installed.
    @Test
    func nothingIsInstalledWhereNoHelperIs() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        try scratch.write("superset", to: scratch.bundled)
        #expect(HelperSync.syncHelperIfPresent(bundled: scratch.bundled, managed: scratch.managed, isOpenIslandRunning: { false }) == .notInstalled)
        #expect(!FileManager.default.fileExists(atPath: scratch.managed.path))
        #expect(scratch.binFolderNames.isEmpty)
    }

    /// A symbolic link is never followed or replaced.
    @Test
    func aLinkedHelperIsLeftAlone() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        try scratch.write("superset", to: scratch.bundled)
        let elsewhere = scratch.root.appendingPathComponent("elsewhere")
        try scratch.write("upstream", to: elsewhere)
        try FileManager.default.createSymbolicLink(at: scratch.managed, withDestinationURL: elsewhere)
        #expect(HelperSync.syncHelperIfPresent(bundled: scratch.bundled, managed: scratch.managed, isOpenIslandRunning: { false }) == .refusedNotAFile)
        #expect(scratch.contents(elsewhere) == "upstream")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: scratch.managed.path)) == elsewhere.path)
    }

    @Test
    func aMissingBundledHelperChangesNothing() throws {
        let scratch = try Scratch()
        defer { try? FileManager.default.removeItem(at: scratch.root) }
        try scratch.write("upstream", to: scratch.managed)
        #expect(HelperSync.syncHelperIfPresent(bundled: scratch.bundled, managed: scratch.managed, isOpenIslandRunning: { false })
                == .bundledHelperMissing)
        #expect(scratch.contents(scratch.managed) == "upstream")
    }
}
