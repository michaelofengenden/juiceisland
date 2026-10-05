import AppKit
import IslandEngine

/// What plays a sound by its stored name (`SoundChoice.storageValue`: a system sound's name, `juice:…` or `file:…`) at a
/// volume: `NSSound` in the app, a recorder or nothing in tests and renders, which never play.
@MainActor
protocol SoundPlaying: AnyObject {
    /// `volume`: Settings › Sound › Volume, 0.1 to 1 (`SignalSounds.volume`).
    func play(_ name: String, volume: Float)
}

/// One `NSSound` per play, made only once every check has passed; no audio engine is held between plays (P33).
@MainActor
final class SystemSoundPlayer: SoundPlaying {
    func play(_ name: String, volume: Float) { SystemSoundPlayer.play(name, volume: volume) }

    /// A sound by its stored name at `volume`: the signals' sounds and Settings' Play buttons alike. A system sound, one
    /// of Juice's own, or a chosen file's copy (`SoundLibrary`); one this Mac cannot make plays nothing (P1001).
    static func play(_ name: String, volume: Float) {
        play(SoundChoice(storageValue: name), volume: volume)
    }

    static func play(_ choice: SoundChoice, volume: Float) {
        guard volume > 0, let sound = SoundLibrary.sound(choice) else { return }
        sound.volume = volume
        if sound.play() { heard(for: sound.duration) }
    }

    /// When the last sound this app started ends, a signal's or a Play button's (P1075): Install automatically never
    /// starts, and an automatic run never quits, while one plays. Nil until one plays; tests and renders play none.
    private(set) static var playingUntil: Date?

    /// A sound this app started still plays at `now`.
    static func isPlaying(at now: Date = Date()) -> Bool { playingUntil.map { now < $0 } ?? false }

    /// A sound of `duration` seconds (a chosen file's is at most 10 s, P1001) started at `now`, with a quarter second after.
    static func heard(for duration: TimeInterval, now: Date = Date()) {
        let end = now.addingTimeInterval(max(duration.isFinite ? duration : 0, 0) + 0.25)
        playingUntil = max(playingUntil ?? end, end)
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
/// screen is locked with Quiet while locked on (P422), while the screen is mirrored with Quiet while presenting on or a
/// Focus quiets the island (P1005, P1006), for a session a mute rule matches (P421) or the choice is None, and nothing
/// for the Done of a Codex app thread while Show Codex app threads is off, whose row is hidden too (a thread that waits
/// still sounds). A sound is a system sound, one of Juice's own or a chosen file (P1000, P1001).
enum SignalSounds {
    /// The sound for this signal by its stored name (a system sound's name, `juice:…` or `file:…`), or nil for silence.
    /// `stillNeedsYou`: the session still has a confirmed request or a failed turn when the signal plays; a needs-you
    /// whose request closed on the way (answered at the agent's own prompt) plays nothing (P162). `isQuestion`: what
    /// waits is a question. `muted`: a mute rule matches the session. `away`: the screen is locked or the owner's
    /// session switched out (`ScreenLockWatch.isAway`). `now`: the wall clock Quiet hours are read on.
    /// `scene`: the screen mirrored or a Focus that quiets (`QuietScenes`, P1005, P1006). `support`: the app's support
    /// folder, where a chosen file's copy is (`SoundFiles`).
    @MainActor
    static func sound(for signal: EngineSignal, isCodexAppThread: Bool, stillNeedsYou: Bool = true, isQuestion: Bool = false,
                      muted: Bool = false, away: Bool = false, scene: QuietScene = .none, settings: AppSettings,
                      now: Date = Date(), calendar: Calendar = .current, support: URL = Product.supportFolder()) -> String? {
        guard !settings.soundsMuted, !muted, !QuietMode.lockQuiets(settings, away: away), !QuietMode.sceneQuiets(settings, scene: scene),
              !QuietMode.inQuietHours(settings, now: now, calendar: calendar), !QuietMode.snoozed(settings, now: now) else { return nil }
        let choice: SoundChoice
        switch signal {
        case .needsYou:
            guard stillNeedsYou else { return nil }
            choice = isQuestion ? questionChoice(settings, support: support) : needsYouChoice(settings, support: support)
        case .done:
            if isCodexAppThread, !settings.showCodexAppThreads { return nil }
            // Done's default is None: a chosen file gone from the folder is silence again.
            choice = playable(settings.doneSound, fallback: .none, support: support)
        }
        return choice == .none ? nil : choice.storageValue
    }

    /// The Needs you sound as it plays now: a chosen file that is gone or unreadable is the default (Glass) again
    /// (P1001).
    @MainActor static func needsYouChoice(_ settings: AppSettings, support: URL = Product.supportFolder()) -> SoundChoice {
        playable(settings.needsYouSound, fallback: AppSettings.defaultNeedsYouSound, support: support)
    }

    /// The Question sound as it plays now: unset, or a chosen file that is gone, it is the Needs you sound (P425, P1001).
    @MainActor static func questionChoice(_ settings: AppSettings, support: URL = Product.supportFolder()) -> SoundChoice {
        guard let question = settings.questionSound else { return needsYouChoice(settings, support: support) }
        if case .file = question, !isPlayable(question, support: support) { return needsYouChoice(settings, support: support) }
        return question
    }

    /// `choice`, or `fallback` when it is a chosen file that cannot play now (`SoundFiles.isPlayable`).
    static func playable(_ choice: SoundChoice, fallback: SoundChoice, support: URL) -> SoundChoice {
        isPlayable(choice, support: support) ? choice : fallback
    }

    static func isPlayable(_ choice: SoundChoice, support: URL) -> Bool {
        guard case let .file(path) = choice else { return true }
        return SoundFiles.isPlayable(path, support: support)
    }

    /// Settings › Sound › Volume as a player takes it.
    @MainActor static func volume(_ settings: AppSettings) -> Float { Float(stored(settings.soundVolume)) }

    /// The slider's low end: Mute is the silence, so Volume never says it a second time, and a Play button always plays.
    static let quietestVolume = 0.1

    /// A volume as kept: `quietestVolume` to 1, whatever was written into the defaults by hand.
    static func stored(_ volume: Double) -> Double { volume.isFinite ? min(max(volume, quietestVolume), 1) : 1 }
}
