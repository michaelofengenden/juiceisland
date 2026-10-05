import Darwin
import Foundation
import IslandHookNotes
import JuiceCore

extension HookHome {
    /// This app's home (P900): its flavor's own folder in Application Support (`Juice Island` for the private app, the
    /// bundle id's for the public Juice), so the two flavors and Open Island never share a helper or a socket.
    public static var current: HookHome { HookHome(supportFolderNamed: AppFlavor.current.supportFolderName) }

    /// The name Juice's own files in agents' folders take (`AgentHookSpec.Place.owned`): one per flavor (P925).
    public static var ownFileStem: String { AppFlavor.current.isPublic ? "juice" : "juice-island" }
}

/// Copies this build's helper to its home's `bin/JuiceHooks` when it is missing or differs: written beside and renamed
/// over, so a hook that fires meanwhile runs one whole helper or the other (P27's rule). Only a click calls it (Connect,
/// Move, Repair), right before hook entries that name the helper are written. A link at the path is refused (P24).
public enum JuiceHelperInstall {
    public enum Failure: Error, Equatable, Sendable {
        case bundledHelperMissing
        case linked
        case writeFailed(String)
    }

    public static func ensure(bundled: URL, managed: URL, fileManager: FileManager = .default) throws {
        guard fileManager.isExecutableFile(atPath: bundled.path) else { throw Failure.bundledHelperMissing }
        var info = stat()
        if lstat(managed.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.linked }
            if ProfileHookInspector.filesMatch(managed, bundled, fileManager: fileManager) { return }
        }
        let folder = managed.deletingLastPathComponent()
        let staging = folder.appendingPathComponent(".\(managed.lastPathComponent).new-\(UUID().uuidString.prefix(8))")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: bundled, to: staging)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw Failure.writeFailed(JuiceLog.code(error))
        }
        guard rename(staging.path, managed.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: staging)
            throw Failure.writeFailed("rename failed (errno \(code))")
        }
    }
}

/// Writes a config file the way every Juice write does (P916): a copy of the old file first
/// (`<file>.backup.<ISO 8601 time, ":" as "-">`, the newest 3 kept, `HookBackups`), then the new bytes beside it and
/// renamed over, so the agent reads one whole file or the other. A link is never written through (P24).
enum ConfigFileWrite {
    enum Failure: Error, Equatable {
        case linked
        case writeFailed(String)
    }

    /// Writes `data`, or removes the file for nil. Unchanged bytes write nothing.
    static func write(_ data: Data?, to url: URL, backup: Bool = true, fileManager: FileManager = .default, now: Date = Date()) throws {
        var info = stat()
        let exists = lstat(url.path, &info) == 0
        if exists, info.st_mode & S_IFMT == S_IFLNK { throw Failure.linked }
        let old = exists ? try? Data(contentsOf: url) : nil
        if old == data { return }
        let folder = url.deletingLastPathComponent()
        if exists, backup {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
            let copy = folder.appendingPathComponent("\(url.lastPathComponent).backup.\(stamp)")
            try? fileManager.removeItem(at: copy)
            do {
                try fileManager.copyItem(at: url, to: copy)
            } catch {
                throw Failure.writeFailed(JuiceLog.code(error))
            }
            HookBackups.prune(in: folder, files: [url.lastPathComponent], fileManager: fileManager)
        }
        guard let data else {
            if exists { try? fileManager.removeItem(at: url) }
            return
        }
        let staging = folder.appendingPathComponent(".\(url.lastPathComponent).juice-new-\(UUID().uuidString.prefix(8))")
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: staging)
            if exists { try? fileManager.setAttributes([.posixPermissions: info.st_mode & 0o777], ofItemAtPath: staging.path) }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw Failure.writeFailed(JuiceLog.code(error))
        }
        guard rename(staging.path, url.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: staging)
            throw Failure.writeFailed("rename failed (errno \(code))")
        }
    }
}
