import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// Claude Desktop's surfaces (P485): Code sessions (`claude-desktop`, and `claude-desktop-3p` on a third-party
/// provider) and Cowork (`local-agent`) all live in Claude.app and open there; a Cowork request stays read-only (no
/// one has measured that Cowork shows its own prompt while a hook holds, P156), so Open brings Claude forward. No
/// public link opens an existing Cowork session (`claude://cowork/new` only), so Open never names one.
struct ClaudeDesktopSurfaceTests {
    typealias F = ClaudeFixtures
    typealias R = RolloutFixtures

    /// A transcript found on disk: every Claude Desktop entrypoint is tagged Claude.app (upstream tags
    /// `claude-desktop` only), a terminal's stays unknown until a hook names it.
    @Test
    func everyDesktopEntrypointIsClaudeApp() throws {
        let root = F.projectsFolder()
        defer { R.remove(root) }
        let cases = ["d1": "claude-desktop", "d2": "claude-desktop-3p", "d3": "local-agent", "d4": "cli", "d5": "sdk-cli"]
        for (id, entrypoint) in cases {
            F.write([F.line(["type": "user", "message": ["role": "user", "content": "hello"]], at: 0, entrypoint: entrypoint)],
                    to: F.transcriptURL(in: root, id: id), id: id)
        }
        let sessions = ClaudeTranscriptScanner(rootURL: root).discoverRecentSessions(now: Date())
        let apps = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.jumpTarget?.terminalApp) })
        #expect(apps == ["d1": "Claude.app", "d2": "Claude.app", "d3": "Claude.app", "d4": "Unknown", "d5": "Unknown"])
    }

    /// Where Open goes and who answers, per surface.
    @Test
    func coworkIsInClaudeAndReadOnly() {
        #expect(AttentionPolicy.claudePlace("local-agent") == .claudeApp)
        #expect(AttentionPolicy.claudePlace("claude-desktop-3p") == .claudeApp)
        let cowork = AttentionPolicy.claude(entrypoint: "local-agent", hasTerminal: false, agentID: nil, permissionMode: "default")
        #expect(cowork == AttentionPolicy.ClaudeDecision(hold: false, show: true, place: .claudeApp))
        let code = AttentionPolicy.claude(entrypoint: "claude-desktop", hasTerminal: false, agentID: nil, permissionMode: "default")
        #expect(code.hold && code.place == .claudeApp)
    }
}
