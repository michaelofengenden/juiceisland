import Foundation
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// OpenCode's bash ask (`packages/opencode/src/tool/shell.ts` `ask`) lists one pattern per command it has not allowed
/// yet and leaves out the ones that change folder (`cd`, `pushd`, `popd`, `chdir`, …: its `CWD` set), while
/// `metadata.command` is the whole command that runs on Allow. The plugin (`open-island-opencode.js`
/// `permission.asked`) sends `{patterns, metadata, command: patterns.join(" && ")}`, so its `command` is the patterns
/// again, not what runs. A card must show what Allow runs (P154).
@MainActor
struct OpenCodeWholeCommandTests {
    /// The request as the bridge builds it from the plugin's `permission.asked` (input JSON cut at 200, then at 110).
    private func mapped(patterns: [String], command: String) -> ApprovalContent.Mapped {
        var asked = FixtureSessionFeed.openCodePayload("opencode-cd", project: "notes-site", event: .permissionRequest)
        let quoted = patterns.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"patterns":[\#(quoted)],"metadata":{"command":"\#(command)"},"command":"\#(patterns.joined(separator: " && "))"}"#
        asked.toolName = "Bash"
        asked.toolInput = String(json.prefix(200))
        asked.permissionTitle = "Allow Bash"
        asked.permissionDescription = "OpenCode wants to run Bash: \(patterns[0])"
        return ApprovalContent.make(request: FixtureSessionFeed.openCodeRequest(asked), input: nil, tool: .openCode,
                                    folder: "/tmp/notes-site")
    }

    @Test
    func anOpenCodeShellApprovalShowsTheWholeCommandAllowRuns() {
        // Short enough that upstream keeps the JSON whole: the box read `rm -rf build` while Allow runs it in ~.
        let home = mapped(patterns: ["rm -rf build"], command: "cd ~ && rm -rf build")
        #expect(home.body == .command("cd ~ && rm -rf build"))
        #expect(home.rowText.hasPrefix("cd ~"))
        // A pipe into a shell read as two commands joined by `&&`.
        #expect(mapped(patterns: ["cat setup.txt", "sh"], command: "cat setup.txt | sh").body == .command("cat setup.txt | sh"))
    }

    @Test
    func anOpenCodeFolderApprovalNamesTheCommandItLetsRun() {
        // The same call asks `external_directory` first (`shell.ts` `ask`: a file command's path outside the project);
        // with bash already allowed that is the only prompt, and Allow runs the command. The card showed the folder
        // glob alone.
        var asked = FixtureSessionFeed.openCodePayload("opencode-dir", project: "notes-site", event: .permissionRequest)
        asked.toolName = "External_directory"
        asked.toolInput = String(#"{"patterns":["/Users/me/other/*"],"metadata":{"command":"rm -rf ~/other/cache","directories":["/Users/me/other"],"patterns":["/Users/me/other/*"]}}"#.prefix(200))
        asked.permissionTitle = "Allow External_directory"
        asked.permissionDescription = "OpenCode wants to run External_directory: /Users/me/other/*"
        let mapped = ApprovalContent.make(request: FixtureSessionFeed.openCodeRequest(asked), input: nil, tool: .openCode,
                                          folder: "/tmp/notes-site")
        let body: String = switch mapped.body {
        case let .command(text), let .text(text): text
        case .diff: ""
        }
        #expect(body.contains("rm -rf ~/other/cache") || mapped.reason?.contains("rm -rf ~/other/cache") == true)
    }

    @Test
    func aCutOpenCodeShellApprovalStillShowsTheFolderItMovesTo() {
        // Cut at 110 characters: the box read the push alone, with nothing to say it runs in another project.
        let other = mapped(patterns: ["git push --force origin main"],
                           command: "cd /Users/me/Developer/other-project && git push --force origin main")
        guard case let .command(text) = other.body else { Issue.record("not a command"); return }
        #expect(text.hasPrefix("cd /Users/me/Developer/other-project"))
    }
}
