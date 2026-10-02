import AppKit
import Foundation

/// Open Island's bridge deletes whatever socket file it finds before binding its own, so two island apps
/// silently steal hook events from each other. The engine refuses to start its bridge while Open Island runs.
public enum SingleIslandGuard {
    public static let openIslandBundleIdentifiers = ["app.openisland.OpenIsland", "app.openisland.dev"]

    public static func otherIslandIsRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return openIslandBundleIdentifiers.contains { identifier in
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .contains { $0.processIdentifier != me && !$0.isTerminated }
        }
    }
}
