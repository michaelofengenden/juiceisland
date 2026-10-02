import Foundation
@testable import IslandEngine
@testable import JuiceIslandUI
import Testing

/// Settings › Sound (P425, P426): a question's own sound, the Needs you sound until the owner picks one, and one volume
/// for every sound. Nothing plays: a `RecordingSoundPlayer` records the name and the volume.
@MainActor
@Suite(.serialized)
struct SoundChoiceTests {
    // MARK: The question sound (P425)

    /// A question plays the Question sound; unset it is the Needs you sound, so nothing changes until the owner picks.
    /// An approval keeps the Needs you sound; Question None silences questions only.
    @Test func aQuestionPlaysTheQuestionSound() {
        let settings = AppSettings.ephemeral()
        func sound(question: Bool) -> String? {
            SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, isQuestion: question, settings: settings)
        }
        #expect(settings.questionSound == nil)
        #expect(sound(question: true) == "Glass" && sound(question: false) == "Glass")
        settings.needsYouSound = .system("Ping")
        #expect(sound(question: true) == "Ping")
        settings.questionSound = .system("Submarine")
        #expect(sound(question: true) == "Submarine" && sound(question: false) == "Ping")
        settings.questionSound = SoundChoice.none
        #expect(sound(question: true) == nil && sound(question: false) == "Ping")
        // A Done is never a question.
        settings.doneSound = .system("Hero")
        #expect(SignalSounds.sound(for: .done(sessionID: "s"), isCodexAppThread: false, isQuestion: true, settings: settings) == "Hero")
    }

    /// With the live engine: a question's request plays the Question sound, an approval the Needs you sound, each at
    /// the volume.
    @Test func theLiveEnginesQuestionPlaysItsOwnSound() throws {
        let probe = QuietLaneRig.Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.questionSound = .system("Submarine")
        settings.soundVolume = 0.4
        let live = QuietLaneRig.live(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        QuietLaneRig.start("q", folder: "/tmp/project", engine, probe)
        QuietLaneRig.start("a", folder: "/tmp/other", engine, probe)
        engine.ingest(QuietLaneRig.question("q", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(live.row(id: "q")?.status == .question)
        engine.ingest(QuietLaneRig.permission("a", "toolu_1", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played == ["Submarine", "Glass"])
        #expect(player.volumes == [0.4, 0.4])
    }

    /// Unset, the key is absent (the Needs you sound); None and a sound are kept; the pop-up offers "Same as Needs you"
    /// first, then None and the sounds.
    @Test func theQuestionSoundKeepsItsValue() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.questionSound == nil && defaults.object(forKey: AppSettings.Key.questionSound) == nil)
        fresh.questionSound = SoundChoice.none
        #expect(AppSettings(defaults: defaults).questionSound == SoundChoice.none)
        fresh.questionSound = .system("Pop")
        #expect(AppSettings(defaults: defaults).questionSound == .system("Pop"))
        fresh.questionSound = nil
        #expect(AppSettings(defaults: defaults).questionSound == nil && defaults.object(forKey: AppSettings.Key.questionSound) == nil)
        let options = SoundChoices.questionOptions
        #expect(options.first.map { $0.0 == nil && $0.1 == "Same as Needs you" } == true)
        #expect(options.dropFirst().map(\.1) == SoundChoices.options.map(\.1))
    }

    // MARK: Volume (P426)

    /// Every play carries the volume; 100 % until the owner moves it, so the sounds stay as they were. The slider stops
    /// at 10 %: Mute is the silence. A value written by hand is brought inside.
    @Test func theVolumeReachesEveryPlay() throws {
        let probe = QuietLaneRig.Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.doneSound = .system("Hero")
        #expect(settings.soundVolume == 1 && SignalSounds.volume(settings) == 1)
        let live = QuietLaneRig.live(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        QuietLaneRig.start("s", folder: "/tmp/project", engine, probe)
        QuietLaneRig.finish("s", engine, probe)
        settings.soundVolume = 0.25
        QuietLaneRig.finish("s", engine, probe)
        #expect(player.played == ["Hero", "Hero"] && player.volumes == [1, 0.25])
        // Mute still plays nothing, at any volume.
        settings.soundsMuted = true
        QuietLaneRig.finish("s", engine, probe)
        #expect(player.played.count == 2)

        #expect(SignalSounds.stored(0) == SignalSounds.quietestVolume && SignalSounds.stored(3) == 1 && SignalSounds.stored(.nan) == 1)
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.soundVolume == 1)
        fresh.soundVolume = 0.6
        #expect(AppSettings(defaults: defaults).soundVolume == 0.6)
        defaults.set(-2.0, forKey: AppSettings.Key.soundVolume)
        #expect(AppSettings(defaults: defaults).soundVolume == SignalSounds.quietestVolume)
    }

    /// Volume's preview when the slider is let go: the Needs you sound, else the Question sound, else Done.
    @Test func theVolumePreviewPlaysTheFirstSoundThereIs() {
        let settings = AppSettings.ephemeral()
        #expect(SoundChoices.preview(settings) == .system("Glass"))
        settings.needsYouSound = SoundChoice.none
        #expect(SoundChoices.preview(settings) == SoundChoice.none)
        settings.questionSound = .system("Pop")
        #expect(SoundChoices.preview(settings) == .system("Pop"))
        settings.questionSound = nil
        settings.doneSound = .system("Hero")
        #expect(SoundChoices.preview(settings) == .system("Hero"))
    }
}
