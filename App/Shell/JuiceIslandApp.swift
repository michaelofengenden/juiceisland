import AppKit

/// The app's entry point, called by the Xcode app target's `main.swift`. The public flavor's target (`PublicApp/`)
/// passes its feed's updater (Sparkle, P823), or nil when the build has no feed's key; the private app passes none.
public enum JuiceIslandApp {
    @MainActor public static func run(feed: (any FeedUpdating)? = nil) {
        let app = NSApplication.shared
        let delegate = AppDelegate(environment: .app(settings: AppSettings(), feed: feed))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
