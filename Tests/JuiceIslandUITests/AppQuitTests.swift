import Foundation
import Testing
@testable import JuiceIslandUI

/// P98: the update's restart asked AppKit to quit from inside a main actor `Task`; `applicationShouldTerminate` said
/// `.terminateLater` and answered from two more main actor tasks (the Codex shutdown and a 3 s deadline), and AppKit
/// waits for that answer in a nested run loop (modal panel mode) that, entered from inside a main actor job, does not
/// drain the main queue: the answer never came and the app never quit. Each test spins that loop from inside this
/// test's own main actor job, as AppKit does, but the control, which spins it from the run loop's own block and runs
/// alone; `terminate` itself cannot run in a test.
@MainActor
@Suite(.serialized)
struct AppQuitTests {
    /// Spins the main run loop in modal panel mode until `done` holds or `limit` passes; returns the seconds it took.
    private func spinModal(limit: TimeInterval, until done: () -> Bool) -> TimeInterval {
        let start = Date()
        while !done(), Date().timeIntervalSince(start) < limit {
            _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02))
        }
        return Date().timeIntervalSince(start)
    }

    /// Modal panel mode joins the main run loop's common modes, as AppKit makes it in an app, so the loop serves the
    /// main queue in it: only where the loop was entered from can keep a task out. A process without AppKit has only the
    /// default mode there, which would keep the task out whatever the cause.
    nonisolated private static func makeModalPanelCommon() {
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.modalPanel.rawValue as CFString))
    }

    /// The cause: a main actor task started then never runs in that loop, so it can never answer.
    @Test func aMainActorTaskNeverRunsInTheLoopAQuitWaitsIn() {
        Self.makeModalPanelCommon()
        var ran = false
        Task { @MainActor in ran = true }
        _ = spinModal(limit: 0.3) { ran }
        #expect(!ran)
    }

    /// The control: the same loop entered from the run loop's own block, outside any main actor job, runs the task, so
    /// the job the loop is entered from is what keeps it out (nil: the main run loop never ran the block). It runs alone
    /// (`JI_RUNLOOP_CONTROL=1 swift test --filter AppQuitTests`): in a whole run another suite's main actor test may be
    /// spinning the loop when the block comes due, and the block then runs inside that test's job.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JI_RUNLOOP_CONTROL"] == "1"))
    nonisolated func outsideAMainActorJobTheSameLoopRunsTheTask() async {
        let ran: Bool? = await withCheckedContinuation { continuation in
            let answer = OneAnswer(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { answer.send(nil) }
            MainRunLoop.perform {
                Self.makeModalPanelCommon()
                var ran = false
                Task { @MainActor in ran = true }
                let start = Date()
                while !ran, Date().timeIntervalSince(start) < 10 {
                    _ = RunLoop.main.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02))
                }
                answer.send(ran)
            }
        }
        #expect(ran == true)
    }

    /// Resumes its continuation once, with the first answer sent.
    private final class OneAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool?, Never>?

        init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }

        func send(_ answer: Bool?) {
            lock.lock()
            let continuation = continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: answer)
        }
    }

    @Test func theAnswerComesWhenTheWorkEnds() {
        var answers = 0
        let reply = TerminationReply { answers += 1 }
        reply.start(deadline: 30, work: { try? await Task.sleep(for: .milliseconds(50)) })
        let took = spinModal(limit: 10) { answers > 0 }
        #expect(answers == 1 && reply.isSent)
        #expect(took < 10)
        _ = spinModal(limit: 0.2) { false }
        #expect(answers == 1)
    }

    @Test func theDeadlineAnswersWhenTheWorkHangsAndTheWorkEndingLaterAddsNothing() {
        var answers = 0
        let reply = TerminationReply { answers += 1 }
        reply.start(deadline: 0.1, work: { try? await Task.sleep(for: .milliseconds(400)) })
        let took = spinModal(limit: 10) { answers > 0 }
        #expect(answers == 1)
        #expect(took < 0.4)
        _ = spinModal(limit: 0.8) { false }
        #expect(answers == 1)
    }

    /// `MainRunLoop.perform` from another thread reaches the main thread inside that loop (the quit signal's path and
    /// `AppQuit`'s).
    @Test func aPerformedBlockRunsInTheLoopFromAnyThread() {
        final class Flag { var ran = false }
        let flag = Flag()
        nonisolated(unsafe) let unsafeFlag = flag
        DispatchQueue.global().async { MainRunLoop.perform { unsafeFlag.ran = true } }
        _ = spinModal(limit: 10) { flag.ran }
        #expect(flag.ran)
    }

    /// The update script's second ask: SIGUSR2 reaches the installed handler on the main thread and ends nothing (its
    /// default action would end this process); the script is told the signal only once it is installed.
    @Test func theQuitSignalReachesTheHandler() {
        var asked = 0
        UpdateQuitSignal.install { asked += 1 }
        #expect(UpdateQuitSignal.installedName == "USR2")
        kill(getpid(), UpdateQuitSignal.number)
        _ = spinModal(limit: 10) { asked > 0 }
        #expect(asked == 1)
        UpdateQuitSignal.install {}
    }
}
