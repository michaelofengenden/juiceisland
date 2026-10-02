import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Claude Code marks pasted text for the model (the hooks docs, UserPromptSubmit input: "that expanded content sits
/// between a `<pasted_content id="…">` line and a `</pasted_content id="…">` line"; the VS Code chat box marks a paste
/// over 800 characters or 2 line breaks). The closing line repeats the id, so it is never `</pasted_content>`, and the
/// generic wrapper rule lets the whole text through with its markers: the row read `<pasted_content id="1">`. The
/// owner's words must show, never the marker (P155). Texts fictional.
struct PromptTextPastedContentTests {
    typealias F = ClaudeFixtures

    static let pasted = "<pasted_content id=\"1\">\nTraceback (most recent call last):\n  File \"app.py\", line 3\nValueError: bad\n</pasted_content id=\"1\">\nwhy does this fail?"

    @Test
    func aPasteMarkerIsNeverShownAsThePrompt() {
        let hook = PromptText.human(Self.pasted)
        #expect(hook != nil)
        #expect(hook?.hasPrefix("<") == false)
        #expect(hook?.contains("pasted_content") == false)
        #expect(hook?.contains("why does this fail?") == true)
        // The bridge's 110-character preview of the same prompt (newlines collapsed), which the engine reads for
        // "Prompt: " activity.
        let preview = String(Self.pasted.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(110)) + "…"
        #expect(PromptText.human(preview)?.hasPrefix("<") == false)
    }

    @Test
    func aTranscriptPromptWithAPasteShowsTheOwnersWords() {
        var fold = ClaudeTranscriptFold(sessionID: F.sessionID, updatedAt: Date())
        fold.apply(F.user(Self.pasted, at: 0))
        #expect(fold.lastUserPrompt?.hasPrefix("<") == false)
        #expect(fold.lastUserPrompt?.contains("pasted_content") == false)
    }
}
