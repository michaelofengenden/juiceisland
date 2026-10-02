import AppKit

/// The app menu: About, Settings… ⌘,, Hide, Quit ⌘Q; Edit (for text fields); View › Show as Island/Window ⌘⇧I.
/// In Island mode Quit has no key equivalent, so no island key can quit the app (P39). Owner: stream A.
@MainActor
final class MainMenu: NSObject {
    private let env: AppEnvironment
    private var quitItem: NSMenuItem?
    private var showAsItem: NSMenuItem?

    init(env: AppEnvironment) {
        self.env = env
    }

    func build() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: Product.name)
        app.addItem(withTitle: "About \(Product.name)", action: #selector(showAbout), keyEquivalent: "").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(Product.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quit = app.addItem(withTitle: "Quit \(Product.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem = quit
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        let showAs = view.addItem(withTitle: "Show as Island", action: #selector(toggleShowAs), keyEquivalent: "i")
        showAs.keyEquivalentModifierMask = [.command, .shift]
        showAs.target = self
        showAsItem = showAs
        viewItem.submenu = view
        main.addItem(viewItem)
        return main
    }

    func update(showAs: ShowAs) {
        quitItem?.keyEquivalent = showAs == .window ? "q" : ""
        showAsItem?.title = showAs == .window ? "Show as Island" : "Show as Window"
    }

    @objc private func showAbout() { env.actions.openSettings(.about) }
    @objc private func showSettings() { env.actions.openSettings(.general) }
    @objc private func toggleShowAs() { env.actions.setShowAs(env.settings.showAs == .window ? .island : .window) }
}
