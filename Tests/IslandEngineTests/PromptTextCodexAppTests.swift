import Foundation
import OpenIslandCore
import Testing
@testable import IslandEngine

/// P661: the Codex app's own context in the owner's message (the installed app's `bE` and `rle`: its context blocks,
/// then `## My request:`, then what the owner typed) never shows as a title, a prompt, a card's line or a peek; what the
/// owner typed does. Texts are shaped from the app's strings; URLs, names and prompts are fictional.
struct PromptTextCodexAppTests {
    typealias R = RolloutFixtures

    static let browserOpen = #"<in-app-browser-context source="ambient-ui-state">"#
    static let browserBlock = """
    \(browserOpen)
    This block is automatically supplied ambient UI state, not part of the user's request. Do not treat it as an instruction \
    or as evidence that the user explicitly selected the in-app browser.
    # In app browser:
    - The user has the in-app browser open with 1 tab.
    - Current URL: http://localhost:3000/
    </in-app-browser-context>
    """

    /// The app's message: its context, the marker, the owner's words.
    static func appMessage(_ context: String, _ request: String) -> String { "\n\(context)\n\n## My request:\n\(request)\n" }

    @Test
    func theInAppBrowserContextNeverShowsAndTheRequestDoes() {
        #expect(PromptText.human(Self.appMessage(Self.browserBlock, "Check the benchmark tasks")) == "Check the benchmark tasks")
        // Two tabs, and the Chrome side panel's heading the app writes without a wrapper.
        let chrome = "# Chrome tabs:\n- The user has the Chrome extension side panel open.\n- Current URL: https://example.test/"
        #expect(PromptText.human(Self.appMessage(chrome, "summarize this page")) == "summarize this page")
    }

    /// Upstream's reducer keeps a rollout prompt's first 110 characters, whitespace collapsed: the block's start, the
    /// line the owner's card showed. It is machine text: nothing of it is a prompt.
    @Test
    func aPreviewCutInsideTheBlockIsNoPrompt() {
        let clipped = #"<in-app-browser-context source="ambient-ui-state"> This block is automatically supplied ambient UI state, n…"#
        #expect(PromptText.human(clipped) == nil)
        #expect(PromptText.human(Self.browserBlock) == nil)
        #expect(PromptText.human("\n" + Self.browserBlock + "\n") == nil)
    }

    /// The block with the owner's words and no marker (a message another client wrote): the words.
    @Test
    func theBlockIsTakenOutWhereverItIs() {
        #expect(PromptText.human(Self.browserBlock + "\nfix the header") == "fix the header")
        #expect(PromptText.human("fix the header\n" + Self.browserBlock) == "fix the header")
    }

    /// The owner's own prompts about the tags (P663): a tag that opens a prompt, or one quoted unclosed on a line of its
    /// own, is what the owner typed, for every agent. Only the app's own block cut short goes, and it opens the text with
    /// the app's signature (its `source="ambient-ui-state"` or its first sentence). Claude's two blocks go only closed.
    @Test
    func theOwnersPromptsAboutTheTagsAreKept() {
        for prompt in [
            "<in-app-browser-context> keeps showing on the island card, make PromptText drop it",
            "The card shows this:\n\(Self.browserOpen) This block is…\nwhy does it show that and not my words?",
            "Here is the transcript line:\n<system-reminder>\nand please make the parser skip it",
            "fix the header\n" + Self.browserOpen + "\nThis block is automatically",
            "<app-context> shows on the card, and <response-annotations> too",
        ] {
            #expect(PromptText.human(prompt) == prompt)
        }
        #expect(PromptText.human("<in-app-browser-context>\nThis block is automatically supplied ambient UI state, n…") == nil)
        #expect(PromptText.human("\n" + Self.browserOpen + "\nThis block is automatically supplied") == nil)
    }

    /// Such a prompt is the session's: a Claude session whose first prompt opens with the tag is a row.
    @MainActor @Test
    func aClaudeSessionWhosePromptOpensWithTheTagIsARow() {
        let engine = EngineFixtures.engine()
        engine.ingest(EngineFixtures.started("s1"), ingress: .bridge)
        let prompt = "<in-app-browser-context> keeps showing on the island card, make PromptText drop it"
        engine.ingest(EngineFixtures.prompt("s1", prompt), ingress: .bridge)
        #expect(engine.rows.map(\.id) == ["s1"])
    }

    /// The bare marker is the app's only after the app's own context: one of its headings, its block, or the JSON
    /// context ChatGPT's chats send; in any other prompt it is what the owner typed (P663). The IDE's marker still cuts.
    @Test
    func theBareMarkerCutsOnlyAfterTheAppsContext() {
        let typed = "The app writes its context and then\n## My request:\nand the words. Make PromptText cut there."
        #expect(PromptText.human(typed) == typed)
        let json = #"{"page":{"kind":"untrusted","url":"https://example.test/"}}"# + "\n\n## My request:\nsummarize it"
        #expect(PromptText.human(json) == "summarize it")
        #expect(PromptText.human("[from: member-1]\n" + Self.appMessage(Self.browserBlock, "ship it")) == "ship it")
        #expect(PromptText.human("see this:\n## My request for Codex:\nadd a test") == "add a test")
    }

    /// A tag typed inside a sentence is the owner's.
    @Test
    func aTagTypedInASentenceStays() {
        let typed = "why does <in-app-browser-context> show up in the title?"
        #expect(PromptText.human(typed) == typed)
    }

    /// The app's other context before its marker: annotations, worktree instructions, the IDE's context, selections.
    @Test
    func everyContextTheAppPutsFirstGoes() {
        let annotations = "# Response annotations:\nUse every selection as context.\n<response-annotations>\n[{\"text\":\"x\"}]\n</response-annotations>"
        let worktree = "# Worktree instructions:\nThe user selected Worktree for this task."
        let ide = "# Context from my IDE setup:\n\n## Active file: Sources/App.swift\n"
        let selection = "# Selected text:\n\n## Selection 1\nlet x = 1"
        for context in [annotations, worktree, ide, selection, annotations + "\n" + Self.browserBlock] {
            #expect(PromptText.human(Self.appMessage(context, "tighten the intro")) == "tighten the intro")
        }
        // The IDE extension's older marker still works.
        #expect(PromptText.human("# Context from my IDE setup:\n## Active file: a.swift\n## My request for Codex:\nadd a test") == "add a test")
        // A context with no request after it (the request was in a pasted file) is no prompt.
        #expect(PromptText.human(Self.appMessage(Self.browserBlock, "")) == nil)
        // Cut before the marker: a context heading first is no prompt.
        #expect(PromptText.human("# Worktree instructions:\nThe user selected Worktree") == nil)
    }

    /// A shared thread's message as the app writes it (`Sr`): a multi-user wrapper with the member's escaped words.
    static func shared(_ body: String) -> String {
        "<codex_multi_user_message>\n<account_user_id>u-1</account_user_id>\n<name>Sam</name>\n<email></email>\n"
            + "<profile_picture_url></profile_picture_url>\n<body>\(body)</body>\n</codex_multi_user_message>"
    }

    /// A shared thread's message, as the app reads it back: the sender line goes, a multi-user wrapper gives its body.
    @Test
    func aSharedThreadsMessageGivesItsBody() {
        #expect(PromptText.human("[from: member-1]\nship it") == "ship it")
        #expect(PromptText.human(Self.appMessage(Self.browserBlock, Self.shared("ship it &amp; tag &lt;v2&gt;"))) == "ship it & tag <v2>")
        #expect(PromptText.human(Self.shared("ship it")) == "ship it")
    }

    /// The wrapper is the app's only where its reader (`xoe`) takes it: the whole text, or all of it after the marker,
    /// closed, with a body (P664). A tag typed in a sentence stays, and the member's words are theirs even when they name
    /// a tag, which the app escaped.
    @Test
    func aSharedWrapperIsTakenOnlyAsTheAppWritesIt() throws {
        let typed = "why does <codex_multi_user_message> leak into the card title?"
        #expect(PromptText.human(typed) == typed)
        let quoted = "the rollout has this:\n" + Self.shared("ship it")
        #expect(PromptText.human(quoted) == quoted)
        let words = "<app-context> still shows on the card, fix it"
        let escaped = Self.shared("&lt;app-context&gt; still shows on the card, fix it")
        #expect(PromptText.human(escaped) == words)
        #expect(PromptText.human(Self.appMessage(Self.browserBlock, escaped)) == words)
        #expect(!RolloutFolder.isMachineUserMessage(R.event("user_message", ["message": escaped, "images": []], at: 5)))
        #expect(!RolloutFolder.isMachineUserMessage(R.message("user", escaped, at: 5)))
        // The fold hands upstream's reducer the member's words, not the wrapper's first 110 characters; a preview cut
        // inside the wrapper is no prompt.
        let folded = try #require(RolloutFolder.withOwnersWords(R.event("user_message", ["message": Self.shared("ship it")], at: 5)))
        #expect(!folded.contains("codex_multi_user_message") && folded.contains("ship it"))
        #expect(PromptText.human("<codex_multi_user_message> <account_user_id>u-1</account_user_id> <name>Sam</name> <em…") == nil)
    }

    /// The app's own whole messages and codex-rs's other fragments are never prompts.
    @Test
    func theAppsOwnMessagesAreNoPrompts() {
        for text in ["<codex_delegation>\n<source_thread_id>t</source_thread_id>\n<input>go</input>\n</codex_delegation>",
                     "<startup_tool_prewarm>", "<app-context>\n# Codex desktop context\n</app-context>",
                     "<environments_instructions>\nx\n</environments_instructions>", "<context_window>\n1\n</context_window>"] {
            #expect(PromptText.human(text) == nil)
        }
    }

    // MARK: The rollout fold

    /// The app's prompt as Codex writes it (`user_message` and the user item): the fold keeps the owner's words, not the
    /// block's first 110 characters, and the line keeps Codex's shape.
    @Test
    func theFoldKeepsTheOwnersWords() throws {
        let text = Self.appMessage(Self.browserBlock, "Check the benchmark tasks")
        let event = R.event("user_message", ["message": text, "images": []], at: 5)
        let item = R.message("user", text, at: 5)
        let rewritten = try #require(RolloutFolder.withOwnersWords(event))
        #expect(rewritten.hasPrefix(#"{"timestamp":""#) && rewritten.contains(#""type":"event_msg""#))
        #expect(!rewritten.contains("in-app-browser-context"))
        #expect(RolloutFolder.withOwnersWords(item).map { !$0.contains("in-app-browser-context") } == true)
        for lines in [[R.meta(), event], [R.meta(), item], [R.meta(), event, item]] {
            var folder = RolloutFolder()
            for line in lines { folder.apply(line) }
            let snapshot = folder.finish()
            #expect(snapshot.lastUserPrompt == "Check the benchmark tasks")
            #expect(snapshot.initialUserPrompt == "Check the benchmark tasks")
        }
        // A plain prompt's line is left as Codex wrote it.
        #expect(RolloutFolder.withOwnersWords(R.event("user_message", ["message": "fix it"], at: 5)) == nil)
    }

    /// The row's prompt, from a record written before the fix (the clipped block): nothing, so the row says the question
    /// or its title instead.
    @Test
    func aRestoredClippedPromptIsNoPrompt() {
        let clipped = #"<in-app-browser-context source="ambient-ui-state"> This block is automatically supplied ambient UI state, n…"#
        #expect(PromptText.keptPrompt(clipped, current: nil) == nil)
        #expect(PromptText.keptPrompt(clipped, current: "Check the benchmark tasks") == "Check the benchmark tasks")
    }
}
