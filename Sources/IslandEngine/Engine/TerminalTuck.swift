import CoreGraphics
import Foundation

/// What tucking a folded session's window away, or bringing it back, came to (`TerminalTuck`, P1302).
public enum TuckOutcome: Equatable, Sendable {
    /// The window held this session's tab alone and is in the Dock now; its bounds as the terminal's own script gave
    /// them, when it gave them (the fold's motion starts there).
    case tucked(TuckBounds?)
    /// The window holds other tabs or panes too, or its terminal would not put it in the Dock: it stays as it is, and
    /// its bounds, when the script gave them, let the fold's motion play from it (P1360).
    case stayed(TuckBounds?)
    /// The window is in the Dock already, or its terminal has nothing to tuck: nothing moves.
    case kept
    /// Brought back out of the Dock.
    case restored
    /// No window holds the tab, or the script failed (the terminal is not running, Automation was refused).
    case failed
}

/// A window's bounds as a terminal's script gives them: left, top, right, bottom, in points from the top-left corner of
/// the main display (AppleScript's `bounds`).
public struct TuckBounds: Equatable, Sendable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double

    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    /// The same rectangle in AppKit's screen coordinates (y up from the main display's foot), given that display's
    /// height. nil for an empty one.
    public func frame(mainDisplayHeight: CGFloat) -> CGRect? {
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: mainDisplayHeight - bottom, width: right - left, height: bottom - top)
    }
}

/// Tucks a folded session's terminal window into the Dock, and brings it back, through the terminal's own script
/// (P1302): Terminal by the agent's tty, iTerm by its session (and tty), Ghostty by its terminal id. Only a window that
/// holds this session's tab alone is tucked (one tab, one pane); any other stays where it is. A tmux pane's outer window
/// is not known exactly, so it stays too. Scripts address the app by bundle id (P49), select nothing and activate
/// nothing; they read a window's bounds only, never its contents. Only the app's own engine runs them, on the owner's
/// click (`SessionEngine.fold`, `openFolded`); a headless engine has none.
enum TerminalTuck {
    enum Move: Equatable, Sendable { case tuck, untuck }

    /// Where tucks run, one at a time, off the main thread.
    static let queue = DispatchQueue(label: "juice-island.tuck", qos: .userInitiated)

    static let live: @Sendable (Move, ReplyRoute) -> TuckOutcome = { move, route in
        guard let script = script(move, route) else { return .kept }
        guard let output = try? JumpRunner.osascript(script, 5) else { return .failed }
        return parse(output)
    }

    /// The script for `move` on `route`'s window; nil where nothing is tucked (a tmux pane).
    static func script(_ move: Move, _ route: ReplyRoute) -> String? {
        switch route {
        case .tmux:
            return nil
        case let .terminal(tty):
            let tty = ExactJump.escape(tty)
            return wrap(ExactJump.terminalBundleID, """
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        if (tty of aTab as text) is "\(tty)" then
                            \(body(move, alone: "(count of tabs of aWindow) is 1"))
                        end if
                    end repeat
                end repeat
            """)
        case let .iterm(sessionID, tty):
            let id = ExactJump.escape(sessionID), tty = ExactJump.escape(tty)
            return wrap(ExactJump.itermBundleID, """
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if (id of aSession as text) is "\(id)" then
                                if "\(tty)" is not "" and (tty of aSession as text) is not "\(tty)" then return ""
                                \(body(move, alone: "(count of tabs of aWindow) is 1 and (count of sessions of aTab) is 1"))
                            end if
                        end repeat
                    end repeat
                end repeat
            """)
        case let .ghostty(terminalID):
            let id = ExactJump.escape(terminalID)
            return wrap(ExactJump.ghosttyBundleID, """
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aTerminal in terminals of aTab
                            if (id of aTerminal as text) is "\(id)" then
                                \(body(move, alone: "(count of tabs of aWindow) is 1 and (count of terminals of aTab) is 1"))
                            end if
                        end repeat
                    end repeat
                end repeat
            """)
        }
    }

    /// What is done to the window once the tab is found: its bounds read first, in a `try` (a terminal that has none
    /// still tucks), so a window that stays gives them too (P1360); then tucked only when `alone` holds and it is not in
    /// the Dock yet, or brought back.
    private static func body(_ move: Move, alone: String) -> String {
        let sep = "(ASCII character 31)"
        switch move {
        case .tuck:
            return """
            set b to {}
                                try
                                    set b to bounds of aWindow
                                end try
                                set placed to ""
                                if (count of b) is 4 then set placed to \(sep) & (item 1 of b as text) & \(sep) & (item 2 of b as text) & \(sep) & (item 3 of b as text) & \(sep) & (item 4 of b as text)
                                if not (\(alone)) then return "stayed" & placed
                                try
                                    if miniaturized of aWindow then return "kept"
                                end try
                                try
                                    set miniaturized of aWindow to true
                                on error
                                    return "stayed" & placed
                                end try
                                return "tucked" & placed
            """
        case .untuck:
            return """
            try
                                    if miniaturized of aWindow then set miniaturized of aWindow to false
                                end try
                                return "restored"
            """
        }
    }

    private static func wrap(_ bundleID: String, _ body: String) -> String {
        """
        tell application id "\(bundleID)"
            if not (it is running) then return ""
        \(body)
        end tell
        return ""
        """
    }

    /// The script's answer: "tucked" or "stayed" and the bounds, "kept", "restored"; anything else (nothing found)
    /// failed.
    static func parse(_ output: String) -> TuckOutcome {
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ExactJump.separator)
        let numbers = parts.dropFirst().compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let bounds = numbers.count == 4 ? TuckBounds(left: numbers[0], top: numbers[1], right: numbers[2], bottom: numbers[3]) : nil
        switch parts.first {
        case "tucked": return .tucked(bounds)
        case "stayed": return .stayed(bounds)
        case "kept": return .kept
        case "restored": return .restored
        default: return .failed
        }
    }
}
