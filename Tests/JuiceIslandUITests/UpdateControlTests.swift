import AppKit
import Foundation
import Testing
@testable import JuiceIslandUI

/// The Update control (P803 to P809): each phase is one state with its words, its fill and what a click does in the
/// toolbar and in About; the tooltip says what a click does; a failure's reason in plain words; About shows the control
/// while an update is offered, runs or failed; and the gear menus' line opens the control, starting the update first
/// when it offers one.
@MainActor
@Suite(.serialized)
struct UpdateControlTests {
    static let info = UpdateInfo(newer: 3, subjects: ["Three", "Two", "One"])

    private func state(_ phase: UpdatePhase, available: UpdateInfo? = Self.info, prepared: Bool = false,
                       progress: UpdateProgress? = nil) -> UpdateControlState {
        let progress = progress ?? UpdateProgress.of(phase: phase, install: false, buildStarted: nil, estimate: nil, now: Date())
        return UpdateControlState.of(available: available, phase: phase, prepared: prepared, progress: progress)
    }

    @Test func eachPhaseIsOneStateWithItsWordsFillAndClick() {
        // Offered: the whole control acts.
        #expect(state(.idle) == .offer(restart: false) && state(.idle).words == "Update" && state(.idle).fill == 1)
        #expect(state(.idle, prepared: true).words == "Restart to update")
        #expect(state(.idle).action(in: .toolbar) == .update && state(.idle).action(in: .about) == .update)
        // Nothing offered, nothing run: no control.
        #expect(state(.idle, available: nil) == .hidden && state(.idle, available: nil).action(in: .toolbar) == .none)
        // A run: its words over its fill; the toolbar's click opens About, About's control takes none.
        #expect(state(.pulling) == .running(words: "Fetching", fraction: UpdateProgress.fetching))
        // Waiting for a background prepare (P895): its own words, the fill where the build starts.
        #expect(state(.waiting) == .running(words: "Waiting for build", fraction: UpdateProgress.fetchEnd))
        #expect(state(.waiting).action(in: .toolbar) == .openAbout && state(.waiting).action(in: .about) == .none)
        // Once the wait is over, the updater's checkout moves (P895): its own words, the fill where it was.
        #expect(state(.settingUp) == .running(words: "Setting up", fraction: UpdateProgress.fetchEnd))
        // Past the estimate (P897): still building, the fill held at the build's end.
        let past = state(.building, progress: UpdateProgress(fraction: UpdateProgress.buildEnd, overran: true, busy: true))
        #expect(past == .running(words: "Still building", fraction: UpdateProgress.buildEnd))
        let building = state(.building, progress: UpdateProgress(fraction: 0.6, buildPercent: 63, secondsLeft: 50))
        #expect(building == .running(words: "Building 63%", fraction: 0.6) && building.fill == 0.6)
        #expect(state(.building).words == "Building")
        #expect(state(.installing).words == "Installing")
        #expect(building.action(in: .toolbar) == .openAbout && building.action(in: .about) == .none)
        // Built and checked: whole, Updated, no click while the app goes.
        #expect(state(.restarting) == .finished && state(.restarting).words == "Updated" && state(.restarting).fill == 1)
        #expect(state(.restarting).action(in: .toolbar) == .none && state(.restarting).action(in: .about) == .none)
        // Past ready, still here: Restart to update quits.
        #expect(state(.restartNeeded).words == "Restart to update" && state(.restartNeeded).action(in: .about) == .restartNow)
        // A failure: Update failed, no fill. In About, under the reason and Show Log, the whole control retries; in the
        // toolbar its words open About (the reason, the log) and Retry is its own half (P809).
        let failed = state(.failed(reason: "the build failed"))
        #expect(failed == .failed(reason: "the build failed") && failed.words == "Update failed" && failed.fill == 0)
        #expect(failed.action(in: .toolbar) == .openAbout && failed.action(in: .about) == .retry)
        #expect(failed.hasOwnRetry(in: .toolbar) && !failed.hasOwnRetry(in: .about))
        #expect(!state(.idle).hasOwnRetry(in: .toolbar) && !building.hasOwnRetry(in: .toolbar))
        // After the relaunch: a quiet Updated, which opens About from the toolbar; an update offered again wins.
        #expect(state(.updated("3d74159"), available: nil) == .updated("3d74159"))
        #expect(state(.updated("3d74159"), available: nil).action(in: .toolbar) == .openAbout)
        #expect(state(.updated("3d74159"), available: nil).action(in: .about) == .none)
        #expect(state(.updated("3d74159")) == .offer(restart: false))
        // The fill stays in 0 to 1.
        #expect(UpdateControlState.running(words: "x", fraction: 1.4).fill == 1 && UpdateControlState.running(words: "x", fraction: -1).fill == 0)
    }

    @Test func theTooltipSaysWhatAClickDoes() {
        #expect(state(.idle).help(available: Self.info, progress: .none, place: .toolbar) == "3 changes · click to update")
        #expect(state(.idle, prepared: true).help(available: Self.info, progress: .none, place: .toolbar) == "3 changes · click to restart")
        let progress = UpdateProgress(fraction: 0.6, buildPercent: 63, secondsLeft: 100)
        #expect(state(.building, progress: progress).help(available: Self.info, progress: progress, place: .toolbar)
            == "Building 63% · about 2 min left · click for details")
        #expect(state(.building, progress: progress).help(available: Self.info, progress: progress, place: .about)
            == "Building 63% · about 2 min left")
        // The words in full where the control has no room for them (P898).
        #expect(state(.waiting).help(available: Self.info, progress: UpdateProgress(fraction: UpdateProgress.fetchEnd), place: .toolbar)
            == "Waiting for the background build · click for details")
        let busy = UpdateProgress(fraction: UpdateProgress.buildEnd, overran: true, busy: true)
        #expect(state(.building, progress: busy).help(available: Self.info, progress: busy, place: .toolbar)
            == "Still building, the Mac is busy · click for details")
        let calm = UpdateProgress(fraction: UpdateProgress.buildEnd, overran: true)
        #expect(state(.building, progress: calm).help(available: Self.info, progress: calm, place: .about)
            == "Still building · taking longer than last time")
        let failed = state(.failed(reason: "update-app.sh stopped (exit 9)"))
        #expect(failed.help(available: Self.info, progress: .none, place: .toolbar)
            == "Update failed: The updater stopped (exit 9) · click for details")
        #expect(failed.help(available: Self.info, progress: .none, place: .about)
            == "Update failed: The updater stopped (exit 9) · click to retry")
        #expect(state(.updated("3d74159"), available: nil).help(available: nil, progress: .none, place: .toolbar)
            == "Updated to 3d74159 · click for What's new")
    }

    /// Every word the control says fits its width at its size (P808, P898): the longest running words are "Waiting for
    /// build" and "Still building"; the full ones go to the tooltip, the menus and About.
    @Test func theControlsWordsFitItsWidth() {
        let progresses = [UpdateProgress(fraction: 0.5, buildPercent: 99, secondsLeft: 1),
                          UpdateProgress(fraction: UpdateProgress.buildEnd, overran: true, busy: true), .none]
        var words = Set<String>()
        for phase in [UpdatePhase.pulling, .waiting, .settingUp, .building, .installing] {
            for progress in progresses { words.insert(UpdateControlState.of(available: Self.info, phase: phase, prepared: false, progress: progress).words) }
        }
        #expect(words.contains("Waiting for build") && words.contains("Still building") && words.contains("Building 99%"))
        for (size, weight, width) in [(12.5, NSFont.Weight.medium, UpdateControlFace.Size.toolbar.width), (13, .medium, UpdateControlFace.Size.about.width)] as [(CGFloat, NSFont.Weight, CGFloat)] {
            let font = NSFont.systemFont(ofSize: size, weight: weight)
            // "Restart to update" with its arrow is the widest the control was made for.
            let room = ("Restart to update" as NSString).size(withAttributes: [.font: font]).width + 17
            #expect(room < width)
            for word in words {
                #expect((word as NSString).size(withAttributes: [.font: font]).width <= room, "\(word) at \(size) pt")
            }
            #expect((UpdateText.waitingFull as NSString).size(withAttributes: [.font: font]).width > width - 16, "the full words would not fit")
        }
    }

    @Test func aFailuresReasonInPlainWords() {
        #expect(UpdateText.plainReason("the build failed") == "The build failed")
        #expect(UpdateText.plainReason("can't reach GitHub") == "Can't reach GitHub")
        #expect(UpdateText.plainReason("update-app.sh stopped (exit 3)") == "The updater stopped (exit 3)")
        #expect(UpdateText.plainReason("This build carries no update-app.sh") == "This build has no updater")
        #expect(UpdateText.plainReason("timed out after 15 min") == "Timed out after 15 min")
        #expect(UpdateText.plainReason("") == "")
    }

    @Test func aboutShowsTheControlWhileOfferedRunningOrFailed() {
        #expect(AboutUpdatesSection.showsControl(state(.idle)) && AboutUpdatesSection.showsControl(state(.building)))
        #expect(AboutUpdatesSection.showsControl(state(.restarting)) && AboutUpdatesSection.showsControl(state(.restartNeeded)))
        #expect(AboutUpdatesSection.showsControl(state(.failed(reason: "x"))))
        #expect(!AboutUpdatesSection.showsControl(state(.idle, available: nil)))
        #expect(!AboutUpdatesSection.showsControl(state(.updated("3d74159"), available: nil)))
        // The row says what the update brings; with none known (a failure restored at launch, before the first check
        // ends) it says nothing, rather than "Update" beside "Update failed".
        #expect(AboutUpdatesSection.offerLabel(Self.info) == "3 changes")
        #expect(AboutUpdatesSection.offerLabel(nil) == "")
    }

    /// The menus keep their line, which opens the control: an offered update starts first (here it fails at once: the
    /// controller knows no repository), a run only opens it, and Restart to Update past ready restarts instead.
    @Test func theGearMenusLineOpensTheControl() throws {
        func env(_ controller: UpdateController, opened: @escaping (SettingsPane) -> Void) -> AppEnvironment {
            let checker = UpdateChecker(stamp: BuildStamp(commit: String(repeating: "a", count: 40), date: Date(), repoPath: nil),
                                        git: NoGitRunner(), state: .checked(Self.info, at: Date()))
            let env = AppEnvironment.demo(updateChecker: checker, updateController: controller)
            env.actions.openSettings = { opened($0) }
            return env
        }
        var opened: [SettingsPane] = []
        let offered = UpdateController(repoPath: nil)
        GearMenu.update(env: env(offered) { opened.append($0) })
        #expect(offered.phase.isFailed && opened == [.about])

        let running = UpdateController(repoPath: nil, phase: .building)
        GearMenu.update(env: env(running) { opened.append($0) })
        #expect(running.phase == .building && opened == [.about, .about])

        let asked = UpdateController(repoPath: nil, phase: .restartNeeded)
        GearMenu.update(env: env(asked) { opened.append($0) })
        #expect(asked.phase == .restartNeeded && opened == [.about, .about])

        // Every update line acts: the step while a run goes too.
        let items = GearMenu.items(env: env(running) { _ in }, showing: .island)
        #expect(items.first??.title == "Updating: Building" && items.first??.isEnabled == true)
    }
}
