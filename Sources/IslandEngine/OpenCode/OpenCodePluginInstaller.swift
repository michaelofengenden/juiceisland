import Darwin
import Foundation
import JuiceCore
import OpenIslandCore

public enum OpenCodePluginError: Error, Equatable, Sendable {
    case foreign
    case linked
    case unreadable
    case writeFailed(String)

    /// Setup's words for a refused or failed click.
    public var refusal: String {
        switch self {
        case .foreign: "Another plugin's file"
        case .linked: "Linked file"
        case .unreadable: "Unreadable file"
        case .writeFailed: "Could not write"
        }
    }
}

/// Juice Island's OpenCode plugin in OpenCode's config folder (`~/.config/opencode/plugins/open-island.js`, where
/// Open Island puts its own). Reads with `lstat` and one bounded read; writes only on a click in Setup (Install, Update,
/// Remove), never by itself, and never a file that is not an island plugin or is a link.
public struct OpenCodePluginInstaller: Sendable {
    public let configDirectory: URL
    /// A plugin file is a few kilobytes; anything much larger is not one.
    static let readLimit = 1_048_576

    public init(configDirectory: URL = OpenCodePluginInstaller.defaultConfigDirectory()) {
        self.configDirectory = configDirectory
    }

    /// OpenCode's global config folder, as both versions resolve it with no `XDG_CONFIG_HOME` set (the app is started
    /// by launchd, so it never has one).
    public static func defaultConfigDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config/opencode", isDirectory: true)
    }

    public var pluginURL: URL {
        configDirectory.appendingPathComponent("plugins", isDirectory: true).appendingPathComponent(OpenCodePlugin.fileName)
    }

    /// OpenCode has run on this Mac (it made its config folder), or a plugin file is there.
    public var configFolderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: configDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// What the plugin path holds. Never follows a link.
    public func readFile() -> OpenCodePluginFile {
        var info = stat()
        guard lstat(pluginURL.path, &info) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .linked
        case S_IFREG: break
        default: return .unreadable
        }
        guard info.st_size <= off_t(Self.readLimit), let handle = FileHandle(forReadingAtPath: pluginURL.path) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.readLimit) else { return .unreadable }
        return .of(contents: data)
    }

    /// Install or Update: writes this build's plugin beside the old file and renames it over, so OpenCode reads one
    /// whole file or the other. Refused for another plugin's file, a link or an unreadable file. No config file is
    /// written: both OpenCode versions load the folder's files by themselves.
    public func install(data: Data = OpenCodePlugin.data) throws {
        try refuseUnlessReplaceable(readFile())
        let fileManager = FileManager.default
        let folder = pluginURL.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".\(OpenCodePlugin.fileName).juice-island-new")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fileManager.removeItem(at: staging)
            try data.write(to: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw OpenCodePluginError.writeFailed(JuiceLog.code(error))
        }
        guard rename(staging.path, pluginURL.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: staging)
            throw OpenCodePluginError.writeFailed("rename failed (errno \(code))")
        }
    }

    /// Remove: only an island plugin. Upstream's uninstaller takes the file, its `config.json` entry when Open Island
    /// registered one (a missing file OpenCode 1 would still try to load) and its manifest; it copies `config.json` to
    /// a backup first, of which the newest 3 are kept (`HookBackups`).
    public func remove() throws {
        let file = readFile()
        guard file.isIslandPlugin else {
            if file == .missing { return }
            try refuseUnlessReplaceable(file)
            throw OpenCodePluginError.foreign
        }
        do {
            try OpenCodePluginInstallationManager(openCodeConfigDirectory: configDirectory).uninstall()
        } catch {
            throw OpenCodePluginError.writeFailed(JuiceLog.code(error))
        }
        HookBackups.prune(in: configDirectory, files: ["config.json"])
    }

    private func refuseUnlessReplaceable(_ file: OpenCodePluginFile) throws {
        switch file {
        case .missing, .ours, .openIsland: return
        case .foreign: throw OpenCodePluginError.foreign
        case .linked: throw OpenCodePluginError.linked
        case .unreadable: throw OpenCodePluginError.unreadable
        }
    }
}

/// `opencode --version`, the one command the app runs for OpenCode (P487): launched only while Setup shows (never at
/// launch, never on a timer), through `CLIEnvironment.make`, bounded by a timeout. It starts no session and no server:
/// both versions print their version and exit.
public enum OpenCodeVersionProbe {
    public static func run(timeout: Duration = .seconds(5)) async -> OpenCodeVersion? {
        guard let executable = ToolLocator.locate("opencode") else { return nil }
        // Claude's default folder: `make` then sets no profile variable, so the environment is the plain allowlist
        // (PATH, HOME, USER, LANG, TMPDIR, TERM) and the island skip keys.
        let environment = CLIEnvironment.make(provider: .claude, folder: NSHomeDirectory() + "/.claude")
        let process = CLIProcess(executable: executable, arguments: ["--version"], environment: environment,
                                 currentDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        do {
            try process.start()
        } catch {
            return nil
        }
        process.closeInput()
        let lines = try? await withTimeout(timeout) {
            var collected: [String] = []
            for await line in process.lines {
                collected.append(line)
                if collected.count >= 8 { break }
            }
            return collected
        }
        process.terminate()
        return lines?.lazy.compactMap { OpenCodeVersion(output: $0) }.first
    }
}
