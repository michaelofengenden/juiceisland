import Darwin
import Foundation
import OpenIslandCore

/// Keeps the managed hook helper (`~/Library/Application Support/OpenIsland/bin/OpenIslandHooks`, the path every hook
/// command names) the same as the app's bundled superset helper (spec §3.5 Helper sync, P27).
///
/// It replaces the managed helper only when one is installed and differs, with a full copy written beside it and
/// renamed into place, so a hook never runs a half-written helper. It installs nothing where no helper is, never
/// follows or replaces a symbolic link, and refuses while Open Island runs, because Open Island's own launch copies
/// its helper back. Only the cutover calls it; nothing in the app does by itself.
public enum HelperSync {
    public enum Result: Equatable, Sendable {
        case replaced
        case unchanged
        /// No managed helper: nothing is installed by a sync (Install in Setup does that, on a click).
        case notInstalled
        case bundledHelperMissing
        case refusedOpenIslandRunning
        /// The managed helper is a symbolic link or not a regular file; it is left alone.
        case refusedNotAFile
        case failed(String)
    }

    /// Where the app bundle keeps the superset helper: `Contents/Helpers/OpenIslandHooks` (scripts/build-app.sh).
    public static func bundledHelperURL(appBundle: URL = Bundle.main.bundleURL) -> URL {
        appBundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(ManagedHooksBinary.binaryName)
    }

    @discardableResult
    public static func syncHelperIfPresent(bundled: URL = bundledHelperURL(),
                                           managed: URL = ManagedHooksBinary.defaultURL(),
                                           isOpenIslandRunning: () -> Bool = SingleIslandGuard.otherIslandIsRunning) -> Result {
        if isOpenIslandRunning() { return .refusedOpenIslandRunning }
        var info = stat()
        guard lstat(managed.path, &info) == 0 else { return .notInstalled }
        guard info.st_mode & S_IFMT == S_IFREG else { return .refusedNotAFile }
        var source = stat()
        guard stat(bundled.path, &source) == 0, source.st_mode & S_IFMT == S_IFREG,
              let fresh = try? Data(contentsOf: bundled), !fresh.isEmpty else { return .bundledHelperMissing }
        guard let current = try? Data(contentsOf: managed) else { return .failed("The installed helper could not be read.") }
        if current == fresh { return .unchanged }

        let folder = managed.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(".\(managed.lastPathComponent).sync-\(UUID().uuidString)")
        do {
            try fresh.write(to: staged, options: .withoutOverwriting)
            guard chmod(staged.path, 0o755) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            // Checked again right before the swap: Open Island launched meanwhile would copy its own helper back.
            if isOpenIslandRunning() {
                unlink(staged.path)
                return .refusedOpenIslandRunning
            }
            guard rename(staged.path, managed.path) == 0 else {
                let message = String(cString: strerror(errno))
                unlink(staged.path)
                return .failed(message)
            }
            return .replaced
        } catch {
            unlink(staged.path)
            return .failed(error.localizedDescription)
        }
    }
}
