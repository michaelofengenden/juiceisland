import Darwin
import Foundation
import IslandHookNotes
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

/// Juice's OpenCode plugin in OpenCode's config folder, in a file of its own named per flavor
/// (`~/.config/opencode/plugins/juice-island.js`, `juice.js`), beside Open Island's `open-island.js` (P934). Juice wrote
/// revisions 1 and 2 under Open Island's name: while its own file is missing, Juice's plugin there reads as an older one
/// of Juice's, and Update moves it into Juice's own file; Open Island's own plugin there is never touched. Reads with
/// `lstat` and one bounded read; writes only on a click in Settings › Agents (Install, Update, Remove), never by itself,
/// and never a file that is not Juice's plugin or is a link.
public struct OpenCodePluginInstaller: Sendable {
    public let configDirectory: URL
    /// Juice's own file name, without `.js` (`HookHome.ownFileStem`).
    public let fileStem: String
    /// A plugin file is a few kilobytes; anything much larger is not one.
    static let readLimit = 1_048_576

    public init(configDirectory: URL = OpenCodePluginInstaller.defaultConfigDirectory(), fileStem: String = HookHome.ownFileStem) {
        self.configDirectory = configDirectory
        self.fileStem = fileStem
    }

    /// OpenCode's global config folder, as both versions resolve it with no `XDG_CONFIG_HOME` set (the app is started
    /// by launchd, so it never has one).
    public static func defaultConfigDirectory(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config/opencode", isDirectory: true)
    }

    public var pluginURL: URL {
        configDirectory.appendingPathComponent("plugins", isDirectory: true).appendingPathComponent("\(fileStem).js")
    }

    /// Open Island's file name, where Juice's revisions 1 and 2 were written.
    public var legacyURL: URL {
        configDirectory.appendingPathComponent("plugins", isDirectory: true).appendingPathComponent(OpenCodePlugin.legacyFileName)
    }

    /// OpenCode has run on this Mac (it made its config folder), or a plugin file is there.
    public var configFolderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: configDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Juice's plugin as the row shows it: Juice's own file; while that is missing, Juice's older plugin under Open
    /// Island's name (an `.ours` there; Open Island's own plugin or anything else there reads as missing, Juice's to
    /// leave alone). Never follows a link.
    public func readFile() -> OpenCodePluginFile {
        let own = Self.read(pluginURL)
        guard own == .missing else { return own }
        if case .ours = readLegacyFile() { return readLegacyFile() }
        return .missing
    }

    /// What Open Island's file name holds.
    public func readLegacyFile() -> OpenCodePluginFile { Self.read(legacyURL) }

    static func read(_ url: URL) -> OpenCodePluginFile {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT ? .missing : .unreadable }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .linked
        case S_IFREG: break
        default: return .unreadable
        }
        guard info.st_size <= off_t(Self.readLimit), let handle = FileHandle(forReadingAtPath: url.path) else { return .unreadable }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.readLimit) else { return .unreadable }
        return .of(contents: data)
    }

    /// Install or Update: writes this build's plugin beside the old file and renames it over, so OpenCode reads one
    /// whole file or the other; then Juice's older plugin under Open Island's name goes, so OpenCode never loads two.
    /// Refused for another plugin's file, a link or an unreadable file. No config file is written: both OpenCode
    /// versions load the folder's files by themselves.
    public func install(data: Data = OpenCodePlugin.data) throws {
        try refuseUnlessReplaceable(Self.read(pluginURL))
        let fileManager = FileManager.default
        let folder = pluginURL.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".\(fileStem).js.juice-island-new")
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
        try removeOlderOfOurs()
    }

    /// Remove: Juice's own file, and Juice's older plugin under Open Island's name; never Open Island's plugin or anyone
    /// else's. Juice never registered its plugin in OpenCode's `config.json`, so no config file is written.
    public func remove() throws {
        let file = Self.read(pluginURL)
        switch file {
        case .missing: break
        case .ours:
            guard unlink(pluginURL.path) == 0 || errno == ENOENT else { throw OpenCodePluginError.writeFailed("unlink (errno \(errno))") }
        default:
            try refuseUnlessReplaceable(file)
            throw OpenCodePluginError.foreign
        }
        try removeOlderOfOurs()
    }

    /// Juice's revision 1 or 2 under Open Island's file name goes; Open Island's own plugin there stays.
    private func removeOlderOfOurs() throws {
        guard case .ours = readLegacyFile() else { return }
        guard unlink(legacyURL.path) == 0 || errno == ENOENT else { throw OpenCodePluginError.writeFailed("unlink (errno \(errno))") }
    }

    private func refuseUnlessReplaceable(_ file: OpenCodePluginFile) throws {
        switch file {
        case .missing, .ours: return
        case .openIsland, .foreign: throw OpenCodePluginError.foreign
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
