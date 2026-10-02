import AppKit

extension UpdateController {
    /// The app's controller: the stamped repository and commit, this process and bundle; quits through the main run
    /// loop (`AppQuit`, P98), opens the log by path, and checks again when the script finds the build already up to
    /// date. The hourly check holds off while an update runs, so its fetch never races the script's, and each check's
    /// result may start a prepare (P710), behind Settings › About's switch; the What's new card's record is a setting.
    static func app(stamp: BuildStamp, checker: UpdateChecker, settings: AppSettings) -> UpdateController {
        // The settings live as long as the app (and hold nothing of this controller's).
        let context = Context(prepareEnabled: { [settings] in settings.prepareUpdates },
                              latest: { [weak checker] in checker?.available },
                              shownWhatsNew: { [settings] in settings.whatsNewShown },
                              markWhatsNewShown: { [settings] in settings.whatsNewShown = $0 })
        let controller = UpdateController(repoPath: stamp.repoPath, build: stamp.shortCommit, commit: stamp.commit,
                                          quit: { AppQuit.request() }, openFile: { NSWorkspace.shared.open($0) },
                                          recheck: { [weak checker] in checker?.checkNow() }, context: context)
        checker.holds = { [weak controller] in controller?.phase.isRunning ?? false }
        checker.checked = { [weak controller] in controller?.considerPreparing() }
        return controller
    }
}
