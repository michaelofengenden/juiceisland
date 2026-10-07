import Darwin
import Foundation
import Testing
@testable import JuiceIslandUI

/// The widget after an update (P1400): at launch the app ends its own widget extension's processes that run the build it
/// replaced, and only those, then asks WidgetKit once for every timeline. The lister, the ender and the reload are
/// injected; the live lister is checked against a process this test starts itself, in a temporary bundle. No process of
/// the owner's is ever signalled.
@Suite(.serialized)
struct WidgetRestartTests {
    typealias R = WidgetExtensionRestart

    /// A temporary app bundle with one widget extension (and, `other`, an extension of another kind), its executable a
    /// copy of `executable` or an empty file.
    static func bundle(name: String = "JuiceIslandWidget", executable: URL? = nil, other: Bool = true) throws -> (app: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("widget-restart-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Juice Island.app", isDirectory: true)
        func appex(_ folder: String, point: String, executableName: String, source: URL?) throws -> URL {
            let contents = app.appendingPathComponent("Contents/PlugIns/\(folder)/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleExecutable": executableName, "NSExtension": ["NSExtensionPointIdentifier": point]]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let file = contents.appendingPathComponent("MacOS/\(executableName)")
            if let source { try FileManager.default.copyItem(at: source, to: file) } else { try Data().write(to: file) }
            return file
        }
        let file = try appex("JuiceIslandWidget.appex", point: "com.apple.widgetkit-extension", executableName: name, source: executable)
        if other { _ = try appex("Share.appex", point: "com.apple.share-services", executableName: "Share", source: nil) }
        return (app, file)
    }

    static func identity(_ url: URL) throws -> R.FileIdentity {
        var status = stat()
        try #require(stat(url.path, &status) == 0)
        return R.FileIdentity(device: UInt64(UInt32(bitPattern: status.st_dev)), inode: status.st_ino)
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _ended: [pid_t] = []
        private var _listed: [String] = []
        private var _reloads = 0
        var ended: [pid_t] { lock.withLock { _ended } }
        var listed: [String] { lock.withLock { _listed } }
        var reloads: Int { lock.withLock { _reloads } }
        func end(_ pid: pid_t) { lock.withLock { _ended.append(pid) } }
        func list(_ name: String) { lock.withLock { _listed.append(name) } }
        func reload() { lock.withLock { _reloads += 1 } }
    }

    /// The owner's case and its neighbours: the extension the update replaced (another inode, started hours before) ends,
    /// as does one whose image cannot be read but started before the bundle's file was made, and one named by a path
    /// with a symbolic link in it; the one WidgetKit started from the new file stays, however old the bundle; one of the
    /// same name started from another copy (a dev build) stays, stale or not. One reload, after the ends.
    @Test func endsOnlyItsOwnStaleExtension() throws {
        let (app, executable) = try Self.bundle()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let widget = try #require(R.extensions(in: app).first)
        #expect(R.extensions(in: app).count == 1 && widget.name == "JuiceIslandWidget")
        let file = try Self.identity(executable)
        #expect(R.canonical(widget.executable.path) == R.canonical(executable.path) && widget.file == file)
        let old = R.FileIdentity(device: widget.file.device, inode: widget.file.inode &+ 7)
        let before = widget.made.addingTimeInterval(-5 * 3_600), after = widget.made.addingTimeInterval(60)
        // `/private/var/folders/…` and `/var/folders/…` are one place: the kernel may keep either.
        let linked = executable.path.hasPrefix("/private/") ? String(executable.path.dropFirst("/private".count)) : executable.path
        let devBuild = app.deletingLastPathComponent()
            .appendingPathComponent("Juice Island Dev.app/Contents/PlugIns/JuiceIslandWidget.appex/Contents/MacOS/JuiceIslandWidget")
        let processes = [
            R.Running(pid: 101, launchedFrom: executable.path, image: old, started: before),
            R.Running(pid: 102, launchedFrom: executable.path, image: widget.file, started: after),
            R.Running(pid: 103, launchedFrom: executable.path, image: widget.file, started: before),
            R.Running(pid: 104, launchedFrom: devBuild.path, image: old, started: before),
            R.Running(pid: 105, launchedFrom: executable.path, image: nil, started: before),
            R.Running(pid: 106, launchedFrom: executable.path, image: nil, started: after),
            R.Running(pid: 107, launchedFrom: linked, image: old, started: after),
        ]
        let calls = Calls()
        let ended = R.run(bundle: app, list: { calls.list($0); return processes }, end: { calls.end($0); return true },
                          reload: { calls.reload() })
        #expect(calls.listed == ["JuiceIslandWidget"], "the widget's executable alone, never another extension's")
        #expect(ended == [101, 105, 107] && calls.ended == [101, 105, 107])
        #expect(calls.reloads == 1)
    }

    /// Nothing stale, or nothing the signal reached: nothing ended and no reload. A bundle with no widget extension asks
    /// for no process at all.
    @Test func nothingStaleEndsNothingAndReloadsNothing() throws {
        let (app, executable) = try Self.bundle()
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let widget = try #require(R.extensions(in: app).first)
        let current = R.Running(pid: 201, launchedFrom: executable.path, image: widget.file, started: widget.made.addingTimeInterval(1))
        let calls = Calls()
        #expect(R.run(bundle: app, list: { _ in [current] }, end: { calls.end($0); return true }, reload: { calls.reload() }).isEmpty)
        let stale = R.Running(pid: 202, launchedFrom: executable.path, image: nil, started: widget.made.addingTimeInterval(-60))
        #expect(R.run(bundle: app, list: { _ in [stale] }, end: { calls.end($0); return false }, reload: { calls.reload() }).isEmpty)
        #expect(calls.ended == [202] && calls.reloads == 0)

        let (plain, _) = try Self.bundle(other: true)
        defer { try? FileManager.default.removeItem(at: plain.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: plain.appendingPathComponent("Contents/PlugIns/JuiceIslandWidget.appex"))
        let none = Calls()
        #expect(R.run(bundle: plain, list: { none.list($0); return [] }, end: { none.end($0); return true }, reload: { none.reload() }).isEmpty)
        #expect(none.listed.isEmpty && none.ended.isEmpty && none.reloads == 0)
        #expect(R.extensions(in: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).app")).isEmpty)
    }

    /// The live lister reads what the rule needs from a real process: this test's own, its launch path and the inode its
    /// image is mapped from, and nothing for a name no process has.
    @Test func theLiveListerReadsThisProcess() throws {
        let path = try #require(R.launchPath(getpid()))
        let me = URL(fileURLWithPath: path)
        let name = me.lastPathComponent
        let mine = R.live(name).filter { $0.pid == getpid() }
        let found = try #require(mine.first)
        #expect(R.canonical(found.launchedFrom) == R.canonical(path))
        let file = try Self.identity(me)
        #expect(found.image == file)
        #expect(abs(found.started.timeIntervalSinceNow) < 86_400 * 7)
        #expect(R.live("no-process-has-this-\(UUID().uuidString.prefix(8))").isEmpty)
    }

    /// Across an update, with a process this test starts and ends itself: started from the bundle's extension, it is
    /// current; once the bundle is moved aside and a new one put in its place (the private Update's swap), it is stale
    /// and the only one `run` ends, through the injected ender; once the old bundle is deleted, still. The real signal
    /// is never sent: the test stops its own child.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/cc")))
    func theLiveListerFollowsAnExtensionAcrossAnUpdate() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("widget-restart-cc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("waits.c"), built = scratch.appendingPathComponent("waits")
        try "#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = [source.path, "-o", built.path]
        try cc.run()
        cc.waitUntilExit()
        try #require(cc.terminationStatus == 0)

        let name = "jiw-\(UUID().uuidString.prefix(8).lowercased())"
        let (app, executable) = try Self.bundle(name: name, executable: built, other: false)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let child = Process()
        child.executableURL = executable
        try child.run()
        defer {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let pid = child.processIdentifier
        let installed = try #require(R.extensions(in: app).first)
        let seen = R.live(name)
        #expect(seen.map(\.pid) == [pid])
        #expect(R.stale(seen, of: installed).isEmpty, "the extension the bundle holds")

        // The update: the bundle moved aside, a new one (a new file) put in its place.
        let aside = app.deletingLastPathComponent().appendingPathComponent("Juice Island.previous.app", isDirectory: true)
        try FileManager.default.moveItem(at: app, to: aside)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: aside.appendingPathComponent("Contents/PlugIns/JuiceIslandWidget.appex/Contents/Info.plist"),
                                         to: executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: built, to: executable)
        let updated = try #require(R.extensions(in: app).first)
        #expect(updated.file != installed.file)
        let movedAside = R.live(name)
        #expect(movedAside.map(\.pid) == [pid] && R.canonical(movedAside[0].launchedFrom) == R.canonical(executable.path))
        #expect(R.stale(movedAside, of: updated).map(\.pid) == [pid])

        try FileManager.default.removeItem(at: aside)
        let calls = Calls()
        let ended = R.run(bundle: app, list: R.live, end: { calls.end($0); return true }, reload: { calls.reload() })
        #expect(ended == [pid] && calls.ended == [pid] && calls.reloads == 1, "the old file deleted, the process still names it")
        #expect(child.isRunning, "no real signal was sent")
    }
}
