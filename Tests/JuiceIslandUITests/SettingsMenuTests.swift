import AppKit
import Testing
@testable import JuiceIslandUI

/// One "Settings…" on every surface (owner, 2026-09-24: "the double settings is still there"): the gear's menu in the
/// island and the window, the usage block's background menu in the island and the window, the desktop panel's menu, the
/// menu bar icon's and the app menu. NSMenus cannot be rendered headless, so the menus' models and titles are tested
/// instead.
@MainActor
struct SettingsMenuTests {
    private static func settingsTitles(_ titles: [String?]) -> [String] {
        titles.compactMap { $0 }.filter { $0.localizedCaseInsensitiveContains("settings") }
    }

    @Test func theGearMenuHasOneSettingsItemOnTheSurfacesPaneAndQuit() {
        let items = GearMenu.items(showing: .island, updateTitle: nil, updateEnabled: false, soundsMuted: false)
        #expect(items.map { $0?.title } == ["Show as Window", "Mute Sounds", nil, "Settings…", "Quit Juice Island"])
        let settings = items[3]
        #expect(settings?.key == "," && settings?.modifiers == [.command] && settings?.action == .settings(.island))
        #expect(items.first??.key == "i" && items.first??.modifiers == [.command, .shift])
        #expect(GearMenu.items(showing: .island, updateTitle: nil, updateEnabled: false, soundsMuted: true)[1]?.title == "Unmute Sounds")
        // No island key quits the app (P39).
        #expect(items.last??.key == "" && items.last??.action == .quit)

        let env = AppEnvironment.demo()
        var opened: [SettingsPane] = []
        var shownAs: [ShowAs] = []
        var quits = 0
        env.actions.openSettings = { opened.append($0) }
        env.actions.setShowAs = { shownAs.append($0) }
        env.actions.quit = { quits += 1 }
        GearMenu.perform(.settings(.island), env: env)
        GearMenu.perform(.showAs(.window), env: env)
        let muted = env.settings.soundsMuted
        GearMenu.perform(.toggleSounds, env: env)
        GearMenu.perform(.quit, env: env)
        #expect(opened == [.island] && shownAs == [.window] && env.settings.soundsMuted != muted && quits == 1)
    }

    /// The window's gear is the island's menu, less what its toolbar already shows as buttons (Update, Show as island).
    @Test func theWindowsGearIsTheIslandsMenuLessItsToolbarButtons() {
        let items = GearMenu.items(showing: .window, updateTitle: "Update Juice Island (3 new changes)", updateEnabled: true,
                                   soundsMuted: false)
        #expect(items.map { $0?.title } == ["Mute Sounds", nil, "Settings…", "Quit Juice Island"])
        #expect(items[2]?.action == .settings(.general))
        #expect(items.last??.key == "q" && items.last??.modifiers == [.command])
    }

    @Test func updateComesFirstAndIsGreyedWhileItRuns() {
        let items = GearMenu.items(showing: .island, updateTitle: "Update Juice Island (3 new changes)", updateEnabled: true, soundsMuted: false)
        #expect(items.map { $0?.title } == ["Update Juice Island (3 new changes)", nil, "Show as Window", "Mute Sounds", nil, "Settings…",
                                            "Quit Juice Island"])
        #expect(items.first??.isEnabled == true && items.first??.action == .update)
        let running = GearMenu.items(showing: .island, updateTitle: "Updating: Building…", updateEnabled: false, soundsMuted: false)
        #expect(running.first??.isEnabled == false)
        #expect(Self.settingsTitles(running.map { $0?.title }) == ["Settings…"])
        // The app's own: an inert checker has nothing newer, so no Update line; the snooze's two choices (P724).
        #expect(GearMenu.items(env: AppEnvironment.demo(), showing: .island).map { $0?.title }
            == ["Show as Window", "Mute Sounds", nil, "Mute for 1 hour", Snooze.Item.mute(.tomorrow).title, nil, "Settings…",
                "Quit Juice Island"])
    }

    @Test func theUsageMenuIsTheSameInTheIslandAndTheWindowWithOneSettingsItem() {
        let env = AppEnvironment.demo()
        env.settings.panelShowOnDesktop = true
        let window = UsageBackgroundMenu.items(usage: env.usage, settings: env.settings, showing: .window)
        let island = UsageBackgroundMenu.items(usage: env.usage, settings: env.settings, showing: .island)
        #expect(window.map { $0?.title } == ["Refresh all", "Desktop panel", nil, "Show as Island", "Settings…"])
        #expect(island.map { $0?.title } == ["Refresh all", "Desktop panel", nil, "Show as Window", "Settings…"])
        #expect(window[1]?.isOn == true && window[3]?.key == "i" && window[3]?.action == .showAs(.island))
        #expect(island[3]?.action == .showAs(.window))
        // Demo data cannot refresh.
        #expect(window.first??.isEnabled == false)

        var opened: [SettingsPane] = []
        var shownAs: [ShowAs] = []
        env.actions.openSettings = { opened.append($0) }
        env.actions.setShowAs = { shownAs.append($0) }
        UsageBackgroundMenu.perform(.settings, env: env)
        UsageBackgroundMenu.perform(.showAs(.island), env: env)
        UsageBackgroundMenu.perform(.toggleDesktopPanel, env: env)
        #expect(opened == [.accounts] && shownAs == [.island] && !env.settings.panelShowOnDesktop)
        #expect(UsageBackgroundMenu.items(usage: env.usage, settings: env.settings, showing: .window)[1]?.isOn == false)
    }

    @Test func theAppMenuHasOneSettingsItem() throws {
        let menu = MainMenu(env: AppEnvironment.demo()).build()
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { item in [item.title] + (item.submenu.map(titles) ?? []) }
        }
        let settings = try #require(menu.items.first?.submenu?.items.first { $0.title == "Settings…" })
        #expect(settings.keyEquivalent == "," && settings.keyEquivalentModifierMask == [.command])
        #expect(Self.settingsTitles(titles(menu)) == ["Settings…"])
    }

    @Test func everyMenuOffersExactlyOneSettingsItem() {
        let env = AppEnvironment.demo()
        let menus: [[String?]] = [
            GearMenu.items(showing: .island, updateTitle: "Update Juice Island (1 new change)", updateEnabled: true, soundsMuted: false)
                .map { $0?.title },
            GearMenu.items(showing: .window, updateTitle: nil, updateEnabled: false, soundsMuted: false).map { $0?.title },
            UsageBackgroundMenu.items(usage: env.usage, settings: env.settings, showing: .window).map { $0?.title },
            UsageBackgroundMenu.items(usage: env.usage, settings: env.settings, showing: .island).map { $0?.title },
            PanelMenu.items(usage: env.usage, settings: env.settings).map { $0?.title },
            StatusMenu.items(usage: env.usage, settings: env.settings).map { $0?.title },
        ]
        for menu in menus {
            #expect(Self.settingsTitles(menu) == ["Settings…"], "\(menu)")
        }
    }
}
