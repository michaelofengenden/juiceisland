import Foundation

/// The update script's second ask to quit (P98). An app that installed this names the signal to the script it starts
/// (`JI_APP_QUIT_SIGNAL=USR2`); still running `JI_QUIT_GRACE` seconds after `ready`, the script sends it once. The app
/// ignores the signal's default action (which would end the process) and hands it to its handler on the main run loop
/// (`MainRunLoop`, so it arrives whatever the main actor is doing); the update controller quits only while its own
/// script runs and the status file says ready, so any other SIGUSR2 does nothing. An older build names no signal, and
/// the script never sends one to it: nothing ends the app from outside.
@MainActor
enum UpdateQuitSignal {
    static let number = SIGUSR2
    /// What the script passes to `kill -<name>`.
    static let name = "USR2"

    private static var source: DispatchSourceSignal?
    private static var handler: (@MainActor () -> Void)?

    /// The name to hand the script, once the handler is installed; nil before, so the script never signals.
    static var installedName: String? { source == nil ? nil : name }

    /// Installs (or replaces) the handler. The app calls this once, at launch.
    static func install(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        guard source == nil else { return }
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
        // Sendable, so not the main actor's: it runs on the source's queue.
        source.setEventHandler { @Sendable in MainRunLoop.perform { UpdateQuitSignal.handler?() } }
        source.resume()
        self.source = source
    }
}
