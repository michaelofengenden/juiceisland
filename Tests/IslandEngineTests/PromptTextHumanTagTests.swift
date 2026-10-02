import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// A prompt the owner typed that opens with a custom element (a web component, an Angular or Vue tag: the names have
/// a `-` by the HTML rules) is the owner's, whatever the generic wrapper rule guesses: it hid the prompt from the row,
/// kept a new session from surfacing, and never counted as the human prompt that ends the main thread's waits (C8).
@MainActor
struct PromptTextHumanTagTests {
    private typealias F = EngineFixtures
    nonisolated static let typed = "<my-button>Save</my-button> has no padding in Safari, fix it"

    @Test(arguments: [
        typed,
        "<app-root></app-root> renders blank after the upgrade",
        "<router-view /> never shows the page, and </router-view> is closed in App.vue",
    ])
    func aTypedCustomElementIsTheOwnersPrompt(_ text: String) {
        #expect(PromptText.human(text) == text)
    }

    @Test
    func aSessionWhoseFirstPromptOpensWithACustomElementIsSurfaced() {
        let engine = F.engine()
        engine.ingest(F.started("web"), ingress: .bridge)
        engine.ingest(.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: "web", claudeMetadata: ClaudeSessionMetadata(
            initialUserPrompt: Self.typed, lastUserPrompt: Self.typed), timestamp: F.now)), ingress: .bridge)
        engine.ingest(F.prompt("web", Self.typed), ingress: .bridge)
        #expect(engine.rows.map(\.id) == ["web"])
        #expect(engine.state.session(id: "web")?.claudeMetadata?.lastUserPrompt == Self.typed)
    }
}
