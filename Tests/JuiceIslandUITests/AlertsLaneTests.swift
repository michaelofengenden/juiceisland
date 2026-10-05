import AppKit
import Foundation
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore
import Testing

/// Wave 3's alerts lane (P1000 to P1024): Juice's own sounds, Choose File…, Quiet while presenting and during Focus, the
/// mute rules' Tool, text size 16, and Show model and Show branch on Clean rows. Nothing plays (a `RecordingSoundPlayer`
/// records names; an `NSSound` is made, never played), files live in a temporary support folder, displays and Focus are
/// the tests' own, and no window shows.
@MainActor
@Suite(.serialized)
struct AlertsLaneTests {
    // MARK: Juice's sounds (P1000)

    /// Each of the three is short, soft and starts and ends at silence (no click); each WAV reads back on this Mac.
    @Test func juiceSoundsAreShortSoftAndClean() throws {
        for sound in JuiceSound.allCases {
            let samples = JuiceSoundSynth.samples(sound.notes)
            let seconds = Double(samples.count) / JuiceSoundSynth.sampleRate
            #expect(seconds >= 0.3 && seconds <= 0.55, "\(sound): \(seconds) s")
            let peak = samples.map(abs).max() ?? 0
            #expect(peak > 0.12 && peak <= 0.36, "\(sound): peak \(peak)")
            #expect(abs(samples.first ?? 1) < 0.01 && abs(samples.last ?? 1) < 0.01, "\(sound) clicks")
            let wav = sound.wav
            #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF" && String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
            #expect(wav.count == 44 + samples.count * 2)
            let made = try #require(NSSound(data: wav), "\(sound) does not decode")
            #expect(abs(made.duration - seconds) < 0.02)
        }
        // Made once a run: the same bytes again.
        #expect(JuiceSound.tap.wav == JuiceSound.tap.wav)
    }

    /// The three tell themselves apart by shape: Tap's pitch steps up, Rise's slides up, Settle's falls.
    @Test func juiceSoundsHaveTheirOwnShapes() {
        func pitch(_ samples: [Double], from start: Double, to end: Double) -> Double {
            let a = Int(start * JuiceSoundSynth.sampleRate), b = min(Int(end * JuiceSoundSynth.sampleRate), samples.count)
            var crossings = 0
            for i in (a + 1)..<b where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
            return Double(crossings) / 2 / (end - start)
        }
        let tap = JuiceSoundSynth.samples(JuiceSound.tap.notes)
        let rise = JuiceSoundSynth.samples(JuiceSound.rise.notes)
        let settle = JuiceSoundSynth.samples(JuiceSound.settle.notes)
        // Tap: E5 (659 Hz) then A5 (880 Hz).
        #expect(abs(pitch(tap, from: 0.01, to: 0.1) - 659) < 25 && abs(pitch(tap, from: 0.2, to: 0.3) - 880) < 25)
        // Rise: lower at its start than once its slide is over, and no step between two notes.
        #expect(pitch(rise, from: 0.0, to: 0.04) < 640 && abs(pitch(rise, from: 0.16, to: 0.3) - 880) < 25)
        // Settle: falls to C5 (523 Hz).
        #expect(pitch(settle, from: 0.005, to: 0.06) > 740 && abs(pitch(settle, from: 0.24, to: 0.4) - 523) < 25)
    }

    // MARK: Stored choices (P1000, P1003)

    /// A system sound, a Juice sound and a file keep their values; a Juice sound this build does not know, or a file with
    /// no path, reads as the event's default, never as silence.
    @Test func soundChoicesKeepTheirValues() throws {
        for choice in [SoundChoice.none, .system("Glass"), .juice(.rise), .file("needs-you/Doorbell.aiff")] {
            #expect(SoundChoice(storageValue: choice.storageValue) == choice)
        }
        #expect(SoundChoice(stored: "juice:chime") == nil && SoundChoice(stored: "file:") == nil)
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        fresh.needsYouSound = .juice(.tap)
        fresh.questionSound = .juice(.rise)
        fresh.doneSound = .file("done/Bell.wav")
        let again = AppSettings(defaults: defaults)
        #expect(again.needsYouSound == .juice(.tap) && again.questionSound == .juice(.rise) && again.doneSound == .file("done/Bell.wav"))
        defaults.set("juice:chime", forKey: AppSettings.Key.needsYouSound)
        defaults.set("juice:chime", forKey: AppSettings.Key.questionSound)
        let later = AppSettings(defaults: defaults)
        #expect(later.needsYouSound == AppSettings.defaultNeedsYouSound && later.questionSound == nil)
    }

    /// The pop-ups offer None, Juice's three, the macOS sounds and Choose File…; the face names each choice plainly.
    @Test func thePopUpOffersJuicesSoundsAndAFile() {
        #expect(SoundChoices.options.prefix(4).map(\.1) == ["None", "Tap", "Rise", "Settle"])
        #expect(SoundChoices.options.count == 1 + JuiceSound.allCases.count + SoundChoices.names.count)
        #expect(SoundChoices.lead(sameAsNeedsYou: true).map(\.1) == ["Same as Needs you", "None"])
        #expect(SoundChoices.title(nil, sameAsNeedsYou: true) == "Same as Needs you" && SoundChoices.title(.juice(.settle)) == "Settle")
        #expect(SoundChoices.title(.file("needs-you/Door bell.aiff")) == "Door bell" && SoundChoices.title(.system("Ping")) == "Ping")
    }

    // MARK: Choose File… (P1001, P1002)

    final class Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("ji-sounds-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        /// A real WAV (Juice's Tap) named `name`, outside the support folder.
        func wav(_ name: String) throws -> URL {
            let file = url.appendingPathComponent(name)
            try JuiceSound.tap.wav.write(to: file)
            return file
        }

        var support: URL { url.appendingPathComponent("Support", isDirectory: true) }
    }

    /// A file this Mac plays is copied in as the event's, and a later one takes its place; the original can go.
    @Test func aChosenFileIsCopiedInAndReplacesTheEventsLast() throws {
        let folder = try Folder()
        let first = try folder.wav("Door bell.wav")
        let choice = try SoundFiles.adopt(first, for: .needsYou, support: folder.support).get()
        #expect(choice == .file("needs-you/Door bell.wav"))
        try FileManager.default.removeItem(at: first)
        #expect(SoundFiles.isPlayable("needs-you/Door bell.wav", support: folder.support))
        #expect(SoundLibrary.sound(choice, support: folder.support) != nil)
        let second = try SoundFiles.adopt(try folder.wav("Chime.wav"), for: .needsYou, support: folder.support).get()
        #expect(second == .file("needs-you/Chime.wav"))
        let kept = try FileManager.default.contentsOfDirectory(atPath: SoundFiles.folder(support: folder.support)
            .appendingPathComponent("needs-you").path)
        #expect(kept == ["Chime.wav"])
        // Another event's file is its own.
        #expect(try SoundFiles.adopt(try folder.wav("Chime.wav"), for: .done, support: folder.support).get() == .file("done/Chime.wav"))
        let staged = try FileManager.default.contentsOfDirectory(atPath: SoundFiles.folder(support: folder.support).path)
        #expect(staged.sorted() == ["done", "needs-you"])
    }

    /// Not a sound, empty, over 5 MB or over 10 s: refused with its line, and the event's earlier file stays.
    @Test func aFileThatWillNotDoIsRefusedWithItsLine() throws {
        let folder = try Folder()
        _ = try SoundFiles.adopt(try folder.wav("Keep.wav"), for: .question, support: folder.support).get()
        let text = folder.url.appendingPathComponent("notes.wav")
        try Data("not a sound".utf8).write(to: text)
        #expect(SoundFiles.adopt(text, for: .question, support: folder.support) == .failure(.notASound))
        let empty = folder.url.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        #expect(SoundFiles.adopt(empty, for: .question, support: folder.support) == .failure(.notASound))
        let big = folder.url.appendingPathComponent("big.wav")
        try Data(count: SoundFiles.maxBytes + 1).write(to: big)
        #expect(SoundFiles.adopt(big, for: .question, support: folder.support) == .failure(.tooBig))
        let long = try folder.wav("Long.wav")
        #expect(SoundFiles.adopt(long, for: .question, support: folder.support, playable: { _ in 12 }) == .failure(.tooLong))
        #expect(SoundFiles.adopt(folder.url, for: .question, support: folder.support) == .failure(.notASound))
        #expect(SoundFiles.isPlayable("question/Keep.wav", support: folder.support))
        #expect(SoundFiles.Refusal.tooLong.line == "That sound is over 10 seconds.")
    }

    /// A stored path plays only from right inside its event's folder: never `..`, an absolute path, a folder of no event,
    /// a hidden name or a link out.
    @Test func aStoredPathNeverLeavesTheFolder() throws {
        let folder = try Folder()
        _ = try SoundFiles.adopt(try folder.wav("Ok.wav"), for: .needsYou, support: folder.support).get()
        #expect(SoundFiles.url("needs-you/Ok.wav", support: folder.support) != nil)
        let outside = try folder.wav("Outside.wav")
        for path in ["../Outside.wav", "needs-you/../../Outside.wav", outside.path, "other/Ok.wav", "needs-you/.hidden.wav",
                     "needs-you", "needs-you/a/b.wav", "needs-you/"] {
            #expect(SoundFiles.url(path, support: folder.support) == nil, "\(path)")
            #expect(!SoundFiles.isPlayable(path, support: folder.support), "\(path)")
        }
        let sounds = SoundFiles.folder(support: folder.support)
        try FileManager.default.createSymbolicLink(at: sounds.appendingPathComponent("needs-you/Link.wav"), withDestinationURL: outside)
        #expect(SoundFiles.url("needs-you/Link.wav", support: folder.support) == nil)
        try FileManager.default.createSymbolicLink(at: sounds.appendingPathComponent("done"), withDestinationURL: folder.url)
        #expect(SoundFiles.url("done/Outside.wav", support: folder.support) == nil)
        #expect(SoundFiles.safeName("a/b:c\u{7}.wav") == "a-b-c-.wav" && SoundFiles.safeName("..") == "sound")
        #expect(SoundFiles.safeName(String(repeating: "x", count: 200) + ".wav").count <= 120)
    }

    /// A chosen file that is gone plays the event's default: Glass for Needs you, the Needs you sound for Question, and
    /// silence for Done (whose default is None). One that is there plays itself.
    @Test func aMissingFileFallsBackToTheDefault() throws {
        let folder = try Folder()
        let settings = AppSettings.ephemeral()
        settings.needsYouSound = .file("needs-you/Gone.wav")
        settings.questionSound = .file("question/Gone.wav")
        settings.doneSound = .file("done/Gone.wav")
        func sounds() -> [String?] {
            [SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, settings: settings, support: folder.support),
             SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, isQuestion: true, settings: settings,
                                support: folder.support),
             SignalSounds.sound(for: .done(sessionID: "s"), isCodexAppThread: false, settings: settings, support: folder.support)]
        }
        #expect(sounds() == ["Glass", "Glass", nil])
        settings.needsYouSound = .juice(.tap)
        #expect(sounds() == ["juice:tap", "juice:tap", nil])
        _ = try SoundFiles.adopt(try folder.wav("Here.wav"), for: .done, support: folder.support).get()
        settings.doneSound = .file("done/Here.wav")
        #expect(sounds()[2] == "file:done/Here.wav")
        // A file that cannot be made into a sound plays nothing and breaks nothing.
        #expect(SoundLibrary.sound(.file("needs-you/Gone.wav"), support: folder.support) == nil)
        #expect(SoundLibrary.sound(.none, support: folder.support) == nil)
        #expect(JuiceSound.allCases.allSatisfy { SoundLibrary.sound(.juice($0), support: folder.support) != nil })
        #expect(SoundChoices.preview(settings, support: folder.support) == .juice(.tap))
    }

    /// The live engine plays a Juice sound by its stored name, at the volume.
    @Test func theLiveEnginePlaysAJuiceSound() throws {
        let probe = QuietLaneRig.Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.needsYouSound = .juice(.tap)
        settings.questionSound = .juice(.rise)
        settings.doneSound = .juice(.settle)
        let live = QuietLaneRig.live(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        QuietLaneRig.start("a", folder: "/tmp/project", engine, probe)
        QuietLaneRig.start("q", folder: "/tmp/other", engine, probe)
        engine.ingest(QuietLaneRig.permission("a", "toolu_1", at: probe.now), ingress: .bridge)
        engine.ingest(QuietLaneRig.question("q", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        QuietLaneRig.start("d", folder: "/tmp/third", engine, probe)
        QuietLaneRig.finish("d", engine, probe)
        #expect(player.played == ["juice:tap", "juice:rise", "juice:settle"])
    }

    // MARK: Quiet while presenting and during Focus (P1004 to P1007)

    /// Mirrored quiets only with the switch on; a Focus that quiets always does (its filter is its switch). Either holds
    /// attention as Quiet hours do.
    @Test func aSceneQuietsAsQuietHoursDo() {
        let settings = AppSettings.ephemeral()
        #expect(!settings.quietWhilePresenting)
        let mirrored = QuietScene(mirrored: true), focus = QuietScene(focus: true)
        #expect(!QuietMode.sceneQuiets(settings, scene: mirrored) && QuietMode.sceneQuiets(settings, scene: focus))
        #expect(!QuietMode.holdsAttention(settings, fullScreen: false, scene: mirrored, now: Date()))
        #expect(QuietMode.holdsAttention(settings, fullScreen: false, scene: focus, now: Date()))
        settings.quietWhilePresenting = true
        #expect(QuietMode.sceneQuiets(settings, scene: mirrored) && QuietMode.holdsAttention(settings, fullScreen: false, scene: mirrored, now: Date()))
        #expect(!QuietMode.sceneQuiets(settings, scene: .none))
        // Silent while quiet, as chosen otherwise; Mute still wins.
        settings.doneSound = .system("Hero")
        func sounds(_ scene: QuietScene) -> [String?] {
            [SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, scene: scene, settings: settings),
             SignalSounds.sound(for: .done(sessionID: "s"), isCodexAppThread: false, scene: scene, settings: settings)]
        }
        #expect(sounds(mirrored) == [nil, nil] && sounds(focus) == [nil, nil] && sounds(.none) == ["Glass", "Hero"])
        settings.quietWhilePresenting = false
        #expect(sounds(mirrored) == ["Glass", "Hero"])
    }

    /// The scenes read the display list only while Quiet while presenting is on, and the Focus filter's last word.
    @Test func theScenesReadTheDisplaysOnlyWithTheSwitchOn() {
        let settings = AppSettings.ephemeral(), focus = FocusFilterState()
        var reads = 0
        let scenes = QuietScenes(settings: settings, focus: focus, mirrored: {
            reads += 1
            return true
        })
        #expect(scenes.now() == .none && reads == 0)
        settings.quietWhilePresenting = true
        #expect(scenes.now() == QuietScene(mirrored: true) && reads == 1)
        focus.apply(quiet: true)
        #expect(scenes.now() == QuietScene(mirrored: true, focus: true) && scenes.focusQuiet)
        // One display is never mirrored; two, one of them in a mirror set, are.
        #expect(!DisplayMirroring.anyMirrored([1]) { _ in true })
        #expect(DisplayMirroring.anyMirrored([1, 2]) { $0 == 2 } && !DisplayMirroring.anyMirrored([1, 2]) { _ in false })
        #expect(IslandPaneText.quietWhilePresenting == "While the screen is mirrored.")
        #expect(IslandPaneText.focus(quietNow: true) == "Quiet now, for a Focus.")
        #expect(IslandPaneText.focus(quietNow: false).hasSuffix("as a filter in System Settings › Focus."))
    }

    /// The filter's word: Quiet as its Focus starts, off (its default) as it ends; the launch's read gives way to a word
    /// macOS sent first.
    @Test func theFocusFilterQuietsUntilItsFocusEnds() {
        let state = FocusFilterState()
        state.launchRead(quiet: true)
        #expect(state.quiet)
        state.apply(quiet: false)
        #expect(!state.quiet)
        state.launchRead(quiet: true)
        #expect(!state.quiet)
        state.apply(quiet: true)
        #expect(state.quiet)
    }

    /// With the live engine: nothing sounds while a Focus quiets the island, and the next request sounds once it ends.
    @Test func whileAFocusQuietsNothingSounds() throws {
        let probe = QuietLaneRig.Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        let focus = FocusFilterState()
        let scenes = QuietScenes(settings: settings, focus: focus, mirrored: { false })
        let live = QuietLaneRig.live(probe, settings: settings, player: player, scene: { scenes.now() })
        let engine = try #require(live.engine)
        QuietLaneRig.start("a", folder: "/tmp/project", engine, probe)
        focus.apply(quiet: true)
        engine.ingest(QuietLaneRig.permission("a", "toolu_1", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played.isEmpty)
        focus.apply(quiet: false)
        QuietLaneRig.start("b", folder: "/tmp/other", engine, probe)
        engine.ingest(QuietLaneRig.permission("b", "toolu_2", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played == ["Glass"])
    }

    /// A reminder plays nothing while a scene quiets (the pill still pulses), and Window mode's banner waits; both come
    /// back once the scene is over.
    @Test func remindersAndBannersHoldBackToo() async {
        typealias F = NoticeFixtures
        let presenting = F.settings()
        presenting.quietWhilePresenting = true
        let reminder = FollowUpsTests.Rig(settings: presenting, rows: [F.waiting("a")], cards: ["a": F.approval("a", request: "A1")])
        reminder.followUps.scene = { QuietScene(mirrored: true) }
        reminder.followUps.start()
        reminder.scheduler.advance(by: 60)
        #expect(reminder.followUps.pulse == 1 && reminder.player.played.isEmpty)

        let rig = BannersTests.Rig(showAs: .window)
        rig.banners.start()
        await F.settle { rig.banners.permission != .unknown }
        rig.sessions.rows = [F.waiting("b")]
        rig.sessions.cards = ["b": F.approval("b", request: "B1")]
        rig.banners.scene = { QuietScene(focus: true) }
        rig.banners.released(.needsYou(sessionID: "b"))
        #expect(rig.center.posted.isEmpty)
        rig.banners.scene = { .none }
        rig.banners.released(.needsYou(sessionID: "b"))
        #expect(rig.center.posted.map(\.id) == ["needs:request:B1"])
    }

    // MARK: The mute rules' Tool (P1010)

    /// A tool's whole name, any case, `*` for any run.
    @Test func aToolPatternMatchesWholeNames() {
        let cases: [(String, String, Bool)] = [
            ("Bash", "Bash", true), ("bash", "Bash", true), ("Bash", "BashOutput", false), ("Bash", "MyBash", false),
            ("mcp__github__*", "mcp__github__create_issue", true), ("mcp__github__*", "mcp__gitlab__create_issue", false),
            ("mcp__*", "mcp__x__y", true), ("*Edit", "MultiEdit", true), ("*Edit", "Edit", true), ("*Edit", "Editor", false),
            ("*", "Anything", true), ("**", "Bash", true), ("Web*", "WebFetch", true), ("Web*", "web", true),
            ("a*b*c", "abc", true), ("a*b*c", "aXbYc", true), ("a*b*c", "acb", false), ("*ab*ab", "abab", true),
            ("*ab*ab", "ab", false), (" Bash ", "Bash", true), ("mcp__*__create_*", "mcp__linear__create_issue", true),
        ]
        for (pattern, name, matches) in cases {
            #expect(ToolPattern(pattern).matches(name) == matches, "\(pattern) ~ \(name)")
        }
    }

    /// A Tool rule mutes a session only while an approval waits on that tool: never its running tool, a question, a
    /// finish or a stall. One for one agent spares the others; one with no text mutes nothing.
    @Test func aToolRuleMutesOnlyItsToolsApprovals() {
        func row(_ status: StatusWord, _ agent: GlyphPalette.Agent = .claude, bucket: SessionBucket = .needsYou) -> SessionRow {
            DStub.row("a", agent, bucket, status: status)
        }
        let bash = MuteRule(field: .tool, text: "Bash")
        #expect(bash.matches(row(.needsApproval(tool: "Bash"))))
        #expect(!bash.matches(row(.needsApproval(tool: "Edit"))) && !bash.matches(row(.needsApproval(tool: nil))))
        #expect(!bash.matches(row(.tool(name: "Bash", detail: "make"), bucket: .running)))
        #expect(!bash.matches(row(.question)) && !bash.matches(row(.done, bucket: .done)))
        let codexOnly = MuteRule(field: .tool, text: "Bash", agent: AgentTool.codex.rawValue)
        #expect(!codexOnly.matches(row(.needsApproval(tool: "Bash"))) && codexOnly.matches(row(.needsApproval(tool: "Bash"), .codex)))
        #expect(!MuteRule(field: .tool, text: "  ").matches(row(.needsApproval(tool: "Bash"))))
        #expect(MuteRule(field: .tool, text: "mcp__github__*").matches(row(.needsApproval(tool: "mcp__github__create_issue"))))
        // A card the agent waits on with no prompt of its own is never muted (P931).
        var alone = row(.needsApproval(tool: "Bash"))
        alone.waitsOnIsland = true
        #expect(![bash].mutes(alone))
        #expect(MuteRulesText.prompt(.tool) == "Bash, mcp__github__*…" && MuteRule.Field.tool.label == "Tool")
        #expect(MuteRulesText.empty == "Match a folder, title, prompt or tool")
    }

    /// Kept as the other fields are; a build that knows no Tool leaves the rule out rather than read it as a folder.
    @Test func aToolRuleKeepsItsValue() {
        let rules = [MuteRule(field: .tool, text: "mcp__*", agent: "codex"), MuteRule(field: .folder, text: "notes")]
        #expect(MuteRules.decode(MuteRules.encode(rules)) == rules)
        let older = #"[{"id":"\#(UUID().uuidString)","field":"sound","text":"Bash"},{"id":"\#(UUID().uuidString)","field":"tool","text":"Bash"}]"#
        #expect(MuteRules.decode(older).map(\.field) == [.tool])
    }

    /// With the live engine: a Bash approval a rule mutes plays nothing; an Edit approval in the same folder sounds.
    @Test func aMutedToolsApprovalPlaysNoSound() throws {
        let probe = QuietLaneRig.Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.muteRules = [MuteRule(field: .tool, text: "bash")]
        let live = QuietLaneRig.live(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        QuietLaneRig.start("a", folder: "/tmp/project", engine, probe)
        QuietLaneRig.start("b", folder: "/tmp/project", engine, probe)
        engine.ingest(QuietLaneRig.permission("a", "toolu_1", tool: "Bash", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played.isEmpty)
        engine.ingest(QuietLaneRig.permission("b", "toolu_2", tool: "Edit", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played == ["Glass"])
        #expect(MuteRules.matchCount(live.rows, rules: settings.muteRules) == 1)
    }

    // MARK: Text size 16 (P1012)

    /// 16 is offered and kept; a larger stored value is read as 16. A Clean row is 51 pt at 16, measured live.
    @Test func textSizeGoesUpTo16() throws {
        #expect(IslandSize.textSizes.last == 16 && IslandPaneText.textSizes.last?.1 == "16")
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        fresh.islandTextSize = 16
        #expect(AppSettings(defaults: defaults).islandTextSize == 16)
        defaults.set(19, forKey: AppSettings.Key.islandTextSize)
        #expect(AppSettings(defaults: defaults).islandTextSize == 16)
        let size = IslandSize(width: 480, text: 16)
        #expect(size.rowTitleHeight == 21 && size.rowStatusHeight == 20 && size.text(11) == 15)
        let layout = DMotionRenders.measure(env: .demo(sessions: .prototype), notch: IslandTheme.Metrics.referenceNotch, card: nil, island: size)
        let rows = layout.parts.filter { if case .row = $0.key { true } else { false } }.map(\.value)
        #expect(!rows.isEmpty && rows.allSatisfy { abs($0.height - 51) < 0.5 }, "\(rows.map(\.height))")
    }

    // MARK: Show model and Show branch (P1015)

    static func factsRow() -> SessionRow {
        var row = DStub.row("f", .claude, .running)
        row.facts = RowFacts(model: "Opus 5.5", mode: "plan", progress: "2/5", effort: "high")
        row.branch = "search-index"
        return row
    }

    /// Off by default (the row as it was); each switch adds its own, only when the session reports it; kept.
    @Test func showModelAndBranchStartOffAndShowWhatTheSessionSays() throws {
        let settings = AppSettings.ephemeral()
        #expect(!settings.rowShowsModel && !settings.rowShowsBranch)
        let row = Self.factsRow()
        #expect(CleanRowShown(row, settings: settings).isEmpty)
        settings.rowShowsModel = true
        #expect(CleanRowShown(row, settings: settings) == CleanRowShown(row, branch: false, model: true))
        #expect(CleanRowShown(row, settings: settings).model?.items == ["Opus 5.5", "high"])
        settings.rowShowsBranch = true
        #expect(CleanRowShown(row, settings: settings).branch == "search-index")
        var bare = row
        bare.facts = RowFacts()
        bare.branch = nil
        #expect(CleanRowShown(bare, settings: settings).isEmpty)
        #expect(IslandPaneText.showsRowFactRows(.clean) && !IslandPaneText.showsRowFactRows(.detailed))
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        fresh.rowShowsModel = true
        fresh.quietWhilePresenting = true
        let again = AppSettings(defaults: defaults)
        #expect(again.rowShowsModel && !again.rowShowsBranch && again.quietWhilePresenting)
    }

    /// What the row says, its peek leaves out: the model and its effort, the branch; the mode and progress stay. A peek
    /// left with nothing is none.
    @Test func thePeekLeavesTheRowItsModelAndBranch() throws {
        let row = Self.factsRow()
        let peek = try #require(SessionPeek.make(row: row, clean: true, prompt: nil, reply: nil, replyIsCurrent: true, read: nil))
        #expect(peek.facts.model == "Opus 5.5" && peek.branch == "search-index")
        let left = try #require(peek.leaving(model: true, branch: true))
        #expect(left.facts.model == nil && left.facts.effort == nil && left.branch == nil && left.facts.mode == "plan")
        #expect(peek.leaving(model: false, branch: false) == peek)
        var plain = row
        plain.facts = RowFacts(model: "Opus 5.5")
        let only = try #require(SessionPeek.make(row: plain, clean: true, prompt: nil, reply: nil, replyIsCurrent: true, read: nil))
        #expect(only.leaving(model: true, branch: true) == nil)
    }

    /// A Clean card's header naming the branch takes "branch <name>" off the reason line; anything else stays.
    @Test func theReasonLineLeavesTheHeaderItsBranch() {
        #expect(ApprovalCardView.reason("Run the tests · branch search-index", headerBranch: "search-index") == "Run the tests")
        #expect(ApprovalCardView.reason("branch search-index", headerBranch: "search-index") == nil)
        #expect(ApprovalCardView.reason("Run the tests · branch other", headerBranch: "search-index") == "Run the tests · branch other")
        #expect(ApprovalCardView.reason("Run the tests · branch search-index", headerBranch: nil) == "Run the tests · branch search-index")
    }
}
