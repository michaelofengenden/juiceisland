import Carbon.HIToolbox
import Foundation
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Lane c37/keys (P1025 to P1030, P1033): one modifier for the card keys, Control or Option; a key recorded per action
/// with Reset, refused when another of Juice's keys has it, a line when macOS takes it; Keyboard shortcuts, every key off
/// at once; and ⇧ with the system-wide key going back in Switch sessions. Settings in memory or a temporary suite only;
/// no key is ever registered and macOS's own list is never read here.
@MainActor
struct ShortcutKeysTests {
    static let approval = SessionCard.approval(ApprovalCardModel(sessionID: "a", agent: .claude, tool: "Bash", body: .command("git push"),
                                                                  reason: nil, alwaysAllowLabel: "Yes, allow git push in this project",
                                                                  canStop: true))
    static let question = SessionCard.question(QuestionCardModel(sessionID: "q", agent: .claude, topic: nil, question: "Name?",
                                                                  options: [.init(label: "A", description: ""), .init(label: "B", description: "")]))

    private func key(_ c: String, control: Bool = false, shift: Bool = false, command: Bool = false, option: Bool = false,
                     editing: Bool = false, isRepeat: Bool = false) -> IslandKeyPress {
        IslandKeyPress(characters: c, control: control, shift: shift, command: command, option: option, editing: editing, isRepeat: isRepeat)
    }

    // MARK: The keys an owner who never opens the pane has (P1027)

    @Test
    func theStandardKeysAreTodaysKeys() {
        let keys = CardKeys.standard
        #expect(CardKeyAction.allCases.map(keys.display) == ["⌃G", "⌃A", "⌃D", "⌃⇧D", "⌃⇧A", "⌃⇧Y", "⌃⇧N"])
        #expect(keys.optionsDisplay == "⌃1 – ⌃4")
        let settings = AppSettings.ephemeral()
        #expect(settings.cardKeys == .standard)
        #expect(settings.shortcutsEnabled && settings.shortcutModifier == .control && settings.recordedCardKeys.isEmpty)
        // Every key the routers took before still does the same.
        #expect(IslandKeyRouter.command(for: key("a", control: true), card: Self.approval, keys: settings.cardKeys)
            == .approve(sessionID: "a", .allowOnce))
        #expect(IslandKeyRouter.command(for: key("A", control: true, shift: true), card: Self.approval) == .approve(sessionID: "a", .alwaysAllow))
        #expect(IslandKeyRouter.command(for: key("D", control: true, shift: true), card: Self.approval) == .approve(sessionID: "a", .denyAndStop))
        #expect(IslandKeyRouter.command(for: key("g", control: true), card: nil) == .jumpToNextNeedsYou)
        #expect(WindowKeyRouter.command(for: .init(character: "d", control: true), keys: settings.cardKeys) == .decide(.deny))
        #expect(WindowKeyRouter.command(for: .init(character: "2", control: true), keys: settings.cardKeys) == .option(1))
    }

    @Test
    func theKeysAreKeptInDefaultsAndResetGoesBack() throws {
        let suite = "ji-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, identity: .development)
        settings.shortcutModifier = .option
        settings.shortcutsEnabled = false
        settings.recordedCardKeys[.allowAll] = CardKey("l", shift: true)
        settings.recordedCardKeys[.allow] = CardKey("y")
        #expect(defaults.string(forKey: AppSettings.Key.shortcutModifier) == "option")
        #expect(defaults.dictionary(forKey: AppSettings.Key.recordedCardKeys) as? [String: String] == ["allowAll": "shift+l", "allow": "y"])
        let again = AppSettings(defaults: defaults, identity: .development)
        #expect(again.cardKeys == CardKeys(enabled: false, modifier: .option, recorded: [.allowAll: CardKey("l", shift: true), .allow: CardKey("y")]))
        // Reset: the standard key again, and nothing left in the defaults once none is recorded.
        again.recordedCardKeys[.allowAll] = nil
        again.recordedCardKeys[.allow] = nil
        #expect(again.cardKeys.display(.allowAll) == "⌥⇧Y")
        #expect(defaults.object(forKey: AppSettings.Key.recordedCardKeys) == nil)
        // A key or an action this build does not know is dropped; the standard key stands.
        #expect(CardKeys.decode(["allow": "ctrl+a", "later": "b", "deny": "shift+x"]) == [.deny: CardKey("x", shift: true)])
    }

    @Test
    func aCardKeyIsOneCharacter() {
        #expect(CardKey(storage: "a") == CardKey("a") && CardKey(storage: "shift+a") == CardKey("a", shift: true))
        #expect(CardKey(storage: "+") == CardKey("+") && CardKey(storage: "shift++") == CardKey("+", shift: true))
        for bad in ["", "ctrl+a", "shift+", "space", "ab", "shift+shift+a"] { #expect(CardKey(storage: bad) == nil, "\(bad)") }
        for good in ["a", "z", "7", ";", "/", "?", "é"] { #expect(CardKey.takes(good), "\(good)") }
        for bad in [" ", "\r", "\t", "\u{1b}", "\u{F700}", "\u{F704}", "ab"] { #expect(!CardKey.takes(bad), "\(bad)") }
        #expect(CardKeyCheck.refusal(characters: "a", modifiers: .command) == "⌘ keys belong to the menus.")
        #expect(CardKeyCheck.refusal(characters: " ", modifiers: .control) == "Pick a letter, a digit or a sign.")
        #expect(CardKeyCheck.refusal(characters: "\u{F701}", modifiers: []) == "Pick a letter, a digit or a sign.")
        #expect(CardKeyCheck.refusal(characters: "Y", modifiers: [.control, .shift]) == nil)
        // Whatever modifier was held, the character and Shift are what is kept.
        #expect(CardKeyCheck.key(characters: "Y", modifiers: [.option, .shift]) == CardKey("y", shift: true))
    }

    // MARK: Option (P1025)

    @Test
    func optionTakesTheCardKeysAndControlLetsThemGo() {
        let keys = CardKeys(modifier: .option)
        #expect(keys.display(.allow) == "⌥A" && keys.optionsDisplay == "⌥1 – ⌥4" && keys.optionHint(0) == "⌥1")
        #expect(IslandKeyRouter.command(for: key("a", option: true), card: Self.approval, keys: keys) == .approve(sessionID: "a", .allowOnce))
        #expect(IslandKeyRouter.command(for: key("D", shift: true, option: true), card: Self.approval, keys: keys)
            == .approve(sessionID: "a", .denyAndStop))
        #expect(IslandKeyRouter.command(for: key("2", option: true), card: Self.question, keys: keys) == .chooseOption(sessionID: "q", index: 1))
        #expect(IslandKeyRouter.command(for: key("g", option: true), card: nil, keys: keys) == .jumpToNextNeedsYou)
        // Control is now nothing of Juice's, and neither are both at once.
        #expect(IslandKeyRouter.command(for: key("a", control: true), card: Self.approval, keys: keys) == nil)
        #expect(IslandKeyRouter.command(for: key("a", control: true, option: true), card: Self.approval, keys: keys) == nil)
        #expect(WindowKeyRouter.command(for: .init(character: "a", option: true), keys: keys) == .decide(.allowOnce))
        #expect(WindowKeyRouter.command(for: .init(character: "a", control: true), keys: keys) == nil)
        #expect(WindowKeyRouter.command(for: .init(character: "a", option: true, command: true), keys: keys) == nil)
    }

    /// ⌥ and a key type a character in a field (å, ∂, ©): with Option a field being edited keeps every key; with Control
    /// it keeps the answering ones, the jump and the options still act (P138).
    @Test
    func aFieldBeingEditedKeepsTheKeysThatWouldTypeOrAnswer() {
        let option = CardKeys(modifier: .option)
        #expect(IslandKeyRouter.command(for: key("g", option: true, editing: true), card: nil, keys: option) == nil)
        #expect(IslandKeyRouter.command(for: key("1", option: true, editing: true), card: Self.question, keys: option) == nil)
        #expect(IslandKeyRouter.command(for: key("g", control: true, editing: true), card: nil) == .jumpToNextNeedsYou)
        #expect(IslandKeyRouter.command(for: key("1", control: true, editing: true), card: Self.question) == .chooseOption(sessionID: "q", index: 0))
        // A Yes recorded on a field's own key (⌃E, end of line) is still the field's while it is edited.
        let recorded = CardKeys(recorded: [.allow: CardKey("e")])
        #expect(IslandKeyRouter.command(for: key("e", control: true, editing: true), card: Self.approval, keys: recorded) == nil)
        #expect(IslandKeyRouter.command(for: key("e", control: true), card: Self.approval, keys: recorded) == .approve(sessionID: "a", .allowOnce))
        #expect(!WindowKeyRouter.takesWhileEditing(.jumpToNeedsYou, keys: option) && !WindowKeyRouter.takesWhileEditing(.option(0), keys: option))
        #expect(WindowKeyRouter.takesWhileEditing(.jumpToNeedsYou) && !WindowKeyRouter.takesWhileEditing(.answerAll(.allowOnce)))
    }

    // MARK: Recorded keys (P1026, P1028)

    @Test
    func aRecordedKeyTakesThePlaceOfTheStandardOne() {
        let keys = CardKeys(recorded: [.allow: CardKey("y"), .jump: CardKey("j", shift: true)])
        #expect(IslandKeyRouter.command(for: key("y", control: true), card: Self.approval, keys: keys) == .approve(sessionID: "a", .allowOnce))
        #expect(IslandKeyRouter.command(for: key("a", control: true), card: Self.approval, keys: keys) == nil)
        #expect(IslandKeyRouter.command(for: key("J", control: true, shift: true), card: nil, keys: keys) == .jumpToNextNeedsYou)
        #expect(IslandKeyRouter.command(for: key("g", control: true), card: nil, keys: keys) == nil)
        #expect(WindowKeyRouter.command(for: .init(character: "y", control: true), keys: keys) == .decide(.allowOnce))
        #expect(keys.hint(.allow) == "⌃Y" && !keys.isStandard(.allow) && keys.isStandard(.deny))
    }

    @Test
    func aKeyAnotherOfJuicesKeysHasIsRefused() throws {
        let keys = CardKeys.standard
        let global = try #require(KeyCombo(storage: "ctrl+opt+j"))
        #expect(CardKeyCheck.refusal(CardKey("d"), for: .allow, keys: keys, global: nil) == "⌃D is already No on an approval.")
        #expect(CardKeyCheck.refusal(CardKey("a", shift: true), for: .allowAll, keys: keys, global: nil) == "⌃⇧A is already Always allow.")
        #expect(CardKeyCheck.refusal(CardKey("2"), for: .allow, keys: keys, global: nil) == "⌃1 to ⌃4 pick a question's option.")
        #expect(CardKeyCheck.refusal(CardKey("y"), for: .allow, keys: keys, global: nil) == nil)
        // Its own key again is no clash.
        #expect(CardKeyCheck.refusal(CardKey("a"), for: .allow, keys: keys, global: nil) == nil)
        // The key from any app: Option with J is it once Option is the modifier; the jump may share it (⌃G, spec §4.4).
        let option = CardKeys(modifier: .option)
        let optionJ = try #require(KeyCombo(storage: "opt+j"))
        #expect(CardKeyCheck.refusal(CardKey("j"), for: .allow, keys: option, global: optionJ) == "⌥J is the key from any app.")
        #expect(CardKeyCheck.refusal(CardKey("j"), for: .jump, keys: option, global: optionJ) == nil)
        #expect(CardKeyCheck.refusal(CardKey("j"), for: .allow, keys: keys, global: global) == nil)
        // The other way: a system-wide key that is a card key is refused, the jump's allowed.
        #expect(CardKeyCheck.cardAction(for: try #require(KeyCombo(storage: "ctrl+a")), keys: keys) == .allow)
        #expect(CardKeyCheck.cardAction(for: try #require(KeyCombo(storage: "ctrl+g")), keys: keys) == nil)
        // A modifier changed after both were set: the lines say which wins.
        #expect(CardKeyCheck.globalClash(optionJ, keys: CardKeys(modifier: .option, recorded: [.deny: CardKey("j")]))
            == "Also No on an approval in \(Product.name); this key wins.")
        #expect(CardKeyCheck.cardClash(.deny, keys: CardKeys(modifier: .option, recorded: [.deny: CardKey("j")]), global: optionJ)
            == "The key from any app takes it first.")
    }

    /// W3R-3: the way back in Switch sessions is the key from any app with ⇧ (P1033). ⌃Y from any app makes it ⌃⇧Y,
    /// Allow all's own key: the window then only moves the ring back while the button still shows ⌃⇧Y. Both rows say
    /// so, and a card key is not recorded onto the way back.
    @Test
    func theWayBackIsComparedWithTheCardKeys() throws {
        let settings = AppSettings.ephemeral()
        settings.globalJumpKey = "ctrl+y"
        settings.globalJumpEnabled = true
        settings.globalKeyAction = .switcher
        let back = try #require(GlobalKeyAction.backKey(settings))
        let keys = settings.cardKeys
        #expect(back.display == "⌃⇧Y" && keys.combo(.allowAll) == back)
        #expect(WindowKeyRouter.command(for: .init(character: "Y", control: true, shift: true), keys: keys, switchBack: back) == .switchBack)
        #expect(CardKeyCheck.backAction(back, keys: keys) == .allowAll)
        #expect(CardKeyCheck.cardClash(.allowAll, keys: keys, global: KeyCombo(storage: "ctrl+y"), back: back)
            == "Going back in Switch sessions takes it first.")
        #expect(CardKeyCheck.cardClash(.denyAll, keys: keys, global: KeyCombo(storage: "ctrl+y"), back: back) == nil)
        #expect(CardKeyCheck.globalClash(KeyCombo(storage: "ctrl+y"), keys: keys, back: back)
            == "With ⇧ also Allow all approvals in \(Product.name); going back wins.")
        #expect(ShortcutsPane.line(.allowAll, keys: keys, global: KeyCombo(storage: "ctrl+y"), system: .none, back: back)
            == "Going back in Switch sessions takes it first.")
        #expect(ShortcutsPane.globalLine(KeyCombo(storage: "ctrl+y"), problem: nil, refusal: nil, keys: keys, system: .none, back: back)
            == "With ⇧ also Allow all approvals in \(Product.name); going back wins.")
        // Recording a card key onto the way back is refused.
        #expect(CardKeyCheck.refusal(CardKey("y", shift: true), for: .allowAll, keys: CardKeys(recorded: [.allowAll: CardKey("k", shift: true)]),
                                     global: KeyCombo(storage: "ctrl+y"), back: back) == "⌃⇧Y goes back in Switch sessions.")
        // Jump, or no Switch sessions: no way back, no line.
        settings.globalKeyAction = .jump
        #expect(GlobalKeyAction.backKey(settings) == nil)
        #expect(CardKeyCheck.backAction(nil, keys: keys) == nil)
        #expect(CardKeyCheck.cardClash(.allowAll, keys: keys, global: KeyCombo(storage: "ctrl+y"), back: nil) == nil)
    }

    // MARK: macOS's own keys (P1029)

    /// Mission Control's ⌃1 and ⌃2 (Switch to Desktop 1, 2) and ⌃Space, as `CopySymbolicHotKeys` gives them; the key
    /// codes are US's, given here, so no layout is read.
    static let missionControl = SystemShortcuts(
        taken: { [HotKeyCode(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(controlKey)),
                  HotKeyCode(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(controlKey)),
                  HotKeyCode(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey))] },
        code: { combo in
            let codes: [String: Int] = ["1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "a": kVK_ANSI_A, "space": kVK_Space,
                                        "j": kVK_ANSI_J]
            guard let code = codes[combo.key] else { return nil }
            let modifiers = (combo.control ? controlKey : 0) | (combo.option ? optionKey : 0) | (combo.shift ? shiftKey : 0)
                | (combo.command ? cmdKey : 0)
            return HotKeyCode(keyCode: UInt32(code), modifiers: UInt32(modifiers))
        })

    /// Mission Control's desktop keys `numbers` (⌃1 to ⌃4) only, on US key codes.
    static func desktops(_ numbers: [Int]) -> SystemShortcuts {
        let codes = [1: kVK_ANSI_1, 2: kVK_ANSI_2, 3: kVK_ANSI_3, 4: kVK_ANSI_4]
        return SystemShortcuts(taken: { numbers.compactMap { codes[$0] }.map { HotKeyCode(keyCode: UInt32($0), modifiers: UInt32(controlKey)) } },
                               code: missionControl.code)
    }

    @Test
    func aKeyMacOSTakesSaysSo() throws {
        let system = Self.missionControl
        // W3R-7: two keys read "and"; a run of three or more "to"; a gap lists them.
        #expect(ShortcutsPane.optionsLine(keys: .standard, system: system) == "macOS already uses ⌃1 and ⌃2.")
        #expect(ShortcutsPane.optionsLine(keys: .standard, system: Self.desktops([1, 2, 3])) == "macOS already uses ⌃1 to ⌃3.")
        #expect(ShortcutsPane.optionsLine(keys: .standard, system: Self.desktops([1, 2, 4])) == "macOS already uses ⌃1, ⌃2 and ⌃4.")
        #expect(ShortcutsPane.optionsLine(keys: .standard, system: Self.desktops([3])) == "macOS already uses ⌃3.")
        #expect(ShortcutsPane.optionsLine(keys: CardKeys(modifier: .option), system: system) == nil)
        #expect(ShortcutsPane.line(.allow, keys: .standard, global: nil, system: system) == nil)
        let spaced = CardKeys(recorded: [.allow: CardKey("1")])
        #expect(ShortcutsPane.line(.allow, keys: spaced, global: nil, system: system) == "macOS already uses ⌃1.")
        let space = try #require(KeyCombo(storage: "ctrl+space"))
        #expect(ShortcutsPane.globalLine(space, problem: nil, refusal: nil, keys: .standard, system: system) == "macOS already uses ⌃Space.")
        // What says more comes first: a refusal, Keyboard shortcuts off, the system's refusal; ⌃G's warning last.
        #expect(ShortcutsPane.globalLine(space, problem: nil, refusal: nil, keys: CardKeys(enabled: false), system: system)
            == "Off with Keyboard shortcuts.")
        #expect(ShortcutsPane.globalLine(space, problem: "Another app uses ⌃Space.", refusal: nil, keys: .standard, system: system)
            == "Another app uses ⌃Space.")
        let controlG = try #require(KeyCombo(storage: "ctrl+g"))
        #expect(ShortcutsPane.globalLine(controlG, problem: nil, refusal: nil, keys: .standard, system: .none) == KeyCombo.ctrlGWarning)
        #expect(!SystemShortcuts.none.uses(controlG))
    }

    // MARK: Keyboard shortcuts off (P1030)

    @Test
    func keyboardShortcutsOffTakesNoKeyButTheOnesEveryWindowHas() async throws {
        let off = CardKeys(enabled: false)
        for press in [key("a", control: true), key("g", control: true), key("1", control: true), key("Y", control: true, shift: true)] {
            #expect(IslandKeyRouter.command(for: press, card: Self.approval, keys: off, batch: 3) == nil)
        }
        #expect(IslandKeyRouter.command(for: key("u"), card: nil, listing: true, keys: off) == nil)
        #expect(IslandKeyRouter.command(for: key("u"), card: nil, listing: true) == .cycleUsage)
        #expect(IslandKeyRouter.command(for: key("\u{1b}"), card: nil, keys: off) == .close)
        #expect(IslandKeyRouter.command(for: key(IslandKeyRouter.downArrow), card: nil, listing: true, keys: off) == .moveSelection(1))
        #expect(IslandKeyRouter.command(for: key("i", shift: true, command: true), card: nil, keys: off) == .showAsWindow)
        #expect(WindowKeyRouter.command(for: .init(character: "a", control: true), keys: off) == nil)
        #expect(WindowKeyRouter.command(for: .init(character: "\r"), keys: off) == .open)
        // No hint shows a key that does nothing, and no row shows the system-wide key's.
        #expect(off.hint(.allow) == nil && off.optionHint(0) == nil)
        let settings = AppSettings.ephemeral()
        settings.globalJumpEnabled = true
        settings.globalJumpKey = "ctrl+opt+j"
        #expect(SessionCardView.showsJumpHint(settings, problem: nil))
        settings.shortcutsEnabled = false
        #expect(!SessionCardView.showsJumpHint(settings, problem: nil))
        #expect(DenyChoices<EmptyView>.tip(canStop: true, stopKey: off.hint(.denyAndStop)) == "⌥-click to say why")
        #expect(QuestionOptionButton.tooltip(.init(label: "A", description: ""), index: 0, keys: off) == "A")
    }

    /// The system-wide key goes with the rest: registered again when Keyboard shortcuts comes back on.
    @Test
    func keyboardShortcutsOffLetsTheSystemWideKeyGo() async throws {
        let settings = AppSettings.ephemeral(), registrar = RecordingHotKeys()
        let us = try GlobalJumpHotKeyTests.layout("com.apple.keylayout.US")
        let hotKey = GlobalJumpHotKey(settings: settings, registrar: registrar, layout: { us }, jump: {})
        settings.globalJumpKey = "ctrl+opt+j"
        settings.globalJumpEnabled = true
        hotKey.start()
        #expect(hotKey.isRegistered)
        settings.shortcutsEnabled = false
        for _ in 0..<100 where hotKey.isRegistered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!hotKey.isRegistered && registrar.calls.last == .unregister)
        settings.shortcutsEnabled = true
        for _ in 0..<100 where !hotKey.isRegistered { try await Task.sleep(for: .milliseconds(5)) }
        #expect(hotKey.isRegistered)
        hotKey.stop()
    }

    // MARK: ⇧ goes back in Switch sessions (P1033)

    @Test
    func shiftWithTheSystemWideKeyIsTheWayBackOnlyInSwitchSessions() throws {
        let settings = AppSettings.ephemeral()
        settings.globalJumpKey = "ctrl+opt+j"
        settings.globalJumpEnabled = true
        #expect(GlobalKeyAction.backKey(settings) == nil)
        settings.globalKeyAction = .switcher
        let back = try #require(GlobalKeyAction.backKey(settings))
        #expect(back.display == "⌃⌥⇧J")
        settings.shortcutsEnabled = false
        #expect(GlobalKeyAction.backKey(settings) == nil)
        settings.shortcutsEnabled = true
        settings.globalJumpKey = "ctrl+shift+j"
        #expect(GlobalKeyAction.backKey(settings) == nil)

        let press = key("J", control: true, shift: true, option: true)
        #expect(IslandKeyRouter.command(for: press, card: nil, listing: true, switchBack: back) == .switchBack)
        #expect(IslandKeyRouter.command(for: press, card: nil, listing: true) == nil)
        #expect(IslandKeyRouter.command(for: key("j", control: true, option: true), card: nil, listing: true, switchBack: back) == nil)
        #expect(WindowKeyRouter.command(for: .init(character: "J", control: true, shift: true, option: true), switchBack: back) == .switchBack)
        #expect(GlobalKeyAction.switcher.detail == "Again for the next, ⇧ goes back; Return jumps.")
    }

    @Test
    func theWayBackWrapsToTheLastRow() throws {
        let ids = ["a", "b", "c"]
        #expect(RowSelection.cycledBack(nil, in: ids) == "c")
        #expect(RowSelection.cycledBack("a", in: ids) == "c")
        #expect(RowSelection.cycledBack("c", in: ids) == "b")
        #expect(RowSelection.cycledBack("gone", in: ids) == "c")
        #expect(RowSelection.cycledBack("a", in: []) == nil)

        let env = AppEnvironment.demo(sessions: .prototype)
        let sessions = env.sessions
        let folded = RowSelection.islandOrder(sessions, style: .clean, showAll: false)
        try #require(folded.showsFooter)
        let all = RowSelection.islandOrder(sessions, style: .clean, showAll: true).shown
        let up = RowSelection.islandSwitchBack(folded.shown[1].id, sessions: sessions, style: .clean, showAll: false)
        #expect(up.row?.id == folded.shown[0].id && !up.showsAll)
        // From the first row: the last row of all, the rest shown first, as the way forward reaches it.
        let wrap = RowSelection.islandSwitchBack(folded.shown[0].id, sessions: sessions, style: .clean, showAll: false)
        #expect(wrap.row?.id == all.last?.id && wrap.showsAll)

        // The window: the ring goes back through its order.
        let order = RowSelection.windowOrder(env)
        env.windowSelection = order.first
        #expect(WindowKeyRouter.perform(.switchBack, env: env) && env.windowSelection == order.last)
        #expect(WindowKeyRouter.perform(.switchBack, env: env) && env.windowSelection == order[order.count - 2])
    }
}
