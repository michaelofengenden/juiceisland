import Foundation
import JuiceCore
import Testing
@testable import IslandEngine

/// P1551: Refresh login types exactly `CODEX_HOME='<folder>' codex` (plain `codex` for `~/.codex`) into a new window of the
/// owner's usual terminal, in the home folder: each path one quoted word, no skip switch, no prompt, nothing after it.
/// Only the line and the script are built here; nothing opens.
struct LoginRefreshLaunchTests {
    static let home = "/tmp/ji-home"

    @Test func theLineIsCodexInTheLoginsFolderEachPathQuoted() {
        #expect(FreshSessionLaunch.loginRefresh(profileFolder: Self.home + "/.codex", host: .terminal, home: Self.home)
            == FreshSessionLaunch(host: .terminal, folder: Self.home, line: "codex"))
        #expect(FreshSessionLaunch.loginRefresh(profileFolder: Self.home + "/.codex/", host: .ghostty, home: Self.home).line == "codex")
        #expect(FreshSessionLaunch.loginRefresh(profileFolder: Self.home + "/.codex-side", host: .iterm, home: Self.home)
            == FreshSessionLaunch(host: .iterm, folder: Self.home, line: "CODEX_HOME='/tmp/ji-home/.codex-side' codex"))
        // A space stays inside the word, and a quote is closed, escaped and reopened.
        #expect(FreshSessionLaunch.loginRefresh(profileFolder: "/tmp/ji home/.codex-it's", host: .terminal, home: Self.home).line
            == #"CODEX_HOME='/tmp/ji home/.codex-it'\''s' codex"#)
    }

    @Test func itCarriesNoSkipSwitchAndNoPrompt() {
        let launch = FreshSessionLaunch.loginRefresh(profileFolder: Self.home + "/.codex-side", host: .terminal, home: Self.home)
        for key in CLIEnvironment.islandSkipKeys { #expect(!launch.line.contains(key)) }
        #expect(launch.line.hasSuffix(" codex") && !launch.line.contains("exec") && !launch.line.contains("\n"))
        // Terminal types the line, and only the line, into its new window.
        let script = FreshSessionLaunch.script(launch)
        #expect(script.contains(#"do script "CODEX_HOME='/tmp/ji-home/.codex-side' codex""#))
    }
}
