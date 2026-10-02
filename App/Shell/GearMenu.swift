import AppKit

/// The gear's menu, the same in the island and the window (C12: no Lock position): Update first while newer commits
/// exist (the Update control's words while one runs; Restart to Update once the owner is asked; "Updated to <commit>"
/// once after one), which keeps its line and opens the control in Settings › About, starting the update first when it
/// offers one (P807) · Show as the other mode ⌘⇧I · Mute Sounds · — · Snooze's lines (`Snooze.items`: while muted, its
/// end, greyed, and Unmute; Mute for 1 hour, Mute until 08:00), so Window mode, with no pill or header to right-click,
/// shows and ends a snooze too · — · Settings… ⌘, · Quit Juice Island. The window's
/// toolbar already has Update and Show as island as buttons, so its gear leaves them out. One Settings item, on the
/// surface's own pane: the sidebar is one click from the rest. ⌘, from the island is the same item. Quit has ⌘Q only in
/// the window: no island key quits the app (P39). Owner: stream D.
@MainActor
enum GearMenu {
    enum Action: Equatable, Sendable { case update, showAs(ShowAs), toggleSounds, snooze(Snooze.Item), settings(SettingsPane), quit }

    struct Item: Equatable {
        var title: String
        var key = ""
        var modifiers: NSEvent.ModifierFlags = []
        var isEnabled = true
        var action: Action
    }

    /// nil is a separator. `showing`: the mode the gear is shown in.
    static func items(showing: ShowAs, updateTitle: String?, updateEnabled: Bool, soundsMuted: Bool, snooze: [Snooze.Item] = [],
                      locale: Locale = .current, timeZone: TimeZone = .current) -> [Item?] {
        var items: [Item?] = []
        if showing == .island {
            if let updateTitle {
                items += [Item(title: updateTitle, isEnabled: updateEnabled, action: .update), nil]
            }
            items.append(Item(title: "Show as Window", key: "i", modifiers: [.command, .shift], action: .showAs(.window)))
        }
        let quit = showing == .window
            ? Item(title: "Quit \(Product.name)", key: "q", modifiers: [.command], action: .quit)
            : Item(title: "Quit \(Product.name)", action: .quit)
        items.append(Item(title: soundsMuted ? "Unmute Sounds" : "Mute Sounds", action: .toggleSounds))
        if !snooze.isEmpty {
            items.append(nil)
            for line in snooze {
                let isHeader = if case .header = line { true } else { false }
                items.append(Item(title: line.title(locale: locale, timeZone: timeZone), isEnabled: !isHeader, action: .snooze(line)))
            }
        }
        return items + [
            nil,
            Item(title: "Settings…", key: ",", modifiers: [.command], action: .settings(showing == .island ? .island : .general)),
            quit,
        ]
    }

    static func items(env: AppEnvironment, showing: ShowAs) -> [Item?] {
        let available = env.updateChecker.available, phase = env.updateController.phase
        let prepared = env.updateController.restartOffered(for: available)
        // Every update line acts: it opens the control, after starting what it says.
        return items(showing: showing, updateTitle: UpdateText.menuTitle(available: available, phase: phase, prepared: prepared,
                                                                         progress: env.updateController.progress),
                     updateEnabled: true, soundsMuted: env.settings.soundsMuted,
                     snooze: Snooze.items(until: env.settings.snoozedUntil, now: Date()))
    }

    static func perform(_ action: Action, env: AppEnvironment) {
        switch action {
        case .update: update(env: env)
        case let .showAs(mode): env.actions.setShowAs(mode)
        case .toggleSounds: env.settings.soundsMuted.toggle()
        case let .snooze(line): Snooze.perform(line, settings: env.settings)
        case let .settings(pane): env.actions.openSettings(pane)
        case .quit: env.actions.quit()
        }
    }

    /// The update line (P807): Restart to Update past ready quits; an offered update (a retry after a failure too)
    /// starts, or installs what a prepare built; then About opens on the control, which shows the run.
    static func update(env: AppEnvironment) {
        let controller = env.updateController
        if controller.phase == .restartNeeded { return controller.restartNow() }
        if UpdateText.offersUpdate(available: env.updateChecker.available, phase: controller.phase) { controller.act() }
        env.actions.openSettings(.about)
    }

    /// Pops the menu up at the pointer (the island's gear and the window's).
    static func popUp(env: AppEnvironment, showing: ShowAs, actions: MenuActions) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        actions.reset()
        for item in items(env: env, showing: showing) {
            guard let item else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = actions.item(item.title, key: item.key, modifiers: item.modifiers) { perform(item.action, env: env) }
            menuItem.isEnabled = item.isEnabled
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Closure-backed items for the menus the app builds in AppKit: the gear's and the menu bar icon's.
@MainActor
final class MenuActions: NSObject {
    private var actions: [Int: () -> Void] = [:]

    func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.tag = actions.count
        actions[item.tag] = action
        return item
    }

    /// Drops the last menu's actions, so they do not pile up with every menu shown.
    func reset() { actions.removeAll() }

    @objc private func run(_ sender: NSMenuItem) { actions[sender.tag]?() }
}
