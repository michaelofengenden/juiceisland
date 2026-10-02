import Foundation
import Testing
@testable import JuiceCore

@Test func processStreamsLinesAndAcceptsInput() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                       arguments: ["-c", "read x; echo \"got:$x\"; echo done; echo oops 1>&2"],
                       environment: ["PATH": "/usr/bin:/bin"])
    try p.start()
    try p.write(line: "hello")
    var seen: [String] = []
    for await line in p.lines { seen.append(line) }
    #expect(seen == ["got:hello", "done"])
    let status = await p.waitForExit()
    #expect(status == 0)
    #expect(p.stderrOutput.contains("oops"))
}

/// A login CLI writes its prompt without a newline and waits on stdin: an interactive process delivers the prompt at
/// once, and its stderr line by line while it runs.
@Test func anInteractiveProcessDeliversItsPromptAndItsErrorLines() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                       arguments: ["-c", "echo first; printf 'Paste code here > '; read x; echo \"no $x\" 1>&2; echo \"got:$x\""],
                       environment: ["PATH": "/usr/bin:/bin"], interactive: true)
    try p.start()
    var lines = p.lines.makeAsyncIterator()
    #expect(await lines.next() == "first")
    #expect(await lines.next() == "Paste code here > ")      // before any input: nothing else would come
    try p.write(line: "abc")
    var errors: [String] = []
    for await line in p.errorLines { errors.append(line) }
    #expect(errors == ["no abc"])
    #expect(await lines.next() == "got:abc")
    #expect(await lines.next() == nil)
    #expect(await p.waitForExit() == 0)
    #expect(p.stderrOutput.contains("no abc"))
}

/// A prompt is still a prompt without its trailing space (a CLI build that drops it), and an unfinished line that does
/// not end like one is not delivered until its newline.
@Test func anInteractiveProcessDeliversAPromptWithNoTrailingSpace() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                       arguments: ["-c", "printf 'Paste code here >'; read x; printf 'got '; sleep 0.2; echo \"$x\""],
                       environment: ["PATH": "/usr/bin:/bin"], interactive: true)
    try p.start()
    var lines = p.lines.makeAsyncIterator()
    #expect(await lines.next() == "Paste code here >")       // before any input: nothing else would come
    try p.write(line: "abc")
    #expect(await lines.next() == "got abc")
    #expect(await lines.next() == nil)
    #expect(await p.waitForExit() == 0)
}

/// Readers are not interactive: an unfinished line stays buffered until its newline or the exit, and stderr is only
/// kept, never streamed.
@Test func aProcessThatIsNotInteractiveKeepsAnUnfinishedLine() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                       arguments: ["-c", "printf 'Paste code here > '; read x; echo \"no $x\" 1>&2; echo \"got:$x\""],
                       environment: ["PATH": "/usr/bin:/bin"])
    try p.start()
    try p.write(line: "abc")
    var seen: [String] = []
    for await line in p.lines { seen.append(line) }
    #expect(seen == ["Paste code here > got:abc"])
    var errors: [String] = []
    for await line in p.errorLines { errors.append(line) }
    #expect(errors.isEmpty)
    #expect(p.stderrOutput.contains("no abc"))
}

@Test func terminateEndsTheStream() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], environment: [:])
    try p.start()
    #expect(p.isRunning)
    p.terminate()
    for await _ in p.lines {}
    let status = await p.waitForExit()
    #expect(status != 0)
    #expect(!p.isRunning)
}

@Test func timeoutFires() async {
    await #expect(throws: TimeoutError.self) {
        try await withTimeout(.milliseconds(50)) {
            try await Task.sleep(for: .seconds(5))
            return 1
        }
    }
    let value = try? await withTimeout(.seconds(2)) { 42 }
    #expect(value == 42)
}

@Test func locatorFindsSystemToolsAndRejectsNonsense() {
    #expect(ToolLocator.locate("sh")?.path == "/bin/sh")
    #expect(ToolLocator.locate("definitely-not-a-real-tool-9f3a") == nil)
}

@Test func environmentCarriesTheProfileFolder() {
    let env = CLIEnvironment.make(provider: .claude, folder: "/Users/me/.claude-x", basePATH: "/usr/bin:/bin")
    #expect(env["CLAUDE_CONFIG_DIR"] == "/Users/me/.claude-x")
    #expect(env["CODEX_HOME"] == nil)
    #expect(env["PATH"]?.contains("/usr/bin") == true)
    #expect(env["HOME"] != nil)
    #expect(env["USER"] == NSUserName())
    let codex = CLIEnvironment.make(provider: .codex, folder: "/Users/me/.codex-side", basePATH: "/usr/bin:/bin")
    #expect(codex["CODEX_HOME"] == "/Users/me/.codex-side")
}

@Test func environmentOmitsTheVariableForTheDefaultFolder() {
    let claudeDefault = CLIEnvironment.make(provider: .claude, folder: NSHomeDirectory() + "/.claude", basePATH: "/usr/bin:/bin")
    #expect(claudeDefault["CLAUDE_CONFIG_DIR"] == nil)

    let claudeDefaultTrailingSlash = CLIEnvironment.make(provider: .claude, folder: NSHomeDirectory() + "/.claude/", basePATH: "/usr/bin:/bin")
    #expect(claudeDefaultTrailingSlash["CLAUDE_CONFIG_DIR"] == nil)

    let codexDefault = CLIEnvironment.make(provider: .codex, folder: NSHomeDirectory() + "/.codex", basePATH: "/usr/bin:/bin")
    #expect(codexDefault["CODEX_HOME"] == nil)

    // A `.` segment normalizes to the same default folder and must not defeat the comparison either.
    let claudeDefaultWithDotSegment = CLIEnvironment.make(provider: .claude, folder: NSHomeDirectory() + "/./.claude", basePATH: "/usr/bin:/bin")
    #expect(claudeDefaultWithDotSegment["CLAUDE_CONFIG_DIR"] == nil)

    // Non-default folders still get the variable set.
    let claudeAlt = CLIEnvironment.make(provider: .claude, folder: NSHomeDirectory() + "/.claude-work", basePATH: "/usr/bin:/bin")
    #expect(claudeAlt["CLAUDE_CONFIG_DIR"] == NSHomeDirectory() + "/.claude-work")

    let codexAlt = CLIEnvironment.make(provider: .codex, folder: NSHomeDirectory() + "/.codex-work", basePATH: "/usr/bin:/bin")
    #expect(codexAlt["CODEX_HOME"] == NSHomeDirectory() + "/.codex-work")
}

/// Every CLI launch carries both island skip switches, for default and other folders, and `extra` cannot drop them.
@Test func environmentSkipsIslandHooks() {
    for provider in Provider.allCases {
        let home = NSHomeDirectory()
        let standard = CLIEnvironment.make(provider: provider, folder: home + "/" + provider.defaultFolderName, basePATH: "/usr/bin:/bin")
        let other = CLIEnvironment.make(provider: provider, folder: home + "/." + provider.rawValue + "-work", basePATH: "/usr/bin:/bin")
        let forced = CLIEnvironment.make(provider: provider, folder: home + "/." + provider.rawValue + "-work",
                                         extra: ["OPEN_ISLAND_SKIP_HOOKS": "0", "VIBE_ISLAND_SKIP": "0"], basePATH: "/usr/bin:/bin")
        for env in [standard, other, forced] {
            #expect(env["OPEN_ISLAND_SKIP_HOOKS"] == "1")
            #expect(env["VIBE_ISLAND_SKIP"] == "1")
        }
    }
}

/// Every CLI fake refuses a launch that lacks either island skip switch, so a launch site that builds its own
/// environment fails its tests instead of passing silently. The BROWSER helper and the orphan fake are not CLIs.
@Test func everyCLIFakeRefusesALaunchWithoutBothIslandSkipSwitches() async throws {
    let notCLIs: Set<String> = ["fake-browser.sh", "fake-orphan.sh"]
    let fakes = try #require(Bundle.module.urls(forResourcesWithExtension: "sh", subdirectory: "Fixtures"))
        .map { $0.deletingPathExtension().lastPathComponent }
        .filter { $0.hasPrefix("fake-") && !notCLIs.contains($0 + ".sh") }
        .sorted()
    #expect(fakes.contains("fake-codex-sticky") && fakes.contains("fake-codex-asks") && fakes.contains("fake-login-device"))
    #expect(fakes.count == 14)
    let base = ["PATH": "/usr/bin:/bin"]
    for fake in fakes {
        let url = try fixtureURL(fake, "sh")
        for environment in [base, base.merging(["OPEN_ISLAND_SKIP_HOOKS": "1"]) { $1 }, base.merging(["VIBE_ISLAND_SKIP": "1"]) { $1 }] {
            let p = CLIProcess(executable: url, arguments: [], environment: environment)
            try p.start()
            p.closeInput()
            let status = try? await withTimeout(.seconds(5)) { await p.waitForExit() }
            p.kill()
            for await _ in p.lines {}                // the stream ends once the exit is handled, with stderr drained
            #expect(status == 97, "\(fake) with \(environment.keys.sorted())")
            #expect(p.stderrOutput.contains("island skip vars missing"), "\(fake) with \(environment.keys.sorted())")
        }
    }
}

@Test func writeAfterExitThrows() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 0"], environment: [:])
    try p.start()
    _ = await p.waitForExit()
    #expect(throws: (any Error).self) { try p.write(line: "x") }
}

@Test func waitForExitStopsWhenCancelled() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 30"], environment: [:])
    try p.start()
    let started = Date()
    await #expect(throws: TimeoutError.self) {
        try await withTimeout(.milliseconds(200)) { await p.waitForExit() }
    }
    #expect(Date().timeIntervalSince(started) < 2)
    p.kill()
    let status = await p.waitForExit()
    #expect(status != 0)
}

@Test func linesArriveInOrderThroughExit() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                       arguments: ["-c", "i=1; while [ $i -le 3000 ]; do echo $i; i=$((i+1)); done"],
                       environment: ["PATH": "/usr/bin:/bin"])
    try p.start()
    var seen: [String] = []
    for await line in p.lines { seen.append(line) }
    #expect(seen == (1...3000).map(String.init))
    _ = await p.waitForExit()
}

@Test func failedStartFinishesTheStream() async throws {
    let p = CLIProcess(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], environment: [:])
    #expect(throws: (any Error).self) { try p.start() }
    await #expect(throws: Never.self) {
        try await withTimeout(.seconds(2)) {
            for await _ in p.lines {}
        }
    }
}

@Test func finalDrainDoesNotWaitForAGrandchildHoldingThePipes() async throws {
    let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("juice-orphan-\(UUID().uuidString).pid")
    defer {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: pidFile)
    }
    let p = CLIProcess(executable: try fixtureURL("fake-orphan", "sh"), arguments: [],
                       environment: ["PATH": "/usr/bin:/bin", "ORPHAN_PID_FILE": pidFile.path])
    try p.start()
    let lines = p.lines
    let started = Date()
    // The stream has to end once the child exits, even though the grandchild still holds the write ends.
    let seen = try await withTimeout(.seconds(3)) {
        var collected: [String] = []
        for await line in lines { collected.append(line) }
        return collected
    }
    #expect(seen == ["first", "second"])
    #expect(Date().timeIntervalSince(started) < 3)
    #expect(!p.isRunning)
}
