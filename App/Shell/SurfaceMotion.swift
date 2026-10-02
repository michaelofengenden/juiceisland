import AppKit
import CoreGraphics
import Observation
import SwiftUI

/// What decides whether anyone can see a surface (the island panel, the app window, Settings), and so whether its
/// glyphs may move. Pure values: `SurfaceMotionWatch` fills them in from AppKit.
struct SurfaceVisibility: Equatable, Sendable {
    /// The window is ordered in, not minimised, and some of it shows (`NSWindow.occlusionState` has `.visible`): not
    /// ordered out (Window mode's island, the pill hidden while idle, a closed window), not in the Dock, not covered.
    var onScreen: Bool
    /// The displays are awake.
    var displaysAwake = true
    /// The login session is in front and unlocked: no lock screen, no other user switched in.
    var sessionActive = true
    /// The screen saver runs, over every window (before the lock, or with no lock at all).
    var screenSaverRunning = false

    static let shown = SurfaceVisibility(onScreen: true)
    static let hidden = SurfaceVisibility(onScreen: false)

    /// Whether the surface's glyphs move: only while someone can see them. A full-screen app is no reason: the island
    /// panel shows over it (`.fullScreenAuxiliary`), and a window it covers reports its occlusion.
    var glyphsMove: Bool { onScreen && displaysAwake && sessionActive && !screenSaverRunning }

    /// Whether a window counts as on screen: ordered in, not in the Dock, and at least partly visible.
    static func onScreen(isVisible: Bool, isMiniaturized: Bool, occlusion: NSWindow.OcclusionState) -> Bool {
        isVisible && !isMiniaturized && occlusion.contains(.visible)
    }
}

/// One surface's visibility, observed by its SwiftUI root (`glyphMotion(_:)`), which pauses every glyph timeline under
/// it while `moves` is false.
@MainActor
@Observable
final class SurfaceMotion {
    var visibility: SurfaceVisibility

    init(_ visibility: SurfaceVisibility = .shown) {
        self.visibility = visibility
    }

    var moves: Bool { visibility.glyphsMove }
}

extension View {
    /// Pauses every glyph timeline under this view while `motion` says nobody can see it.
    func glyphMotion(_ motion: SurfaceMotion) -> some View {
        modifier(GlyphMotionModifier(motion: motion))
    }
}

private struct GlyphMotionModifier: ViewModifier {
    let motion: SurfaceMotion

    func body(content: Content) -> some View {
        content.environment(\.glyphMotionPaused, !motion.moves)
    }
}

/// Keeps a `SurfaceMotion` in step with its window and the Mac: the window ordered in or out, minimised, closed or
/// covered (its occlusion); the displays sleeping and waking; the screen saver; the screen locking and the login
/// session switching. Notifications only, nothing polls. The controllers call `refresh()` after they order the window
/// in or out; AppKit tells the occlusion later, and a window just ordered in is read again once in case that word
/// never comes.
///
/// The island panel (`island: true`) does not follow occlusion: it floats over the menu bar on every Space and over
/// full-screen apps, so nothing covers it but the screen saver and the lock screen, which the watch reads for itself,
/// and the pill must never stay still for want of an occlusion notice.
@MainActor
final class SurfaceMotionWatch {
    let motion: SurfaceMotion
    private weak var window: NSWindow?
    private let island: Bool
    private var displaysAwake = true
    private var sessionActive = true
    private var screenSaverRunning = false
    private var recheck: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(window: NSWindow, motion: SurfaceMotion, island: Bool = false) {
        self.window = window
        self.motion = motion
        self.island = island
        sessionActive = !Self.screenIsLocked()
        let local = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification] {
            observe(local, name, object: window) { $0.refresh(settle: false) }
        }
        // A closed window is ordered out once `willClose` returns.
        observe(local, NSWindow.willCloseNotification, object: window) { watch in
            Task { @MainActor [weak watch] in watch?.refresh(settle: false) }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAwake = false; $0.refresh(settle: false) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAwake = true; $0.refresh(settle: false) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false; $0.refresh(settle: false) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { watch in
            watch.sessionActive = !Self.screenIsLocked()
            watch.refresh(settle: false)
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.sessionActive = false; $0.refresh(settle: false) }
        // Unlocked, the screen saver is gone too, even if its stop was never told.
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { watch in
            watch.sessionActive = true
            watch.screenSaverRunning = false
            watch.refresh(settle: false)
        }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screenSaverRunning = true; $0.refresh(settle: false) }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screenSaverRunning = false; $0.refresh(settle: false) }
        refresh()
    }

    func stop() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        recheck?.cancel()
    }

    /// Reads the window and the Mac again; `motion` changes only when what it says changes. `settle`: the window was
    /// just ordered in or out, so a window that shows but is not yet reported visible is read once more, half a second on.
    func refresh(settle: Bool = true) {
        guard let window else { return }
        let occlusion: NSWindow.OcclusionState = island ? .visible : window.occlusionState
        let onScreen = SurfaceVisibility.onScreen(isVisible: window.isVisible, isMiniaturized: window.isMiniaturized, occlusion: occlusion)
        let visibility = SurfaceVisibility(onScreen: onScreen, displaysAwake: displaysAwake, sessionActive: sessionActive,
                                           screenSaverRunning: screenSaverRunning)
        if settle, window.isVisible, !occlusion.contains(.visible), recheck == nil {
            recheck = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.recheck = nil
                if !Task.isCancelled { self?.refresh(settle: false) }
            }
        }
        if visibility != motion.visibility { motion.visibility = visibility }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil,
                         _ action: @escaping @MainActor (SurfaceMotionWatch) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    /// Whether the screen is locked now (the login session's own flag), for a watch made while it is.
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
