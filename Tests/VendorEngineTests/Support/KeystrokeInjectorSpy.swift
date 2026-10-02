@testable import IslandEngine

/// The spy TerminalJumpServiceTests expects. Upstream declares it in KeystrokeInjectorTests.swift, which is not
/// derived here because another test in that file posts a real keystroke to the frontmost app.
final class KeystrokeInjectorSpy: KeystrokeInjector, @unchecked Sendable {
    var callCount = 0
    func sendCmdShiftRightBracket() {
        callCount += 1
    }
}
