import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Setup's OpenCode row underneath (P480, P487): what the plugin path holds, the installed version, the one button,
/// and the writes a click makes, in a temporary config folder. Nothing here runs `opencode`.
struct OpenCodeSetupTests {
    static let openIslandPlugin = Data("// Open Island plugin for OpenCode\n// Bridges OpenCode events\nexport default async () => ({});\n".utf8)

    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("juice-island-opencode-\(UUID().uuidString)/.config/opencode", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    static func put(_ data: Data, in installer: OpenCodePluginInstaller) {
        try! FileManager.default.createDirectory(at: installer.pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! data.write(to: installer.pluginURL)
    }

    // MARK: Reading

    @Test
    func theFileIsReadFromItsFirstLine() {
        #expect(OpenCodePluginFile.of(contents: OpenCodePlugin.data) == .ours(revision: OpenCodePlugin.revision))
        #expect(OpenCodePluginFile.of(contents: Data("// Juice Island plugin for OpenCode, revision 7.\nx".utf8)) == .ours(revision: 7))
        #expect(OpenCodePluginFile.of(contents: Self.openIslandPlugin) == .openIsland)
        #expect(OpenCodePluginFile.of(contents: Data("export default {}\n".utf8)) == .foreign)
        #expect(OpenCodePluginFile.of(contents: Data("// Juice Island plugin for OpenCode, revision x.\n".utf8)) == .foreign)
        #expect(OpenCodePluginFile.of(contents: Data()) == .foreign)
    }

    @Test
    func theVersionIsReadFromWhateverTheCLIPrints() {
        #expect(OpenCodeVersion(output: "2.0.18\n") == OpenCodeVersion(major: 2, minor: 0, patch: 18))
        #expect(OpenCodeVersion(output: "1.18.33") == OpenCodeVersion(major: 1, minor: 18, patch: 33))
        #expect(OpenCodeVersion(output: "opencode v2.1.0-beta.3") == OpenCodeVersion(major: 2, minor: 1, patch: 0))
        #expect(OpenCodeVersion(output: "0.15") == OpenCodeVersion(major: 0, minor: 15))
        #expect(OpenCodeVersion(output: "command not found") == nil)
        #expect(OpenCodeVersion(output: "") == nil)
        #expect(OpenCodeVersion(major: 1, minor: 18, patch: 33) < OpenCodeVersion(major: 2, minor: 0))
    }

    // MARK: The button

    @Test
    func theRowSaysWhatTheFileIsForTheInstalledOpenCode() {
        let two = OpenCodeVersion(major: 2, minor: 0, patch: 18)
        let one = OpenCodeVersion(major: 1, minor: 18, patch: 33)
        func of(_ file: OpenCodePluginFile, _ version: OpenCodeVersion?, running: Bool = false) -> OpenCodePluginChoice {
            OpenCodePluginChoice.of(file, version: version, openIslandRunning: running)
        }
        #expect(of(.missing, two) == OpenCodePluginChoice(word: "Not installed", amber: false, action: .install))
        #expect(of(.ours(revision: OpenCodePlugin.revision), two) == OpenCodePluginChoice(word: "Installed", amber: false, action: .remove))
        #expect(of(.ours(revision: OpenCodePlugin.revision), one).action == .remove)
        #expect(of(.ours(revision: OpenCodePlugin.revision - 1), two) == OpenCodePluginChoice(word: "Older than this build", amber: false, action: .update))
        #expect(of(.ours(revision: OpenCodePlugin.revision + 1), two) == OpenCodePluginChoice(word: "Newer than this build", amber: false, action: .remove))
        // The case the owner asked for: Open Island's plugin, which OpenCode 2 refuses to load.
        #expect(of(.openIsland, two) == OpenCodePluginChoice(word: "For OpenCode 1", amber: true, action: .update))
        #expect(of(.openIsland, one) == OpenCodePluginChoice(word: "Open Island's", amber: false, action: .update))
        #expect(of(.openIsland, nil) == OpenCodePluginChoice(word: "Open Island's", amber: false, action: .update))
        for file in [OpenCodePluginFile.foreign, .linked, .unreadable] {
            let choice = of(file, two)
            #expect(choice.action == nil && choice.refusal == choice.word && choice.amber, "\(file)")
        }
        let refused = of(.missing, two, running: true)
        #expect(refused.action == nil && refused.refusal == OpenCodePluginChoice.openIslandRunning)
    }

    // MARK: Writes

    @Test
    func installWritesOnlyThePluginFile() throws {
        let folder = Self.folder()
        defer { Self.remove(folder) }
        let installer = OpenCodePluginInstaller(configDirectory: folder)
        #expect(installer.readFile() == .missing)
        try installer.install()
        #expect(installer.readFile() == .ours(revision: OpenCodePlugin.revision))
        #expect(try Data(contentsOf: installer.pluginURL) == OpenCodePlugin.data)
        // No config file written, no staging file left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["plugins"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: installer.pluginURL.deletingLastPathComponent().path)
                == [OpenCodePlugin.fileName])
    }

    @Test
    func updateReplacesOpenIslandsPluginInPlace() throws {
        let folder = Self.folder()
        defer { Self.remove(folder) }
        let installer = OpenCodePluginInstaller(configDirectory: folder)
        Self.put(Self.openIslandPlugin, in: installer)
        // Open Island registered its file in config.json; the registration stays valid for the new file.
        let config = Data(#"{"plugin":["file://\#(installer.pluginURL.path)"],"theme":"dark"}"#.utf8)
        try config.write(to: folder.appendingPathComponent("config.json"))
        try installer.install()
        #expect(installer.readFile() == .ours(revision: OpenCodePlugin.revision))
        #expect(try Data(contentsOf: folder.appendingPathComponent("config.json")) == config)
    }

    @Test
    func anotherPluginsFileOrALinkIsNeverWritten() throws {
        let folder = Self.folder()
        defer { Self.remove(folder) }
        let installer = OpenCodePluginInstaller(configDirectory: folder)
        let theirs = Data("export default {}\n".utf8)
        Self.put(theirs, in: installer)
        #expect(throws: OpenCodePluginError.foreign) { try installer.install() }
        #expect(throws: OpenCodePluginError.foreign) { try installer.remove() }
        #expect(try Data(contentsOf: installer.pluginURL) == theirs)

        try FileManager.default.removeItem(at: installer.pluginURL)
        let target = folder.appendingPathComponent("elsewhere.js")
        try OpenCodePlugin.data.write(to: target)
        try FileManager.default.createSymbolicLink(at: installer.pluginURL, withDestinationURL: target)
        #expect(installer.readFile() == .linked)
        #expect(throws: OpenCodePluginError.linked) { try installer.install() }
        #expect(throws: OpenCodePluginError.linked) { try installer.remove() }
        let attributes = try FileManager.default.attributesOfItem(atPath: installer.pluginURL.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    /// Remove takes the file and, when Open Island registered it, its `config.json` entry (backed up, 3 kept); the
    /// rest of the config stays.
    @Test
    func removeTakesTheFileAndOpenIslandsRegistration() throws {
        let folder = Self.folder()
        defer { Self.remove(folder) }
        let installer = OpenCodePluginInstaller(configDirectory: folder)
        try installer.install()
        let configURL = folder.appendingPathComponent("config.json")
        try Data(#"{"plugin":["file://\#(installer.pluginURL.path)","opencode-wakatime"],"theme":"dark"}"#.utf8).write(to: configURL)
        for second in 0..<4 {
            try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json.backup.2026-09-2\(second)T10-00-00Z"))
        }
        try installer.remove()
        #expect(installer.readFile() == .missing)
        let config = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any])
        #expect(config["plugin"] as? [String] == ["opencode-wakatime"])
        #expect(config["theme"] as? String == "dark")
        let backups = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("config.json.backup.") }
        #expect(backups.count == HookBackups.keep)
        // Nothing there: nothing to do.
        try installer.remove()
    }

    @Test
    func removeLeavesAConfigWithoutARegistrationAlone() throws {
        let folder = Self.folder()
        defer { Self.remove(folder) }
        let installer = OpenCodePluginInstaller(configDirectory: folder)
        try installer.install()
        let config = Data(#"{"theme":"dark"}"#.utf8)
        try config.write(to: folder.appendingPathComponent("opencode.json"))
        try installer.remove()
        #expect(try Data(contentsOf: folder.appendingPathComponent("opencode.json")) == config)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("config.json").path))
    }
}
