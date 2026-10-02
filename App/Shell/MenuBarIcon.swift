import AppKit
import JuiceCore
import Observation

/// Settings › General › Menu bar icon (spec §4.5, §7 amendment 1): Juice's status item, as Juice's spec §4 has it:
/// three small batteries as a template icon, a red dot while an account needs the owner (a sign-in), and its menu. It
/// exists only while the switch is on (off by default); nothing is created while it is off.
@MainActor
enum StatusMenu {
    enum Action: Equatable, Sendable { case accounts, refreshAll, toggleDesktopPanel, toggleLock, settings, quit }

    struct Item: Equatable {
        var title: String
        var key = ""
        var isEnabled = true
        /// A switch's tick; nil for a plain item.
        var isOn: Bool?
        /// Why a greyed item is greyed, on hover.
        var help: String?
        var action: Action
    }

    /// nil is a separator. Juice's menu: one line per provider with accounts (it opens Accounts) · — · Refresh all (its
    /// progress while one runs) · ✓ Show on desktop · ✓ Lock position · — · Settings… ⌘, · Quit Juice Island ⌘Q.
    static func items(usage: any UsageModel, settings: AppSettings) -> [Item?] {
        let providers: [Item?] = usage.panel.rows.filter { !$0.batteries.isEmpty }.map { row in
            let availability = row.availability.isKnown ? "\(row.availability.available) available" : "availability unknown"
            return Item(title: "\(row.provider.displayName) · \(availability)", action: .accounts)
        }
        let refresh: Item = if let progress = usage.refreshProgress {
            Item(title: "Refreshing \(progress) of \(usage.refreshTotal)…", isEnabled: false, action: .refreshAll)
        } else {
            Item(title: "Refresh all", isEnabled: usage.refreshUnavailableReason == nil, help: usage.refreshUnavailableReason,
                 action: .refreshAll)
        }
        return providers + (providers.isEmpty ? [] : [nil]) + [
            refresh,
            Item(title: "Show on desktop", isOn: settings.panelShowOnDesktop, action: .toggleDesktopPanel),
            Item(title: "Lock position", isOn: settings.panelLocked, action: .toggleLock),
            nil,
            Item(title: "Settings…", key: ",", action: .settings),
            Item(title: "Quit \(Product.name)", key: "q", action: .quit),
        ]
    }

    static func perform(_ action: Action, env: AppEnvironment) {
        switch action {
        case .accounts: env.actions.openSettings(.accounts)
        case .refreshAll: env.usage.refreshAll()
        case .toggleDesktopPanel: env.settings.panelShowOnDesktop.toggle()
        case .toggleLock: env.settings.panelLocked.toggle()
        case .settings: env.actions.openSettings(.general)
        case .quit: env.actions.quit()
        }
    }
}

/// What the switch makes and removes: the status item in the app, a stand-in in tests, which never put an icon in the
/// menu bar.
@MainActor
protocol MenuBarIconHandle: AnyObject {
    func remove()
}

/// Keeps the menu bar icon in line with its switch: made when it turns on, removed when it turns off.
@MainActor
final class MenuBarIconSwitch {
    private(set) var icon: (any MenuBarIconHandle)?
    private let settings: AppSettings
    private let make: @MainActor () -> any MenuBarIconHandle
    private var started = false

    init(settings: AppSettings, make: @escaping @MainActor () -> any MenuBarIconHandle) {
        self.settings = settings
        self.make = make
    }

    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    func stop() {
        started = false
        icon?.remove()
        icon = nil
    }

    private func observe() {
        guard started else { return }
        let on = withObservationTracking { settings.menuBarItem } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        if on, icon == nil { icon = make() }
        if !on, let icon {
            icon.remove()
            self.icon = nil
        }
    }
}

/// The status item: the icon, its red dot and the menu, built each time it opens (`StatusMenu`).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, MenuBarIconHandle {
    private let env: AppEnvironment
    private let item: NSStatusItem
    private let dot = NSView()
    private let actions = MenuActions()
    private var removed = false

    init(env: AppEnvironment) {
        self.env = env
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        item.button?.image = Self.icon()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(red: 1, green: 0.486, blue: 0.459, alpha: 1).cgColor
        dot.layer?.cornerRadius = 3
        dot.frame = CGRect(x: 14, y: 12, width: 6, height: 6)
        dot.isHidden = true
        item.button?.addSubview(dot)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        observeDot()
    }

    func remove() {
        removed = true
        NSStatusBar.system.removeStatusItem(item)
    }

    /// The dot follows the accounts' `attentionNeeded`, whichever usage model runs.
    private func observeDot() {
        guard !removed else { return }
        let needed = withObservationTracking { env.usage.panel.attentionNeeded } onChange: { [weak self] in
            Task { @MainActor in self?.observeDot() }
        }
        dot.isHidden = !needed
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions.reset()
        for entry in StatusMenu.items(usage: env.usage, settings: env.settings) {
            guard let entry else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = actions.item(entry.title, key: entry.key, modifiers: entry.key.isEmpty ? [] : [.command]) { [env] in
                StatusMenu.perform(entry.action, env: env)
            }
            menuItem.isEnabled = entry.isEnabled
            menuItem.toolTip = entry.help
            if let isOn = entry.isOn { menuItem.state = isOn ? .on : .off }
            menu.addItem(menuItem)
        }
    }

    /// Three small horizontal batteries, drawn as a template so the menu bar tints it (Juice's icon).
    static func icon() -> NSImage {
        // 22 pt wide so the third battery's nub fits: three 7 pt steps plus the last nub's own point.
        let image = NSImage(size: CGSize(width: 22, height: 14), flipped: false) { _ in
            for (index, fill) in [CGFloat(0.7), 0.35, 1.0].enumerated() {
                let body = CGRect(x: CGFloat(index) * 7 + 0.5, y: 3.5, width: 5, height: 7)
                let outline = NSBezierPath(roundedRect: body, xRadius: 1.5, yRadius: 1.5)
                outline.lineWidth = 1
                NSColor.black.setStroke()
                outline.stroke()
                NSColor.black.setFill()
                CGRect(x: body.maxX + 0.5, y: body.midY - 1, width: 1, height: 2).fill()
                let inner = body.insetBy(dx: 1.5, dy: 1.5)
                NSBezierPath(roundedRect: CGRect(x: inner.minX, y: inner.minY, width: inner.width * fill, height: inner.height),
                             xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = Product.name
        return image
    }
}
