import Foundation
import Testing

/// P293: the end-to-end rig's waits count looks, never seconds. A full run shares the main actor with every suite, and
/// one suite's long job held it past a wait's 30 s deadline; the first look after it came a moment before what that job
/// had let through arrived, and the wait gave up with the condition about to hold ("waited 30 s in vain" on the bridge
/// observer, about three minutes into a loaded run).
@MainActor
struct RigWaitTests {
    /// A job holds the main actor 4 times as long as the whole wait may take by the clock, and the condition holds only
    /// on the second look after it. A deadline gave up on the first; the looks go on.
    @Test func aWaitTheMainActorHeldPastItsLimitStillSeesTheCondition() async {
        let stalled = EngineFixtureBox(false)
        Task { @MainActor in
            usleep(200_000)
            stalled.update { $0 = true }
        }
        var looksAfter = 0
        let held = await Looks.until(0.05) {
            guard stalled.current else { return false }
            looksAfter += 1
            return looksAfter >= 2
        }
        #expect(held && looksAfter == 2)
    }

    /// Looks that all find it false end the wait, however long they took: the first, then `limit` seconds' worth.
    @Test func aConditionThatNeverHoldsEndsTheWaitAfterItsLooks() async {
        var looks = 0
        let held = await Looks.until(0.05) {
            looks += 1
            return false
        }
        #expect(!held && looks == Looks.count(0.05) + 1)
    }
}
