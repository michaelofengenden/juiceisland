import Foundation
import Observation
import ServiceManagement

/// What Launch at Login needs from macOS: `SMAppService.mainApp` in the app, a fake in tests, which never register.
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    /// System Settings › General › Login Items.
    func openSystemSettings()
}

/// The running app as its own login item.
@MainActor
final class MainAppLoginItem: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Settings › General › Launch at Login (spec §4.5, on by default), through `SMAppService.mainApp`. Only the installed
/// release build has the row: a development build and a stray copy with the production bundle id (a build folder, the
/// update's `Juice Island.previous.app`) never register themselves, so the item always opens the installed app (P65).
/// The switch shows what macOS says, not what was asked: on while the item is registered, including while the owner
/// still has to allow it in System Settings, which the row says in one line with Open Login Items beside it. The owner's
/// choice is kept (`AppSettings.launchAtLogin`): at launch, while it is on, an item this app never registered is
/// registered, once (`AppSettings.loginItemRegistered`); an item the owner turned off or removed in System Settings is
/// left as it is, as removing one reads as never registered (P140).
@MainActor
@Observable
final class LaunchAtLogin {
    static var installedPath: String { "/Applications/\(Product.name).app" }
    static var approvalLine: String { "Allow \(Product.name) in Login Items." }

    /// The row shows only here: the installed release build.
    let isAvailable: Bool
    /// Registered, whether or not the owner has allowed it yet.
    private(set) var isOn = false
    /// Registered, but not yet allowed in System Settings › Login Items.
    private(set) var needsApproval = false
    /// Why macOS refused the last change, in its own words; nil once one works.
    private(set) var problem: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let service: any LoginItemService

    init(settings: AppSettings, identity: AppIdentity, bundlePath: String, service: any LoginItemService) {
        self.settings = settings
        self.service = service
        isAvailable = identity == .production && bundlePath == Self.installedPath
        refresh()
    }

    static func app(settings: AppSettings) -> LaunchAtLogin {
        LaunchAtLogin(settings: settings, identity: .current, bundlePath: Bundle.main.bundleURL.path, service: MainAppLoginItem())
    }

    /// The row's line: the approval it waits for, or macOS's refusal.
    var note: String? { problem ?? (needsApproval ? Self.approvalLine : nil) }

    /// Reads what macOS says now (the pane asks when it shows and when the app comes back to the front).
    func refresh() {
        guard isAvailable else { return }
        let status = service.status
        isOn = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }

    /// Once at launch: the owner's choice (on by default) registers an item this app never registered. One it did
    /// register that reads as not registered now was removed by the owner in System Settings, and stays removed: the
    /// stored choice follows (P140).
    func applyAtLaunch() {
        // The welcome's Pick a look has the choice: nothing registers before the owner leaves it (P962).
        guard isAvailable, !settings.loginItemAwaitsChoice, service.status == .notRegistered else { return }
        if settings.loginItemRegistered {
            if settings.launchAtLogin { settings.launchAtLogin = false }
            return
        }
        guard settings.launchAtLogin else { return }
        change(on: true)
    }

    /// The switch, and the welcome's Pick a look as the owner leaves it (P962).
    func set(_ on: Bool) {
        settings.loginItemAwaitsChoice = false
        guard isAvailable else { return }
        settings.launchAtLogin = on
        change(on: on)
    }

    /// The welcome's Pick a look, as the owner leaves it (P962): a choice that differs from what macOS says registers or
    /// unregisters the item; one that matches changes nothing there. Outside /Applications the row was not shown, so
    /// nothing was chosen: the wait stays, and only Settings' switch registers it later, as after an early close (P973).
    func chooseAtWelcome(_ on: Bool) {
        guard isAvailable else { return }
        refresh()
        guard on != isOn else {
            settings.loginItemAwaitsChoice = false
            settings.launchAtLogin = on
            return
        }
        set(on)
    }

    func openSystemSettings() { service.openSystemSettings() }

    private func change(on: Bool) {
        do {
            if on {
                try service.register()
                settings.loginItemRegistered = true
            } else {
                try service.unregister()
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        refresh()
    }
}
