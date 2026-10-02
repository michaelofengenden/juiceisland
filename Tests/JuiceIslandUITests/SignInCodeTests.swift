import AppKit
import Foundation
import Testing
@testable import JuiceIslandUI

/// The sign-in code field's small rules. The flow itself (the code reaching the CLI, a refusal, a wrong code, and
/// `submitCode` ignoring blanks) is JuiceCore's `SignInCoordinatorTests`; the field's look is
/// `RRenders.accountsSignInWantsACode`.
@MainActor
struct SignInCodeTests {
    /// What Continue's disabled state and the Return guard test: blanks and line breaks alone are no code.
    @Test func trimmingLeavesOnlyTheCodesText() {
        #expect(SignInCodeField.trimmed(" \n\t ").isEmpty)
        #expect(SignInCodeField.trimmed("  k3y#st4te\n") == "k3y#st4te")
    }

    /// ⌘V into the field comes from the app menu: Settings makes the app regular while it is open, and its Edit menu
    /// has Paste on ⌘V.
    @Test func settingsHasPasteForTheCodeField() throws {
        let menu = MainMenu(env: .demo()).build()
        let edit = try #require(menu.items.compactMap(\.submenu).first { $0.title == "Edit" })
        let paste = try #require(edit.items.first { $0.action == #selector(NSText.paste(_:)) })
        #expect(paste.keyEquivalent == "v" && paste.keyEquivalentModifierMask == .command)
        #expect(ActivationPolicyRule.policy(showAs: .island, dockIconInIslandMode: false, auxiliaryWindowOpen: true) == .regular)
    }
}
