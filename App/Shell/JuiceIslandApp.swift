import AppKit

/// The app's entry point, called by the Xcode app target's `main.swift`. The public flavor's target (`PublicApp/`)
/// passes its feed's updater (Sparkle, P823), or nil when the build has no feed's key; the private app passes none. Both
/// pass `focusFilter`, which reads their Focus filter in force (`QuietFocusFilter.current`, P1006): read once, as the
/// app starts, so a Focus already on when it launches quiets it too.
public enum JuiceIslandApp {
    @MainActor public static func run(feed: (any FeedUpdating)? = nil, focusFilter: (@Sendable () async -> Bool?)? = nil) {
        let app = NSApplication.shared
        let delegate = AppDelegate(environment: .app(settings: AppSettings(), feed: feed))
        app.delegate = delegate
        if let focusFilter {
            Task { @MainActor in
                if let quiet = await focusFilter() { FocusFilterState.shared.launchRead(quiet: quiet) }
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
