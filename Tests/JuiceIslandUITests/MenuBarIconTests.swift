import Foundation
import Testing
@testable import JuiceIslandUI

/// Stands in for the status item: nothing is put in the menu bar.
@MainActor
private final class FakeIcon: MenuBarIconHandle {
    private(set) var removed = false
    func remove() { removed = true }
}

/// Settings › General › Menu bar icon (spec §4.5, §7 amendment 1; Juice spec §4): the icon exists only while the switch
/// is on, and its menu is Juice's.
@MainActor
struct MenuBarIconTests {
    @Test
    func theIconExistsOnlyWhileTheSwitchIsOn() async throws {
        let settings = AppSettings.ephemeral()
        var made: [FakeIcon] = []
        let icon = MenuBarIconSwitch(settings: settings) {
            let icon = FakeIcon()
            made.append(icon)
            return icon
        }
        icon.start()
        #expect(made.isEmpty && icon.icon == nil)
        settings.menuBarItem = true
        for _ in 0..<100 where made.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(made.count == 1 && icon.icon === made.first)
        settings.menuBarItem = false
        for _ in 0..<100 where icon.icon != nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(made.first?.removed == true)
        settings.menuBarItem = true
        for _ in 0..<100 where made.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(made.count == 2)
        icon.stop()
        #expect(made.last?.removed == true)
    }

    @Test
    func theMenuIsJuicesWithOneSettingsItem() {
        let env = AppEnvironment.demo()
        env.settings.panelShowOnDesktop = true
        env.settings.panelLocked = false
        let items = StatusMenu.items(usage: env.usage, settings: env.settings)
        let titles = items.map { $0?.title }
        #expect(titles[0]?.hasPrefix("Claude · ") == true && titles[1]?.hasPrefix("Codex · ") == true)
        #expect(Array(titles.dropFirst(2)) == [nil, "Refresh all", "Show on desktop", "Lock position", nil, "Settings…", "Quit Juice Island"])
        // Demo data cannot refresh, and the greyed item says why.
        let refresh = items[3]
        #expect(refresh?.isEnabled == false && refresh?.help == env.usage.refreshUnavailableReason)
        #expect(items[4]?.isOn == true && items[5]?.isOn == false)

        var opened: [SettingsPane] = []
        var quits = 0
        env.actions.openSettings = { opened.append($0) }
        env.actions.quit = { quits += 1 }
        StatusMenu.perform(.accounts, env: env)
        StatusMenu.perform(.settings, env: env)
        StatusMenu.perform(.toggleDesktopPanel, env: env)
        StatusMenu.perform(.toggleLock, env: env)
        StatusMenu.perform(.quit, env: env)
        #expect(opened == [.accounts, .general] && quits == 1)
        #expect(!env.settings.panelShowOnDesktop && env.settings.panelLocked)
    }
}
