import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Setup's OpenCode row as the app builds it (P480, P487): shown only when OpenCode is on this Mac, the version asked
/// only when Setup appears and at most once a minute, and a click that writes the plugin, refused while Open Island
/// runs. A temporary config folder and a stub probe: nothing runs `opencode`.
@MainActor
struct OpenCodeSetupModelTests {
    final class Calls: @unchecked Sendable {
        var probes = 0
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    static func model(folder: URL, found: Bool = true, version: OpenCodeVersion? = OpenCodeVersion(major: 2, minor: 0, patch: 18),
                      calls: Calls) -> OpenCodePluginModel {
        OpenCodePluginModel(installer: OpenCodePluginInstaller(configDirectory: folder), locate: { found },
                            probe: { calls.probes += 1; return version }, now: { calls.now })
    }

    static func folder(create: Bool) -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("juice-island-oc-model-\(UUID().uuidString)")
        let url = base.appendingPathComponent(".config/opencode", isDirectory: true)
        if create { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        return url
    }

    @Test
    func noOpenCodeNoRow() async {
        let calls = Calls()
        let model = Self.model(folder: Self.folder(create: false), found: false, calls: calls)
        await model.refresh(askVersion: true)
        #expect(model.row(openIslandRunning: false) == nil)
        #expect(calls.probes == 0)
        #expect(OpenCodePluginModel.inert.installer.configDirectory.path == "/nonexistent/opencode")
    }

    @Test
    func theVersionIsAskedWhenSetupAppearsAtMostOnceAMinute() async {
        let calls = Calls()
        let folder = Self.folder(create: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let model = Self.model(folder: folder, calls: calls)
        await model.refresh(askVersion: false)
        #expect(calls.probes == 0)
        #expect(model.row(openIslandRunning: false)?.title == "OpenCode")
        await model.refresh(askVersion: true)
        await model.refresh(askVersion: true)
        #expect(calls.probes == 1)
        #expect(model.row(openIslandRunning: false)?.title == "OpenCode 2.0.18")
        calls.now = calls.now.addingTimeInterval(61)
        await model.refresh(askVersion: true)
        #expect(calls.probes == 2)
    }

    @Test
    func installThenRemoveOnClicks() async throws {
        let calls = Calls()
        let folder = Self.folder(create: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let model = Self.model(folder: folder, calls: calls)
        await model.refresh(askVersion: true)
        let before = try #require(model.row(openIslandRunning: false, home: folder.deletingLastPathComponent().deletingLastPathComponent().path))
        #expect(before.word == "Not installed" && before.buttonTitle == "Install" && before.canClick)
        #expect(before.folder == "~/.config/opencode")
        // Refused while Open Island runs: nothing written.
        #expect(model.row(openIslandRunning: true)?.canClick == false)
        await model.perform(openIslandRunning: true)
        #expect(!FileManager.default.fileExists(atPath: model.installer.pluginURL.path))
        await model.perform(openIslandRunning: false)
        #expect(model.row(openIslandRunning: false)?.word == "Installed")
        #expect(model.row(openIslandRunning: false)?.buttonTitle == "Remove")
        await model.perform(openIslandRunning: false)
        #expect(model.row(openIslandRunning: false)?.word == "Not installed")
    }

    /// Open Island's plugin under OpenCode 2: amber, with Update, which replaces it.
    @Test
    func openIslandsPluginUnderOpenCode2OffersUpdate() async throws {
        let calls = Calls()
        let folder = Self.folder(create: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let installer = OpenCodePluginInstaller(configDirectory: folder)
        try FileManager.default.createDirectory(at: installer.pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// Open Island plugin for OpenCode\nexport default async () => ({});\n".utf8).write(to: installer.pluginURL)
        let model = Self.model(folder: folder, calls: calls)
        await model.refresh(askVersion: true)
        let row = try #require(model.row(openIslandRunning: false))
        #expect(row.word == "For OpenCode 1" && row.tone == .amber && row.buttonTitle == "Update")
        await model.perform(openIslandRunning: false)
        #expect(installer.readFile() == .ours(revision: OpenCodePlugin.revision))
        #expect(model.row(openIslandRunning: false)?.word == "Installed")
    }

    /// A refused click says why on the row, until the next read.
    @Test
    func aRefusedClickSaysWhy() async throws {
        let calls = Calls()
        let folder = Self.folder(create: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().deletingLastPathComponent()) }
        let model = Self.model(folder: folder, calls: calls)
        await model.refresh(askVersion: false)
        // The folder turns read-only between the read and the click.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        await model.perform(openIslandRunning: false)
        #expect(model.row(openIslandRunning: false)?.refusal == "Could not write")
        #expect(model.row(openIslandRunning: false)?.canClick == false)
    }
}
