import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// OpenCode writes text parts of its own into the owner's user message (`synthetic: true`,
/// `packages/opencode/src/session/prompt.ts` and `compaction.ts`): an @-mentioned file becomes "Called the Read tool
/// with the following input: …" and the Read tool's output (`<path>…</path>\n<type>file</type>\n<content>…`), a `!`
/// command "The following tool was executed by the user", an @agent " Use the above message and context to generate
/// a prompt and call the task tool with subagent: …", an auto-compaction "Continue if you have next steps, …". The
/// plugin (`open-island-opencode.js`, `message.part.updated`) sends every user text part as a UserPromptSubmit, never
/// looking at `synthetic`, so the last of them became the row's prompt (P155). Texts fictional, in those shapes.
@MainActor
struct OpenCodeSyntheticPromptTests {
    nonisolated static let synthetic = [
        #"Called the Read tool with the following input: {"filePath":"/tmp/notes-site/src/a.ts"}"#,
        "<path>/tmp/notes-site/src/a.ts</path>\n<type>file</type>\n<content>\n1: export const a = 1\n\n(End of file - total 1 lines)\n</content>",
        "The following tool was executed by the user",
        " Use the above message and context to generate a prompt and call the task tool with subagent: general",
        "Summarize the task tool output above and continue with your task.",
        "Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed.",
    ]

    @Test(arguments: synthetic)
    func openCodesOwnTextIsNeverAPrompt(_ text: String) {
        #expect(PromptText.human(text) == nil)
    }

    @Test
    func anOpenCodeRowKeepsTheOwnersPromptAfterAnAtMention() {
        let feed = FixtureSessionFeed(scenario: .agentQuestion)
        let id = "opencode-ses_demo_mention"
        var events = FixtureSessionFeed.openCodeStart(id, project: "notes-site", prompt: "explain @src/a.ts", at: feed.now - 60)
        for (index, text) in Self.synthetic.prefix(2).enumerated() {
            events += FixtureSessionFeed.openCodeStart(id, project: "notes-site", prompt: text, at: feed.now - 50 + Double(index)).dropFirst()
        }
        #expect(feed.engine.loadPreviewEvents(events))
        let model = feed.makeModel()
        #expect(model.row(id: id)?.lastPrompt == "explain @src/a.ts")
    }
}
