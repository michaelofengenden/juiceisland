import AppKit

/// Work for the main thread that must run even inside a nested run loop entered from a main actor job (P98). AppKit
/// waits for `applicationShouldTerminate`'s later answer in such a loop (modal panel mode); when `terminate` was called
/// from inside a job (a `Task` on the main actor), that loop does not drain the main queue, so a main actor job
/// scheduled from then on never runs and the quit waits forever. A performed block and a timer are the run loop's own
/// sources: they run in every mode listed here, whatever the loop was entered from.
enum MainRunLoop {
    /// The modes AppKit spins the main run loop in. The common set holds them in an app; they are named one by one too
    /// for a process without AppKit, whose common set is only the default mode (the tests).
    static let modes: [RunLoop.Mode] = [.common, .default, .modalPanel, .eventTracking]

    /// Runs `body` on the main thread from the run loop's blocks, in any of `modes`; callable from any thread.
    static func perform(_ body: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, modes.map(\.rawValue) as CFArray) { MainActor.assumeIsolated { body() } }
        CFRunLoopWakeUp(main)
    }

    /// A one-shot timer on the main run loop, in every one of `modes`.
    @MainActor
    static func timer(after interval: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in MainActor.assumeIsolated { body() } }
        for mode in modes { RunLoop.main.add(timer, forMode: mode) }
        return timer
    }
}

/// Quitting from code: About's Quit and the update's restart. The quit is asked from the main run loop, never from
/// inside the caller's main actor job, so the answer to `applicationShouldTerminate` can arrive (P98).
@MainActor
enum AppQuit {
    static func request() {
        MainRunLoop.perform { NSApp.terminate(nil) }
    }
}

/// Answers `applicationShouldTerminate`'s `.terminateLater` exactly once: when `work` ends or at the deadline, whichever
/// comes first. Both answers come through `MainRunLoop` (a timer and a performed block), never a main actor job, and
/// `work` runs off the main actor, so the answer arrives whatever called `terminate` (P98).
@MainActor
final class TerminationReply {
    private let answer: @MainActor () -> Void
    private var sent = false
    private var deadline: Timer?

    /// `answer` is AppKit's reply; tests count it.
    init(answer: @escaping @MainActor () -> Void = { NSApp.reply(toApplicationShouldTerminate: true) }) {
        self.answer = answer
    }

    /// Starts the race. The run loop's timer and the detached task keep the reply until it is sent.
    func start(deadline seconds: TimeInterval, work: @escaping @Sendable () async -> Void) {
        deadline = MainRunLoop.timer(after: seconds) { [self] in send() }
        Task.detached { [self] in
            await work()
            MainRunLoop.perform { [self] in send() }
        }
    }

    var isSent: Bool { sent }

    private func send() {
        guard !sent else { return }
        sent = true
        deadline?.invalidate()
        deadline = nil
        answer()
    }
}
