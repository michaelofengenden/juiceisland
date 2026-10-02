import AppKit
import Foundation
import JuiceCore

/// One running app, as much as the guard needs to know about it.
struct RunningAppInfo: Equatable, Sendable {
    var processIdentifier: pid_t
    var bundleIdentifier: String?
    var bundleURL: URL?

    init(processIdentifier: pid_t, bundleIdentifier: String?, bundleURL: URL?) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
    }

    init(_ app: NSRunningApplication) {
        self.init(processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL)
    }
}

/// "Never two Juice readers at once" (spec §5.3, P69): the live readers never start while another Juice reader runs,
/// because each app keeps its own floors and two of them would read every account twice as often. Another reader is
/// any running app other than this process that has Juice's bundle id (`com.ofengenden.juice`, which the release build
/// shares, so a second copy or instance of this app counts too) or a bundle named `Juice.app`. The public flavor
/// (P820), itself a `Juice.app` under its own bundle id, counts a second copy of itself by that id too, and the private
/// app's and standalone Juice's id as before: on a Mac with both, only one of them reads.
struct StandaloneJuiceGuard {
    /// This process, the one reader that is never "the other Juice".
    var ownProcessIdentifier: pid_t
    /// The running apps now (`NSWorkspace` in the app; a list in tests).
    var runningApps: @MainActor () -> [RunningAppInfo]
    /// The bundle ids of other readers: Juice's, and the public flavor's own in that flavor.
    var readerBundleIdentifiers: Set<String> = Self.readerBundleIdentifiers(.current)

    static let juiceBundleIdentifier = AppIdentity.productionBundleIdentifier
    static let juiceBundleName = "Juice.app"

    static func readerBundleIdentifiers(_ flavor: AppFlavor) -> Set<String> {
        var ids: Set<String> = [juiceBundleIdentifier]
        if flavor.isPublic, let own = flavor.bundleIdentifier { ids.insert(own) }
        return ids
    }

    /// The app's guard: this process, `NSWorkspace`'s running apps.
    static var system: StandaloneJuiceGuard {
        StandaloneJuiceGuard(ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
                             runningApps: { NSWorkspace.shared.runningApplications.map(RunningAppInfo.init) })
    }

    func isStandaloneJuice(_ app: RunningAppInfo) -> Bool {
        guard app.processIdentifier != ownProcessIdentifier else { return false }
        return app.bundleIdentifier.map(readerBundleIdentifiers.contains) == true
            || app.bundleURL?.standardizedFileURL.lastPathComponent == Self.juiceBundleName
    }

    /// Whether standalone Juice runs now. `excluding` drops apps that have terminated but may still be listed.
    @MainActor
    func standaloneJuiceIsRunning(excluding gone: Set<pid_t> = []) -> Bool {
        standaloneJuice(in: runningApps(), excluding: gone)
    }

    func standaloneJuice(in apps: [RunningAppInfo], excluding gone: Set<pid_t> = []) -> Bool {
        apps.contains { !gone.contains($0.processIdentifier) && isStandaloneJuice($0) }
    }
}

/// The system events the live model follows: apps launching and quitting (the guard), and sleep and wake (reads pause,
/// spec §9.5). The app's observers go through `NSWorkspace`'s notification center; tests install nothing and call the
/// model directly. No event monitor is involved.
@MainActor
final class LiveSystemEvents {
    private var tokens: [NSObjectProtocol] = []

    struct Handlers {
        var appLaunched: @MainActor (RunningAppInfo) -> Void
        var appTerminated: @MainActor (RunningAppInfo) -> Void
        var willSleep: @MainActor () -> Void
        var didWake: @MainActor () -> Void
    }

    func install(_ handlers: Handlers) {
        guard tokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let info = Self.app(in: note) else { return }
            MainActor.assumeIsolated { handlers.appLaunched(info) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let info = Self.app(in: note) else { return }
            MainActor.assumeIsolated { handlers.appTerminated(info) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handlers.willSleep() }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handlers.didWake() }
        })
    }

    private nonisolated static func app(in note: Notification) -> RunningAppInfo? {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication).map(RunningAppInfo.init)
    }

    func uninstall() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
}
