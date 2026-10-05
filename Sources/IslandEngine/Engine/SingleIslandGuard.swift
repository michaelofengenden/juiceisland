import AppKit
import Foundation

/// The other island apps. Open Island's bridge deletes whatever socket file it finds before binding its own, so two
/// island apps on one socket silently steal hook events from each other. Juice's bridge now has a socket of its own
/// (`HookHome`, P900), so Open Island running blocks only what still shares its path: a bridge configured on Open
/// Island's socket, the relay of that socket (P911), the old managed helper's sync and the OpenCode plugin file Open
/// Island writes back at launch. Vibe Island is seen too, as a notice only: it has its own socket and helper (P914).
public enum SingleIslandGuard {
    public static let openIslandBundleIdentifiers = ["app.openisland.OpenIsland", "app.openisland.dev"]

    public static func otherIslandIsRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return openIslandBundleIdentifiers.contains { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains { $0.processIdentifier != me && !$0.isTerminated }
        }
    }

    /// Vibe Island is running: by its name, its bundle's file name or a bundle id that names it (its id is not public).
    public static func vibeIslandIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            !app.isTerminated && isVibeIsland(name: app.localizedName, bundleFile: app.bundleURL?.lastPathComponent,
                                             bundleID: app.bundleIdentifier)
        }
    }

    /// The first run's Quit Open Island and Switch to Juice (P958, P955), on the owner's click only: each running copy
    /// is asked to quit, as its own Quit would (`terminate`, never a forced kill). True when one was asked.
    @discardableResult
    public static func askOpenIslandToQuit() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = openIslandBundleIdentifiers.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { $0.processIdentifier != me && !$0.isTerminated }
        return apps.map { $0.terminate() }.contains(true)
    }

    @discardableResult
    public static func askVibeIslandToQuit() -> Bool {
        NSWorkspace.shared.runningApplications.filter { app in
            !app.isTerminated && isVibeIsland(name: app.localizedName, bundleFile: app.bundleURL?.lastPathComponent, bundleID: app.bundleIdentifier)
        }.map { $0.terminate() }.contains(true)
    }

    static func isVibeIsland(name: String?, bundleFile: String?, bundleID: String?) -> Bool {
        let id = (bundleID ?? "").lowercased()
        return name?.lowercased() == "vibe island" || bundleFile?.lowercased() == "vibe island.app"
            || id.contains("vibeisland") || id.contains("vibe-island")
    }
}
