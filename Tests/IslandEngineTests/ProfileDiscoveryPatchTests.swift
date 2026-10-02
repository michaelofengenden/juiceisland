import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

/// The patched ActiveAgentProcessDiscovery (Patches/active-agent-profiles.patch). Serialized because
/// AgentProfileRoots is process-wide state.
@Suite(.serialized)
struct ProfileDiscoveryPatchTests {
    private static let ps = """
      202 401 ttys001 /opt/homebrew/bin/codex
      302 501 ttys002 claude
      401 900 ttys001 -/bin/zsh
      501 900 ttys002 -/bin/zsh
      900 1 ?? /Applications/Ghostty.app/Contents/MacOS/ghostty
    """

    private static func discovery() -> ActiveAgentProcessDiscovery {
        ActiveAgentProcessDiscovery { executablePath, arguments in
            if executablePath == "/bin/ps" { return ps }
            guard executablePath == "/usr/sbin/lsof", let pid = arguments.dropFirst(2).first else { return nil }
            switch pid {
            case "202":
                return """
                fcwd
                n/tmp/project
                n/Users/test/.codex-side/sessions/2026/09/23/rollout-2026-09-23T10-00-00-019d516f-71ee-7e40-bcff-502fedac0928.jsonl
                """
            case "302":
                return """
                fcwd
                n/tmp/project
                n/Users/test/.claude-work/projects/-tmp-project/7c2d9a51-0d3e-4b8e-9a51-2f1e1c7d3b10.jsonl
                """
            default:
                return nil
            }
        }
    }

    @Test
    func withoutProfileRootsOtherHomesAreInvisibleLikeUpstream() {
        AgentProfileRoots.update(claudeRoots: [], codexRoots: [])
        let snapshots = Self.discovery().discover()
        #expect(!snapshots.contains { $0.tool == .codex })
        #expect(snapshots.first { $0.tool == .claudeCode }?.sessionID == nil)
    }

    @Test
    func profileRootsMakeOtherHomesMatchTheirProcesses() {
        AgentProfileRoots.update(claudeRoots: ["/Users/test/.claude-work"], codexRoots: ["/Users/test/.codex-side"])
        defer { AgentProfileRoots.update(claudeRoots: [], codexRoots: []) }
        let snapshots = Self.discovery().discover()
        #expect(snapshots.first { $0.tool == .codex }?.sessionID == "019d516f-71ee-7e40-bcff-502fedac0928")
        let claude = snapshots.first { $0.tool == .claudeCode }
        #expect(claude?.sessionID == "7c2d9a51-0d3e-4b8e-9a51-2f1e1c7d3b10")
        #expect(claude?.transcriptPath == "/Users/test/.claude-work/projects/-tmp-project/7c2d9a51-0d3e-4b8e-9a51-2f1e1c7d3b10.jsonl")
    }

    @Test
    func aProcessWithoutATerminalIsNeverASession() {
        // Juice's own `claude` usage reads run with pipes, not a terminal: upstream skips TTY-less processes. The
        // same process with a terminal is the control, so the test fails if `lsof` alone decided the result.
        func discovery(tty: String) -> ActiveAgentProcessDiscovery {
            ActiveAgentProcessDiscovery { executablePath, arguments in
                if executablePath == "/bin/ps" { return "  700 1 \(tty) /opt/homebrew/bin/claude --output-format stream-json" }
                guard executablePath == "/usr/sbin/lsof", arguments.dropFirst(2).first == "700" else { return nil }
                return "fcwd\nn/private/var/folders/x/T/juice-cli\n"
            }
        }
        #expect(discovery(tty: "??").discover().isEmpty)
        #expect(discovery(tty: "ttys009").discover().count == 1)
    }

    @Test
    func fragmentsAlwaysKeepTheDefaultsAndDropDuplicates() {
        AgentProfileRoots.update(claudeRoots: ["/h/.claude-a"], codexRoots: ["/h/.codex-b"])
        defer { AgentProfileRoots.update(claudeRoots: [], codexRoots: []) }
        #expect(AgentProfileRoots.claudeProjectFragments == ["/.claude/projects/", "/h/.claude-a/projects/"])
        #expect(AgentProfileRoots.codexSessionFragments == ["/.codex/sessions/", "/h/.codex-b/sessions/"])
        #expect(AgentProfileRoots.uniquePaths(["/x", "/y", "/x"]) == ["/x", "/y"])
    }
}
