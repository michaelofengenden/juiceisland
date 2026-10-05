import Darwin
import Foundation

/// Where one flavor of the app keeps its hook helper and its sockets (P900): a folder in Application Support, the
/// app's own (`Juice Island` for the private app, the bundle id's for the public Juice), holding `bin/JuiceHooks` and
/// the three sockets that helper talks to. Each flavor has its own, so the private app, a public Juice and Open Island
/// never take each other's hooks: Open Island keeps `OpenIsland/bin/OpenIslandHooks` and `OpenIsland/bridge.sock`.
///
/// The helper finds its home from its own path (`bin/JuiceHooks` under the folder), so a hook command needs nothing
/// but the helper's path, and the app and every helper it installed agree without a setting. A helper at any other
/// path (the old managed copy at Open Island's path, a test's build product) has no home and keeps the sockets it
/// always used.
public struct HookHome: Equatable, Sendable {
    /// The helper's file name in `bin/`. Never "OpenIslandHooks" or anything with it: upstream's installers take any
    /// command naming `openislandhooks` as their own and would remove Juice's hooks (P901).
    public static let helperName = "JuiceHooks"
    public static let binFolder = "bin"
    public static let bridgeName = "bridge.sock"
    /// The context notes' and the request broker's sockets, as the private app has named them since the notes began
    /// (`HookNoteSocket`, `HookRequestSocket`): helpers already installed keep reaching them.
    public static let notesName = "hook-notes.sock"
    public static let requestsName = "hook-requests.sock"
    /// Shorter names where the long ones would not fit a socket address (104 bytes on macOS): a public flavor's folder is
    /// named by its bundle id, which can be long (P902).
    public static let shortNotesName = "notes.sock"
    public static let shortRequestsName = "requests.sock"

    public let folder: URL

    public init(folder: URL) {
        self.folder = folder.standardizedFileURL
    }

    /// `~/Library/Application Support/<folderName>`, with the home folder from the user database, so the app and a
    /// helper started by any agent agree even when the agent's `HOME` differs.
    public init(supportFolderNamed folderName: String, home: String = HookHome.userHome()) {
        self.init(folder: URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true))
    }

    public var helperURL: URL {
        folder.appendingPathComponent(Self.binFolder, isDirectory: true).appendingPathComponent(Self.helperName)
    }

    public var bridgeURL: URL { folder.appendingPathComponent(Self.bridgeName) }
    public var notesURL: URL { fitting(Self.notesName, else: Self.shortNotesName) }
    public var requestsURL: URL { fitting(Self.requestsName, else: Self.shortRequestsName) }

    /// The long name when its path fits a socket address, else the short one. Both sides work it out the same way.
    private func fitting(_ name: String, else short: String) -> URL {
        let long = folder.appendingPathComponent(name)
        return Self.fitsSocketAddress(long) ? long : folder.appendingPathComponent(short)
    }

    /// Whether a path fits `sockaddr_un.sun_path` with its terminating zero.
    public static func fitsSocketAddress(_ url: URL) -> Bool {
        let address = sockaddr_un()
        return url.path.utf8.count < MemoryLayout.size(ofValue: address.sun_path)
    }

    /// The home whose helper this executable is: `<folder>/bin/JuiceHooks`. nil for any other path.
    public static func of(helperExecutable url: URL?) -> HookHome? {
        guard let url else { return nil }
        let path = url.standardizedFileURL
        let bin = path.deletingLastPathComponent()
        guard path.lastPathComponent == helperName, bin.lastPathComponent == binFolder else { return nil }
        return HookHome(folder: bin.deletingLastPathComponent())
    }

    /// This process's executable, as the kernel started it (`_NSGetExecutablePath`): the hook command's path.
    public static func currentExecutable() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// The running helper's home, or nil when it runs from anywhere else.
    public static func ofCurrentHelper() -> HookHome? { of(helperExecutable: currentExecutable()) }

    public static func userHome() -> String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }
}

/// What Open Island installs, and what Juice installed before its own helper (P900): the helper every older hook
/// command names and the socket that helper's upstream half dials. Read only, to know which hooks still call it and
/// to serve its socket while they do (`LegacyBridgeRelay`).
public enum LegacyHookHome {
    public static let folderName = "OpenIsland"
    public static let helperName = "OpenIslandHooks"

    public static func folder(home: String = HookHome.userHome()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    public static func helperURL(home: String = HookHome.userHome()) -> URL {
        folder(home: home).appendingPathComponent("bin", isDirectory: true).appendingPathComponent(helperName)
    }

    public static func bridgeURL(home: String = HookHome.userHome()) -> URL {
        folder(home: home).appendingPathComponent("bridge.sock")
    }
}
