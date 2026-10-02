import Foundation
import ServiceManagement
import Testing
@testable import JuiceIslandUI

/// Stands in for `SMAppService.mainApp`: a status and a record of the calls. Nothing is ever registered for real.
@MainActor
final class FakeLoginItem: LoginItemService {
    enum Call: Equatable { case register, unregister, openSystemSettings }
    var status: SMAppService.Status
    /// What register does to the status: macOS may leave a new item waiting for the owner's approval.
    var registersAs: SMAppService.Status = .enabled
    var refusal: String?
    private(set) var calls: [Call] = []

    init(status: SMAppService.Status) { self.status = status }

    func register() throws {
        calls.append(.register)
        if let refusal { throw NSError(domain: "SMAppServiceErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: refusal]) }
        status = registersAs
    }

    func unregister() throws {
        calls.append(.unregister)
        status = .notRegistered
    }

    func openSystemSettings() { calls.append(.openSystemSettings) }
}

/// Settings › General › Launch at Login (spec §4.5; P65): the installed release build only; the switch shows what
/// macOS says; the owner's choice registers an item once at launch.
@MainActor
struct LaunchAtLoginTests {
    private func make(_ service: FakeLoginItem, settings: AppSettings = .ephemeral(), identity: AppIdentity = .production,
                      path: String = LaunchAtLogin.installedPath) -> LaunchAtLogin {
        LaunchAtLogin(settings: settings, identity: identity, bundlePath: path, service: service)
    }

    /// A development build, and a copy with the production id anywhere but /Applications (a build folder, the update's
    /// previous app), never touch the login item and show no row.
    @Test
    func onlyTheInstalledReleaseBuildHasTheRow() {
        for (identity, path) in [(AppIdentity.development, LaunchAtLogin.installedPath), (.other, LaunchAtLogin.installedPath),
                                 (.production, "/Applications/Juice Island.previous.app"),
                                 (.production, "/tmp/juice-island-test/output/prod.noindex/Juice Island.app")] {
            let service = FakeLoginItem(status: .notRegistered)
            let login = make(service, identity: identity, path: path)
            login.applyAtLaunch()
            login.set(true)
            #expect(!login.isAvailable)
            #expect(service.calls.isEmpty)
        }
    }

    @Test
    func theOwnersChoiceRegistersOnceAtLaunchAndNeverUndoesSystemSettings() {
        let fresh = FakeLoginItem(status: .notRegistered)
        let login = make(fresh)
        #expect(!login.isOn)
        login.applyAtLaunch()
        #expect(fresh.calls == [.register])
        #expect(login.isOn)

        // Turned off in System Settings, or already registered: launch leaves it.
        for status in [SMAppService.Status.requiresApproval, .enabled] {
            let service = FakeLoginItem(status: status)
            make(service).applyAtLaunch()
            #expect(service.calls.isEmpty)
        }
        // The owner turned it off here: launch leaves it off.
        let settings = AppSettings.ephemeral()
        settings.launchAtLogin = false
        let off = FakeLoginItem(status: .notRegistered)
        make(off, settings: settings).applyAtLaunch()
        #expect(off.calls.isEmpty)
    }

    /// P140: removing the item with − in System Settings › Login Items leaves it not registered, as if never; the next
    /// launch (every in-app Update relaunches) leaves it removed, and the stored choice follows. The switch registers
    /// it again.
    @Test
    func anItemTheOwnerRemovedInSystemSettingsStaysRemoved() {
        let settings = AppSettings.ephemeral()
        let service = FakeLoginItem(status: .notRegistered)
        make(service, settings: settings).applyAtLaunch()
        #expect(service.calls == [.register])
        #expect(settings.loginItemRegistered)
        // The owner removes it in System Settings; the app is updated and launches again.
        service.status = .notRegistered
        let relaunched = make(service, settings: settings)
        relaunched.applyAtLaunch()
        #expect(service.calls == [.register])
        #expect(!relaunched.isOn && !settings.launchAtLogin)
        make(service, settings: settings).applyAtLaunch()
        #expect(service.calls == [.register])
        // The switch is the owner's way back.
        relaunched.set(true)
        #expect(service.calls == [.register, .register])
        #expect(relaunched.isOn && settings.launchAtLogin)
        // A registration macOS refused registered nothing: the next launch tries again.
        let refused = AppSettings.ephemeral()
        let refusing = FakeLoginItem(status: .notRegistered)
        refusing.refusal = "Operation not permitted"
        make(refusing, settings: refused).applyAtLaunch()
        #expect(!refused.loginItemRegistered)
        refusing.refusal = nil
        make(refusing, settings: refused).applyAtLaunch()
        #expect(refusing.calls == [.register, .register] && refused.loginItemRegistered)
    }

    @Test
    func theSwitchShowsWhatMacOSSaysAndAnApprovalItWaitsFor() {
        let service = FakeLoginItem(status: .notRegistered)
        service.registersAs = .requiresApproval
        let settings = AppSettings.ephemeral()
        let login = make(service, settings: settings)
        login.set(true)
        #expect(login.isOn && login.needsApproval)
        #expect(login.note == LaunchAtLogin.approvalLine)
        login.openSystemSettings()
        // The owner allows it in System Settings; the pane reads again when the app comes back.
        service.status = .enabled
        login.refresh()
        #expect(login.isOn && !login.needsApproval && login.note == nil)

        login.set(false)
        #expect(!login.isOn && !settings.launchAtLogin)
        #expect(service.calls == [.register, .openSystemSettings, .unregister])
    }

    @Test
    func aRefusalIsShownInMacOSsWordsAndTheSwitchStaysOff() {
        let service = FakeLoginItem(status: .notRegistered)
        service.refusal = "Operation not permitted"
        let login = make(service)
        login.set(true)
        #expect(!login.isOn)
        #expect(login.note == "Operation not permitted")
        service.refusal = nil
        login.set(true)
        #expect(login.isOn && login.note == nil)
    }
}
