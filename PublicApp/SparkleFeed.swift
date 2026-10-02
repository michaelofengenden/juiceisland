import AppKit
import JuiceIslandUI
import Sparkle

/// The public flavor's updater (P823 to P826): Sparkle 2 with its own windows hidden. This file is the only one that
/// names Sparkle (guardrail check 8); the private app's target never compiles it and never links the framework.
///
/// Sparkle reads its settings from the Info.plist that `project-public.yml` writes: the feed
/// (`https://github.com/<PUBLIC_REPO>/releases/latest/download/appcast.xml`), the EdDSA public key, a check once a day
/// with no question first, and no download before the owner's click. It reaches that feed and the downloads it names,
/// nothing else. Every step it takes comes here as a user-driver call and goes on as a `FeedUpdateEvent`, which the
/// Update control draws (checking, downloading n%, extracting, installing, then the relaunch).
@MainActor
final class SparkleFeed: NSObject, FeedUpdating, SPUUserDriver, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private var report: (@MainActor (FeedUpdateEvent) -> Void)?
    /// Sparkle's question for the update it found, held until the owner's click.
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    /// An informational update's page: the click opens it instead.
    private var infoURL: URL?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var retryTermination: (() -> Void)?

    /// The updater, or nil when this build carries no feed or no public key: updates are off, and About says so.
    static func make(bundle: Bundle = .main) -> SparkleFeed? {
        func value(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty || $0.contains("$(") ? nil : $0 }
        }
        guard let feed = value("SUFeedURL"), feed.hasPrefix("https://github.com/"), value("SUPublicEDKey") != nil else { return nil }
        return SparkleFeed()
    }

    // MARK: FeedUpdating

    func start(report: @escaping @MainActor (FeedUpdateEvent) -> Void) {
        self.report = report
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        do {
            try updater.start()
        } catch {
            return report(.failed("The updater could not start"))
        }
        self.updater = updater
        if let last = updater.lastUpdateCheckDate { report(.lastChecked(last)) }
    }

    func checkNow() -> Bool {
        guard let updater, updater.canCheckForUpdates else { return false }
        updater.checkForUpdates()
        return true
    }

    func install() -> Bool {
        guard let reply = foundReply else { return false }
        foundReply = nil
        if let infoURL {
            NSWorkspace.shared.open(infoURL)
            reply(.dismiss)
            return false
        }
        reply(.install)
        return true
    }

    func relaunch() {
        if let reply = readyReply {
            readyReply = nil
            reply(.install)
        } else {
            retryTermination?()
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // The Info.plist turns the daily check on, so this is not asked; if it ever is, the answer is the same.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        report?(.checking)
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundReply = reply
        infoURL = appcastItem.isInformationOnlyUpdate ? appcastItem.infoURL : nil
        report?(.found(version: appcastItem.displayVersionString, downloaded: state.stage != .notDownloaded,
                       informational: appcastItem.isInformationOnlyUpdate))
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        report?(.upToDate)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        report?(.failed(error.localizedDescription))
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        report?(.downloadStarted)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        report?(.expectedLength(expectedContentLength))
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        report?(.received(length))
    }

    func showDownloadDidStartExtractingUpdate() {
        report?(.extracting(0))
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        report?(.extracting(progress))
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyReply = reply
        report?(.readyToInstall)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        report?(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        foundReply = nil
        readyReply = nil
        report?(.ended)
    }

    // MARK: SPUUpdaterDelegate

    /// The daily check found nothing (Check now's answer comes through `showUpdateNotFoundWithError` too).
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        MainActor.assumeIsolated { report?(.upToDate) }
    }
}
