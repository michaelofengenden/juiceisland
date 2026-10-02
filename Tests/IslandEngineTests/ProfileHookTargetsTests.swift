import Foundation
import Testing
@testable import IslandEngine
import JuiceCore

struct ProfileHookTargetsTests {
    private let home = "/Users/test"

    @Test
    func accountsAndDiscoveryMergeOnePerFolderDefaultFirst() {
        let accounts = [
            Account(provider: .claude, folder: "/Users/test/.claude-work", alias: "Work"),
            Account(provider: .claude, folder: "/Users/test/.claude", alias: "Main"),
            Account(provider: .codex, folder: "/Users/test/.codex", alias: "default", monitored: false),
        ]
        let discovered = [
            DiscoveredProfile(provider: .claude, folder: "/Users/test/.claude-work/", suggestedAlias: "work"),
            DiscoveredProfile(provider: .codex, folder: "/Users/test/.codex-side", suggestedAlias: "side"),
            DiscoveredProfile(provider: .claude, folder: "/Users/test/.claude-lab", suggestedAlias: "lab"),
        ]
        let targets = ProfileHookTargets.make(accounts: accounts, discovered: discovered, home: home)
        #expect(targets.map(\.alias) == ["Main", "Work", "lab", "default", "side"])
        #expect(targets.map(\.isDefaultFolder) == [true, false, false, true, false])
        #expect(targets.map(\.isMonitored) == [true, true, false, false, false])
        #expect(targets[1].accountID == "claude:/Users/test/.claude-work")
        #expect(targets[2].accountID == nil)
        #expect(targets[4].id == "codex:/Users/test/.codex-side")
    }
}

struct AccountResolverTests {
    private let targets = ProfileHookTargets.make(
        accounts: [Account(provider: .claude, folder: "/Users/test/.claude", alias: "Main"),
                   Account(provider: .claude, folder: "/Users/test/.claude-work", alias: "Work"),
                   Account(provider: .codex, folder: "/Users/test/.codex-side", alias: "Side")],
        discovered: [], home: "/Users/test")

    @Test
    func theDefaultFolderNeverClaimsAnotherProfilesPath() {
        let tag = AccountResolver.tag(transcriptPath: "/Users/test/.claude-work/projects/-x/a.jsonl",
                                      tool: .claudeCode, targets: targets)
        #expect(tag?.alias == "Work")
        #expect(tag?.accountID == "claude:/Users/test/.claude-work")
        let main = AccountResolver.tag(transcriptPath: "/Users/test/.claude/projects/-x/b.jsonl",
                                       tool: .claudeCode, targets: targets)
        #expect(main?.alias == "Main")
    }

    @Test
    func codexSessionsAndArchivedSessionsBothMatch() {
        for path in ["/Users/test/.codex-side/sessions/2026/09/23/rollout-1.jsonl",
                     "/Users/test/.codex-side/archived_sessions/rollout-2.jsonl"] {
            #expect(AccountResolver.tag(transcriptPath: path, tool: .codex, targets: targets)?.alias == "Side")
        }
    }

    @Test
    func unknownPathsMissingPathsAndOtherToolsStayUntagged() {
        #expect(AccountResolver.tag(transcriptPath: "/tmp/elsewhere/d.jsonl", tool: .claudeCode, targets: targets) == nil)
        #expect(AccountResolver.tag(transcriptPath: nil, tool: .claudeCode, targets: targets) == nil)
        #expect(AccountResolver.tag(transcriptPath: "/Users/test/.claude/projects/-x/e.jsonl", tool: .geminiCLI, targets: targets) == nil)
    }

    @Test
    func aSubagentTranscriptTagsLikeItsParent() {
        let tag = AccountResolver.tag(transcriptPath: "/Users/test/.claude-work/projects/-x/abc/subagents/agent-1.jsonl",
                                      tool: .claudeCode, targets: targets)
        #expect(tag?.alias == "Work")
    }
}
