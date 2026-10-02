import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The island's panel never has AppKit work its key view loop out on every change of its views (E2: SwiftUI's
/// `FocusBridge.updateDefaultKeyViewLoop` ran in every frame of a motion), so Tab between a card's fields depends on
/// the panel working it out once: as it becomes key, and when a card's fields come or change while it is key. Panels
/// here hold their views as the island's does (`IslandPanelController.makePanel`: a plain container view as the content
/// view, the hosting view inside it), are never ordered in, and take Tab through their own event path.
@MainActor
struct KeyViewLoopTests {
    /// A window whose content view is a hosting view has AppKit work its loop out on every change (SwiftUI turns it on);
    /// the island's panel keeps it off, whatever its content view.
    @Test func theIslandsPanelDoesNotWorkItsKeyViewLoopOutOnEveryChange() {
        _ = NSApplication.shared
        let hosted = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        hosted.contentView = NSHostingView(rootView: Color.clear)
        #expect(hosted.autorecalculatesKeyViewLoop)
        IslandPanel.configureKeyViewLoop(hosted)
        #expect(!hosted.autorecalculatesKeyViewLoop)
        let island = Self.panel(Color.clear, size: CGSize(width: 200, height: 100))
        #expect(!island.panel.autorecalculatesKeyViewLoop)
        island.close()
    }

    struct Two: View {
        @State var a = ""
        @State var b = ""
        var body: some View {
            VStack { TextField("a", text: $a); TextField("b", text: $b) }.frame(width: 200)
        }
    }

    /// Two fields in the island's panel: with the loop never worked out, Tab stays on the first (so Tab rests on the
    /// panel's own working out); once the panel has become key (`IslandPanel.becomeKey`), it goes to the other, back.
    @Test func tabMovesBetweenFieldsOnceThePanelHasBecomeKey() {
        let size = CGSize(width: 300, height: 200)
        #expect(Self.tabs(Two(), size: size, becomeKey: false) == ["field0", "field0", "field0", "field0"])
        #expect(Self.tabs(Two(), size: size, becomeKey: true) == ["field0", "field1", "field0", "field1"])
    }

    /// The island with a question card showing and a Done card built ahead beside it (out of sight, taking no clicks):
    /// once the panel is key, Tab keeps to the question's field and never reaches the card built ahead.
    @Test func tabInTheIslandsCardKeepsToItsField() {
        let env = AppEnvironment.demo(sessions: .prototype)
        let ui = IslandUIState()
        let question = FixtureSessionFeed.ID.question
        IslandMotionDirector.snap(ui, to: DIslandMotionTests.model(surface: .island), at: 0)
        ui.presentation = .card(sessionID: question)
        ui.card = env.card(for: question)
        ui.aheadCard = env.card(for: FixtureSessionFeed.ID.claudeDone)
        ui.apply([.part(.cardHeader): 1, .part(.cardBody): 1, .header: 1])
        let size = CGSize(width: IslandPanelSizing.canvasWidth, height: 600)
        let root = IslandRootView(ui: ui, notch: DIslandMotionTests.notch, canvas: size, actions: IslandViewActions(), pillClicked: {},
                                  measured: { _ in })
        #expect(Self.tabs(root.environment(env), size: size, becomeKey: true) == ["field0", "field0", "field0", "field0"])
    }

    // MARK: Helpers

    /// An island panel holding `view` as the island's holds its canvas, never ordered in.
    static func panel(_ view: some View, size: CGSize) -> (panel: IslandPanel, hosting: NSView, close: () -> Void) {
        _ = NSApplication.shared
        let panel = IslandPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        IslandPanel.configureKeyViewLoop(panel)
        let container = IslandContainerView(frame: CGRect(origin: .zero, size: size))
        container.autoresizesSubviews = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = CGRect(origin: .zero, size: size)
        container.addSubview(hosting)
        panel.contentView = container
        hosting.layoutSubtreeIfNeeded()
        return (panel, hosting, {
            panel.contentView = nil
            panel.close()
        })
    }

    /// Where focus goes on each of four Tabs from the first text field of `view` in an island panel (`fieldN` in the
    /// order the fields are laid out), the panel told it became key first or not. The loop is off when Tab is pressed.
    static func tabs(_ view: some View, size: CGSize, becomeKey: Bool) -> [String] {
        let (panel, hosting, close) = Self.panel(view, size: size)
        defer { close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        // As AppKit tells it when a click makes it key (the panel is never ordered in here).
        if becomeKey { panel.becomeKey() }
        var fields: [NSView] = []
        func walk(_ view: NSView) {
            if view is NSTextField { fields.append(view) }
            for sub in view.subviews { walk(sub) }
        }
        walk(hosting)
        func name(_ responder: NSResponder?) -> String {
            var responder = responder
            if let text = responder as? NSTextView, text.isFieldEditor, let delegate = text.delegate as? NSView { responder = delegate }
            if let view = responder as? NSView, let index = fields.firstIndex(of: view) { return "field\(index)" }
            return responder.map { String(describing: type(of: $0)) } ?? "nil"
        }
        guard !panel.autorecalculatesKeyViewLoop else { return ["loop on"] }
        guard let first = fields.first, panel.makeFirstResponder(first) else { return ["no field"] }
        var trail: [String] = [name(panel.firstResponder)]
        for _ in 0..<3 {
            guard let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                             isARepeat: false, keyCode: 48) else { return ["no event"] }
            panel.sendEvent(tab)
            trail.append(name(panel.firstResponder))
        }
        return trail
    }
}
