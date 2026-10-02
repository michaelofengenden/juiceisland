import Foundation
import Testing
@testable import JuiceCore

private func events(_ transcript: [String]) -> [SignInOutput.Event] {
    var output = SignInOutput()
    return transcript.flatMap { output.read($0) }
}

/// `claude auth login` (2.1): the page's URL, then `Paste code here if prompted > ` with no newline, which the
/// interactive process delivers as a line of its own.
@Test func claudesLoginAsksForTheCodeAfterItsURL() throws {
    let url = try #require(URL(string: "https://example.com/oauth/authorize?code=true&state=abc123"))
    #expect(events(["Opening browser to sign in…",
                    "If the browser didn't open, visit: \(url.absoluteString)",
                    "Paste code here if prompted > "]) == [.url(url), .wantsCode])
}

/// `codex login` (0.156): the local server's address, then the page's URL; no code is asked for or shown, and the word
/// `codex` is not a code.
@Test func codexsBrowserLoginOnlyHasURLs() throws {
    let local = try #require(URL(string: "http://localhost:1455"))
    let page = try #require(URL(string: "https://example.com/oauth/authorize?response_type=code&state=abc"))
    #expect(events(["Starting local login server on http://localhost:1455.",
                    "If your browser did not open, navigate to this URL to authenticate:",
                    "",
                    page.absoluteString,
                    "",
                    "On a remote or headless machine? Use `codex login --device-auth` instead."]) == [.url(local), .url(page)])
}

/// `codex login --device-auth`: the page and, on the line after the one announcing it, the one-time code to type
/// there, both in colour. The announcements end like prompts but ask for nothing here.
@Test func codexsDeviceLoginShowsItsOneTimeCode() throws {
    let page = try #require(URL(string: "https://example.com/codex/device"))
    #expect(events(["",
                    "Follow these steps to sign in with ChatGPT using device code authorization:",
                    "",
                    "1. Open this link in your browser and sign in to your account",
                    "   \u{1B}[94mhttps://example.com/codex/device\u{1B}[0m",
                    "",
                    "2. Enter this one-time code \u{1B}[90m(expires in 15 minutes)\u{1B}[0m",
                    "   \u{1B}[94mABCD-EFGH\u{1B}[0m",
                    "",
                    "Continue only if you started this login in Codex. If a website or another person gave you this code, cancel.",
                    "SUCCESS"]) == [.url(page), .deviceCode("ABCD-EFGH")])
}

@Test func escapesAreRemovedBeforeReading() {
    let link = "\u{1B}]8;;https://example.com/a\u{07}https://example.com/a\u{1B}]8;;\u{07}"
    #expect(SignInOutput.plain(link) == "https://example.com/a")
    #expect(SignInOutput.plain("\u{1B}[1;32mdone\u{1B}[0m\r") == "done")
    var output = SignInOutput()
    #expect(output.read("If the browser didn't open, visit: " + link) == [.url(URL(string: "https://example.com/a")!)])
}

@Test func aRefusalOnStderrIsRecognised() {
    #expect(SignInOutput.refusesCode("Invalid code. Please make sure the full code was copied."))
    #expect(SignInOutput.refusesCode("That code has expired"))
    #expect(!SignInOutput.refusesCode("Opening browser to sign in…"))
    #expect(!SignInOutput.refusesCode("warning: codex is out of date"))
}
