import AppKit
import IslandEngine

/// What plays a system sound by name at a volume: `NSSound` in the app, a recorder or nothing in tests and renders,
/// which never play.
@MainActor
protocol SoundPlaying: AnyObject {
    /// `volume`: Settings › Sound › Volume, 0.1 to 1 (`SignalSounds.volume`).
    func play(_ name: String, volume: Float)
}

/// One `NSSound` per play, made only once every check has passed; no audio engine is held between plays (P33).
@MainActor
final class SystemSoundPlayer: SoundPlaying {
    func play(_ name: String, volume: Float) { SystemSoundPlayer.play(name, volume: volume) }

    /// A system sound by name at `volume`: the signals' sounds and Settings' Play buttons alike.
    static func play(_ name: String, volume: Float) {
        guard volume > 0, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = volume
        sound.play()
    }
}

/// Plays nothing: every `LiveSessions` but the app's own (`AppEnvironment.app`).
@MainActor
final class SilentSoundPlayer: SoundPlaying {
    func play(_ name: String, volume: Float) {}
}

/// The engine's released signals as the owner's sounds (spec §3.4, §4.5). The engine has already let the signal out:
/// once per key (P5), none before the first live event (P6), a Done only after its 1.5 s hold (P2), and none while the
/// session's own tab is in front when No alerts for focused sessions is on. Here: a question plays the Question sound
/// (the Needs you sound until the owner picks one, P425), anything else that needs you the Needs you sound, and a Done
/// the Done sound, each at Volume (P426); nothing while Mute is on, in Quiet hours (P331), while snoozed (P724), while the
/// screen is locked with Quiet while locked on (P422), for a session a mute rule matches (P421) or the choice is None,
/// and nothing for the Done of a Codex app thread while Show Codex app threads is off, whose row is hidden too (a thread
/// that waits still sounds).
enum SignalSounds {
    /// The system sound's name for this signal, or nil for silence.
    /// `stillNeedsYou`: the session still has a confirmed request or a failed turn when the signal plays; a needs-you
    /// whose request closed on the way (answered at the agent's own prompt) plays nothing (P162). `isQuestion`: what
    /// waits is a question. `muted`: a mute rule matches the session. `away`: the screen is locked or the owner's
    /// session switched out (`ScreenLockWatch.isAway`). `now`: the wall clock Quiet hours are read on.
    @MainActor
    static func sound(for signal: EngineSignal, isCodexAppThread: Bool, stillNeedsYou: Bool = true, isQuestion: Bool = false,
                      muted: Bool = false, away: Bool = false, settings: AppSettings,
                      now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard !settings.soundsMuted, !muted, !QuietMode.lockQuiets(settings, away: away),
              !QuietMode.inQuietHours(settings, now: now, calendar: calendar), !QuietMode.snoozed(settings, now: now) else { return nil }
        let choice: SoundChoice
        switch signal {
        case .needsYou:
            guard stillNeedsYou else { return nil }
            choice = isQuestion ? settings.questionSound ?? settings.needsYouSound : settings.needsYouSound
        case .done:
            if isCodexAppThread, !settings.showCodexAppThreads { return nil }
            choice = settings.doneSound
        }
        guard case let .system(name) = choice else { return nil }
        return name
    }

    /// Settings › Sound › Volume as a player takes it.
    @MainActor static func volume(_ settings: AppSettings) -> Float { Float(stored(settings.soundVolume)) }

    /// The slider's low end: Mute is the silence, so Volume never says it a second time, and a Play button always plays.
    static let quietestVolume = 0.1

    /// A volume as kept: `quietestVolume` to 1, whatever was written into the defaults by hand.
    static func stored(_ volume: Double) -> Double { volume.isFinite ? min(max(volume, quietestVolume), 1) : 1 }
}
