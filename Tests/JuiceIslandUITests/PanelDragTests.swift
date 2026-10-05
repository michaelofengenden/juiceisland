import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The unlocked desktop panel drags itself (P1200 to P1203): a press anywhere on the panel that moves past the threshold
/// moves the window with the pointer, a press that does not move keeps its click, locked nothing moves, and the drag is
/// remembered per display as the owner's. Headless: the window is created and never ordered on screen, its events are
/// built here and handed to it, and its pointer is the test's.
@MainActor
struct PanelDragTests {
    // MARK: The rule

    @Test func aPressBecomesADragOnlyPastTheThreshold() {
        var drag = PanelDrag<String>()
        drag.press("down", at: CGPoint(x: 100, y: 100), origin: CGPoint(x: 10, y: 20))
        #expect(drag.isHolding && !drag.isMoving)
        // Within 4 pt, however it wanders: still a press.
        #expect(drag.drag(to: CGPoint(x: 103, y: 100)) == nil)
        #expect(drag.drag(to: CGPoint(x: 102, y: 102.5)) == nil)
        #expect(drag.drag(to: CGPoint(x: 100, y: 96)) == nil)
        #expect(!drag.isMoving)
        // Past it: a drag, the grabbed point kept under the pointer (the window moves by the whole way, threshold included).
        #expect(drag.drag(to: CGPoint(x: 105, y: 100)) == CGPoint(x: 15, y: 20))
        #expect(drag.isMoving)
        // Once moving, every step follows, back over the start too.
        #expect(drag.drag(to: CGPoint(x: 101, y: 99)) == CGPoint(x: 11, y: 19))
        #expect(drag.drag(to: CGPoint(x: 400, y: -50)) == CGPoint(x: 310, y: -130))
        guard case .drop = drag.release() else { Issue.record("a drag drops"); return }
        #expect(!drag.isHolding)
    }

    @Test func aPressThatNeverMovesIsAClickAndNothingHeldIsNothing() {
        var drag = PanelDrag<String>()
        guard case .none = drag.release() else { Issue.record("nothing held"); return }
        #expect(drag.drag(to: CGPoint(x: 50, y: 50)) == nil)
        drag.press("down", at: CGPoint(x: 0, y: 0), origin: .zero)
        _ = drag.drag(to: CGPoint(x: 2, y: 2))
        guard case .click(let press) = drag.release() else { Issue.record("a still press clicks"); return }
        #expect(press == "down" && !drag.isHolding)
        // Lock position on while a press is held: forgotten.
        drag.press("again", at: .zero, origin: .zero)
        drag.cancel()
        guard case .none = drag.release() else { Issue.record("cancelled"); return }
        #expect(PanelDragRule.threshold == 4)
    }

    // MARK: The real window

    /// A panel window at (100, 100), never shown, its pointer the test's.
    private func window(locked: Bool = false) -> (DesktopPanelWindow, Pointer) {
        _ = NSApplication.shared
        let window = DesktopPanelWindow()
        window.setPanelFrame(CGRect(x: 100, y: 100, width: 362, height: 184))
        window.movesByDragging = !locked
        let pointer = Pointer()
        window.pointer = { pointer.at }
        return (window, pointer)
    }

    final class Pointer { var at = CGPoint.zero }

    /// The real window behind the controller, never ordered on screen: the controller's show and hide only flip a flag,
    /// and everything else is the window's own.
    final class OffscreenPanel: DesktopPanelSurface {
        let window: DesktopPanelWindow
        init(_ window: DesktopPanelWindow) { self.window = window }
        var panelFrame: CGRect { window.panelFrame }
        func setPanelFrame(_ frame: CGRect) { window.setPanelFrame(frame) }
        private(set) var isShown = false
        func show() { isShown = true }
        func hide() { isShown = false }
        var movesByDragging: Bool {
            get { window.movesByDragging }
            set { window.movesByDragging = newValue }
        }
        var isDragging: Bool { window.isDragging }
        var onUserMove: (@MainActor () -> Void)? {
            get { window.onUserMove }
            set { window.onUserMove = newValue }
        }
        var onUserDrop: (@MainActor () -> Void)? {
            get { window.onUserDrop }
            set { window.onUserDrop = newValue }
        }
    }

    private func event(_ type: NSEvent.EventType, _ window: NSWindow, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: 200, y: 100), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Unlocked: a press on a battery's place, moved 60 right and 40 down, moves the window by exactly that, each step the
    /// owner's move; the content never sees the press; nothing takes focus.
    @Test func unlockedThePanelFollowsThePointer() {
        let (window, pointer) = window()
        defer { window.close() }
        var moves = 0
        window.onUserMove = { moves += 1 }
        let start = window.frame
        pointer.at = CGPoint(x: 300, y: 250)
        #expect(window.handle(event(.leftMouseDown, window)).isEmpty)
        pointer.at = CGPoint(x: 302, y: 249)
        #expect(window.handle(event(.leftMouseDragged, window)).isEmpty)
        #expect(window.frame == start && moves == 0 && !window.isDragging)
        pointer.at = CGPoint(x: 330, y: 230)
        #expect(window.handle(event(.leftMouseDragged, window)).isEmpty)
        #expect(window.isDragging && moves == 1)
        pointer.at = CGPoint(x: 360, y: 210)
        #expect(window.handle(event(.leftMouseDragged, window)).isEmpty)
        #expect(window.handle(event(.leftMouseUp, window)).isEmpty)
        #expect(window.frame.origin == CGPoint(x: start.minX + 60, y: start.minY - 40))
        #expect(window.panelFrame == CGRect(x: 160, y: 60, width: 362, height: 184))
        #expect(moves == 2 && !window.isDragging)
        #expect(!window.isKeyWindow && !window.isMainWindow && NSApp.keyWindow !== window)
    }

    /// A press that does not move reaches the content at its release, press then release, as the click it was (a
    /// battery's, the money's); a Control-click (the right-click menu), a right click and a press in the shadow's margin
    /// go on at once.
    @Test func aStillPressKeepsItsClick() {
        let (window, pointer) = window()
        defer { window.close() }
        pointer.at = CGPoint(x: 300, y: 250)
        let down = event(.leftMouseDown, window), up = event(.leftMouseUp, window)
        #expect(window.handle(down).isEmpty)
        pointer.at = CGPoint(x: 301, y: 251)
        #expect(window.handle(event(.leftMouseDragged, window)).isEmpty)
        #expect(window.handle(up) == [down, up])
        let control = event(.leftMouseDown, window, flags: .control)
        #expect(window.handle(control) == [control])
        let controlUp = event(.leftMouseUp, window)
        #expect(window.handle(controlUp) == [controlUp])
        let right = event(.rightMouseDown, window)
        #expect(window.handle(right) == [right])
        // The window's 24 pt margin around the panel: its shadow, not the panel.
        pointer.at = CGPoint(x: 90, y: 250)
        let margin = event(.leftMouseDown, window)
        #expect(window.handle(margin) == [margin])
        #expect(window.panelFrame == CGRect(x: 100, y: 100, width: 362, height: 184))
    }

    /// Locked: every event goes on as it came and nothing moves.
    @Test func lockedNothingMoves() {
        let (window, pointer) = window(locked: true)
        defer { window.close() }
        var moves = 0
        window.onUserMove = { moves += 1 }
        pointer.at = CGPoint(x: 300, y: 250)
        for (type, at) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 300, y: 250)), (.leftMouseDragged, CGPoint(x: 360, y: 200)), (.leftMouseUp, CGPoint(x: 360, y: 200))] {
            pointer.at = at
            let e = event(type, window)
            #expect(window.handle(e) == [e])
        }
        #expect(window.panelFrame == CGRect(x: 100, y: 100, width: 362, height: 184) && moves == 0)
        #expect(!window.isMovableByWindowBackground)
        // Locking while a press is held forgets it: the release goes on alone.
        window.movesByDragging = true
        #expect(window.handle(event(.leftMouseDown, window)).isEmpty)
        window.movesByDragging = false
        let up = event(.leftMouseUp, window)
        #expect(window.handle(up) == [up])
    }

    /// The drag through the controller: remembered for the display the panel was left on, which becomes the chosen one,
    /// and a reading during the drag never pulls it back (P71).
    @Test func theDragIsRememberedPerDisplayAsTheOwners() async {
        let env = AppEnvironment.demo()
        env.settings.panelLocked = false
        let (window, pointer) = window()
        defer { window.close() }
        let store = PanelPositionStore(defaults: nil)
        let main = PanelScreen(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
        let side = PanelScreen(id: "side", name: "Studio", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                               visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415))
        let controller = DesktopPanelController(env: env, store: store, screens: { [main, side] }, makeSurface: { OffscreenPanel(window) })
        controller.apply()
        let placed = window.panelFrame
        #expect(window.movesByDragging)
        pointer.at = CGPoint(x: placed.midX, y: placed.midY)
        _ = window.handle(event(.leftMouseDown, window))
        pointer.at = CGPoint(x: placed.midX + 1500, y: placed.midY + 300)
        _ = window.handle(event(.leftMouseDragged, window))
        // A reading arrives mid-drag: the panel stays under the pointer.
        controller.apply()
        #expect(window.panelFrame.origin == CGPoint(x: placed.minX + 1500, y: placed.minY + 300))
        _ = window.handle(event(.leftMouseUp, window))
        for _ in 0..<40 where store.frame(for: "side") == nil { try? await Task.sleep(for: .milliseconds(25)) }
        #expect(store.frame(for: "side") == CGRect(x: placed.minX + 1500, y: placed.minY + 300, width: placed.width, height: placed.height))
        #expect(env.settings.panelDisplay == "side")
        controller.stop()
    }

    /// A drag held still for longer than the save's 250 ms is not saved under the owner's hand: the panel stays under the
    /// pointer, past the visible frame (into the menu bar) too, and follows the next step; at the drop it is pulled whole
    /// onto the visible frame and saved at once (P1215).
    @Test func aHeldDragIsSavedAtItsDropAndNeverPulledAwayBefore() async {
        let env = AppEnvironment.demo()
        env.settings.panelLocked = false
        let (window, pointer) = window()
        defer { window.close() }
        let store = PanelPositionStore(defaults: nil)
        let main = PanelScreen(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
        let controller = DesktopPanelController(env: env, store: store, screens: { [main] }, makeSurface: { OffscreenPanel(window) })
        controller.apply()
        let placed = window.panelFrame
        pointer.at = CGPoint(x: placed.midX, y: placed.midY)
        _ = window.handle(event(.leftMouseDown, window))
        // 30 pt past the top of the visible frame, then held there.
        let lift = main.visibleFrame.maxY - placed.maxY + 30
        pointer.at = CGPoint(x: placed.midX, y: placed.midY + lift)
        _ = window.handle(event(.leftMouseDragged, window))
        try? await Task.sleep(for: .milliseconds(450))
        #expect(window.panelFrame.origin == CGPoint(x: placed.minX, y: placed.minY + lift))
        #expect(store.frame(for: "main") == nil)
        pointer.at.x += 10
        _ = window.handle(event(.leftMouseDragged, window))
        #expect(window.panelFrame.origin == CGPoint(x: placed.minX + 10, y: placed.minY + lift))
        _ = window.handle(event(.leftMouseUp, window))
        #expect(window.panelFrame.maxY == main.visibleFrame.maxY && window.panelFrame.minX == placed.minX + 10)
        #expect(store.frame(for: "main") == window.panelFrame)
        controller.stop()
    }

    /// Lock position comes on in the middle of a drag: the press is forgotten, and where the panel was left is saved as
    /// the owner's move, as any (P1215).
    @Test func lockingMidDragKeepsWhereItWasLeft() async {
        let env = AppEnvironment.demo()
        env.settings.panelLocked = false
        let (window, pointer) = window()
        defer { window.close() }
        let store = PanelPositionStore(defaults: nil)
        let main = PanelScreen(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
        let controller = DesktopPanelController(env: env, store: store, screens: { [main] }, makeSurface: { OffscreenPanel(window) })
        controller.apply()
        let placed = window.panelFrame
        pointer.at = CGPoint(x: placed.midX, y: placed.midY)
        _ = window.handle(event(.leftMouseDown, window))
        pointer.at = CGPoint(x: placed.midX - 200, y: placed.midY + 100)
        _ = window.handle(event(.leftMouseDragged, window))
        try? await Task.sleep(for: .milliseconds(300))
        env.settings.panelLocked = true
        controller.apply()
        #expect(!window.movesByDragging && !window.isDragging)
        for _ in 0..<40 where store.frame(for: "main") == nil { try? await Task.sleep(for: .milliseconds(25)) }
        let left = CGRect(x: placed.minX - 200, y: placed.minY + 100, width: placed.width, height: placed.height)
        #expect(store.frame(for: "main") == left && window.panelFrame == left)
        controller.stop()
    }

    /// Nothing the pointer rests on during the drag starts the chip's rest; after the drop the next target does, as
    /// ever. (The chip itself is never shown here: each rest is dismissed before its 350 ms.)
    @Test func theChipWaitsOutTheDrag() {
        let (window, pointer) = window()
        defer { window.close() }
        let hover = PanelHoverController(panel: window)
        pointer.at = CGPoint(x: 300, y: 250)
        _ = window.handle(event(.leftMouseDown, window))
        pointer.at = CGPoint(x: 340, y: 250)
        _ = window.handle(event(.leftMouseDragged, window))
        hover.pointer(over: HoverTarget(id: "a", label: "Claude · 57%"))
        #expect(hover.resting == nil)
        _ = window.handle(event(.leftMouseUp, window))
        hover.pointer(over: HoverTarget(id: "b", label: "Codex · 12%"))
        #expect(hover.resting?.id == "b")
        hover.dismiss()
        #expect(hover.resting == nil)
    }
}
