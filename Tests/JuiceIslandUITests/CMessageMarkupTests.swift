import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream C: an agent's last message as the Done card and the rows draw it (owner, 2026-09-24: the Done card showed
/// `**three pages**` and a raw `:codex-file-citation{…}`). A safe subset of Markdown, nothing opened or fetched.
@MainActor
struct CMessageMarkupTests {
    typealias Span = MessageMarkup.Span

    private func line(_ text: String) -> [Span] {
        let lines = MessageMarkup.lines(text)
        #expect(lines.count == 1, "\(lines)")
        return lines.first ?? []
    }

    @Test func boldAndACodexCitationAsTheFilesName() {
        let text = #"Wrote **three pages** of notes: :codex-file-citation{path="/Users/someone/Developer/notes-site/notes.pdf"}"#
        #expect(line(text) == [Span(text: "Wrote "), Span(text: "three pages", style: .bold), Span(text: " of notes: "),
                               Span(text: "notes.pdf", style: .mono)])
    }

    @Test func italicCodeAndNesting() {
        #expect(line("The *summary* is in `results/summary.md`") == [
            Span(text: "The "), Span(text: "summary", style: .italic), Span(text: " is in "), Span(text: "results/summary.md", style: .mono),
        ])
        #expect(line("_one_ __two__ ***three***") == [
            Span(text: "one", style: .italic), Span(text: " "), Span(text: "two", style: .bold), Span(text: " "),
            Span(text: "three", style: [.bold, .italic]),
        ])
        #expect(line("**bold with `code` and *more***") == [
            Span(text: "bold with ", style: .bold), Span(text: "code", style: [.bold, .mono]), Span(text: " and ", style: .bold),
            Span(text: "more", style: [.bold, .italic]),
        ])
        // Nothing inside a code span is Markdown.
        #expect(line("`**not bold**`") == [Span(text: "**not bold**", style: .mono)])
        #expect(line("``a ` b``") == [Span(text: "a ` b", style: .mono)])
    }

    @Test func linksAndImagesShowOnlyTheirText() {
        #expect(line("See [the outline](https://example.com/outline) first") == [Span(text: "See the outline first")])
        #expect(line("[**bold** link](https://example.com/a_(b))") == [Span(text: "bold", style: .bold), Span(text: " link")])
        #expect(line("![a chart](https://example.com/chart.png)") == [Span(text: "a chart")])
        #expect(line("<https://example.com/x>") == [Span(text: "https://example.com/x")])
        #expect(line("~~old~~ new") == [Span(text: "old new")])
        #expect(line(#"a \*literal\* star"#) == [Span(text: "a *literal* star")])
    }

    @Test func proseThatOnlyLooksLikeMarkdownStaysAsItIs() {
        for text in ["snake_case_name and my__init__ok", "2 * 3 * 4", "a*b", "at 10:30{x}", "Note:foo{x}", "a :smile: face",
                     "see [1] and [2]", "https://example.com/a_b_c", "Vec<String> or a < b > c", "[x] (y)", "_private_var",
                     "C:\\Users", "array[0]: {1}", "【not a citation】"] {
            #expect(MessageMarkup.lines(text) == [[Span(text: text)]], "\(text)")
        }
        // Unmatched marks are searched once each, never once per way to nest them.
        let many = String(repeating: "*a _b **c ", count: 80) + "end"
        #expect(MessageMarkup.lines(many) == [[Span(text: many)]])
        #expect(line("*a **b** c*") == [Span(text: "a ", style: .italic), Span(text: "b", style: [.bold, .italic]),
                                          Span(text: " c", style: .italic)])
        #expect(line("*a**") == [Span(text: "a", style: .italic), Span(text: "*")])
        // As CommonMark: `__init__.py` is bold "init" (agents put file names in code spans).
        #expect(line("__init__.py") == [Span(text: "init", style: .bold), Span(text: ".py")])
    }

    @Test func directivesShowTheirFileTheirLabelOrNothing() {
        #expect(line(#"see :codex-file-citation{path="/tmp/a/b.swift" line_range_start=3 line_range_end=9}"#) ==
            [Span(text: "see "), Span(text: "b.swift", style: .mono)])
        #expect(line("see :cite[the **spec**]{#x .y}") == [Span(text: "see the "), Span(text: "spec", style: .bold)])
        #expect(line(#"done :codex-status{kind="ok"}."#) == [Span(text: "done .")])
        #expect(MessageMarkup.lines("Done.\n" + #"::git-stage{cwd="/tmp/repo"}"#) == [[Span(text: "Done.")]])
        // Anything else that only looks like a directive stays as written.
        for text in [#"done :badge{kind="ok"}."#, "set :root{color:red} first", "a :x[]{} b"] {
            #expect(line(text) == [Span(text: text)], "\(text)")
        }
        #expect(line(#"::code-comment{title="Nit" file='src/app/main.swift' start=1}"#) == [Span(text: "main.swift", style: .mono)])
        #expect(line("see 【F:src/app/main.swift†L10-L20】 there") == [
            Span(text: "see "), Span(text: "main.swift", style: .mono), Span(text: " there"),
        ])
        // A container directive's fences go; the text between them stays.
        #expect(MessageMarkup.lines(":::note\nKeep this\n:::") == [[Span(text: "Keep this")]])
        // Citations back to back stay apart.
        #expect(line(#":codex-file-citation{path="/a/b.pdf"}:codex-file-citation{path="/a/c.pdf"}【F:a/d.swift】"#) == [
            Span(text: "b.pdf", style: .mono), Span(text: " "), Span(text: "c.pdf", style: .mono), Span(text: " "),
            Span(text: "d.swift", style: .mono),
        ])
        #expect(line("`b.pdf`, 【F:a/c.pdf】") == [Span(text: "b.pdf", style: .mono), Span(text: ", "), Span(text: "c.pdf", style: .mono)])
        // A quoted path may hold spaces and braces.
        #expect(line(#":codex-file-citation{path="/tmp/My Notes/{draft} v2.md"}"#) == [Span(text: "{draft} v2.md", style: .mono)])
    }

    @Test func blocksKeepTheirTextAndDropTheirMarks() {
        let text = """
        # Summary #

        Did the work.
        ---
        - first
          - nested `x`
        * second
        1. numbered stays
        > quoted **bit**

        ```swift
        let x = 1
            indented()
        ```
        | File | Lines |
        |------|------:|
        | `a.swift` | 12 |
        """
        #expect(MessageMarkup.lines(text) == [
            [Span(text: "Summary", style: .bold)],
            [Span(text: "Did the work.")],
            [Span(text: "• first")],
            [Span(text: "  • nested "), Span(text: "x", style: .mono)],
            [Span(text: "• second")],
            [Span(text: "1. numbered stays")],
            [Span(text: "quoted "), Span(text: "bit", style: .bold)],
            [Span(text: "let x = 1", style: .mono)],
            [Span(text: "    indented()", style: .mono)],
            [Span(text: "File · Lines")],
            [Span(text: "a.swift", style: .mono), Span(text: " · 12")],
        ])
        #expect(line("# Learn C#") == [Span(text: "Learn C#", style: .bold)])
        #expect(line("#hashtag") == [Span(text: "#hashtag")])
        // An unclosed fence still shows its lines, in mono.
        #expect(MessageMarkup.lines("```\nrm -rf build") == [[Span(text: "rm -rf build", style: .mono)]])
    }

    @Test func aRowGetsOnePlainLineCutAtItsLimit() {
        #expect(MessageMarkup.plain(FixtureSessionFeed.markdownMessage) ==
            "Read the report and wrote three pages of notes: notes.pdf Next • The summary is in results/summary.md "
            + "• Check the outline before the second pass")
        let long = (1...200).map { "line \($0) with **bold**" }.joined(separator: "\n")
        let plain = MessageMarkup.plain(long, limit: 40)
        #expect(plain == "line 1 with bold line 2 with bold line 3…")
        // Only what the limit needs is read.
        #expect(MessageMarkup.lines(long, budget: 40).count == 3)
        #expect(MessageMarkup.plain("") == "" && MessageMarkup.plain(#"::badge{kind="x"}"#) == "")
    }

    /// Round sib review: every unmatched opener searched to the line's end, so one 20 KB line took 1.75 s, on the main
    /// thread, for every Done row and card.
    @Test func longLinesCostTheirLengthNotItsSquare() {
        let lines = [
            String(repeating: "*a ", count: 6_667), String(repeating: "*a *b* ", count: 2_857),
            String(repeating: "[", count: 20_000), String(repeating: "【F:", count: 6_700), String(repeating: " :a[", count: 5_000),
            String(repeating: " :a{\"", count: 4_000), String(repeating: "<", count: 20_000), String(repeating: "src/**/*.swift ", count: 1_333),
        ]
        let clock = ContinuousClock()
        let spent = clock.measure {
            for line in lines {
                _ = MessageMarkup.lines(line)
                _ = MessageMarkup.plain(line)
                _ = MessageText.styled(line, lineLimit: 6)
            }
        }
        #expect(spent < .seconds(1), "\(spent)")
        // Emphasis nested as deep as a parsed line allows.
        let nested = String(repeating: "*a ", count: 333) + String(repeating: "a* ", count: 333)
        #expect(MessageMarkup.lines(nested) == [[Span(text: Array(repeating: "a", count: 666).joined(separator: " "), style: .italic)]])
        // Past its first 2,000 characters a line is kept as written.
        let tail = String(repeating: "a", count: MessageMarkup.parsedLineLength) + " **b**"
        #expect(MessageMarkup.lines(tail) == [[Span(text: tail)]])
    }

    @Test func aLimitedCardReadsOnlyWhatItsLinesShow() {
        let long = (1...200).map { "line \($0) with **bold**" }.joined(separator: "\n")
        let card = String(MessageText.styled(long, lineLimit: 6).characters)
        #expect(card.hasPrefix("line 1 with bold\nline 2 with bold") && card.hasSuffix("…"))
        #expect(card.split(separator: "\n").count < 50)
        #expect(String(MessageText.styled(long).characters).split(separator: "\n").count == 200)
        // A message read only in part says so, even when little of what was read shows.
        #expect(MessageMarkup.plain("Done.\n" + String(repeating: "----------\n", count: 1_000) + "More") == "Done.…")
        #expect(MessageMarkup.plain("Done.\n" + String(repeating: "----------\n", count: 10) + "More") == "Done. More")
    }

    @Test func theCardDrawsStyledRunsAndNoLink() {
        let styled = MessageText.styled("Wrote **three pages**, see [it](https://example.com/x) and `a.md`\n\n- next")
        #expect(String(styled.characters) == "Wrote three pages, see it and a.md\n• next")
        #expect(styled.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
        let fonts = styled.runs.compactMap { $0.font }
        #expect(fonts.contains(Fonts.sys(12, .semibold)) && fonts.contains(Fonts.mono(11, .regular)))
    }

    @Test func rowsShowTheMessageAsPlainTextAndTheCardKeepsItWhole() throws {
        let model = FixtureSessionFeed(scenario: .markdown).makeModel()
        let row = try #require(model.row(id: FixtureSessionFeed.ID.markdownDone))
        #expect(row.detail == MessageMarkup.plain(FixtureSessionFeed.markdownMessage))
        #expect(SessionRowText.cleanStatus(row).text?.hasPrefix("Read the report and wrote three pages of notes: notes.pdf") == true)
        guard case let .done(card) = model.card(for: FixtureSessionFeed.ID.markdownDone) else {
            Issue.record("no Done card")
            return
        }
        #expect(card.message == FixtureSessionFeed.markdownMessage)
        // Plain messages read as before.
        let prototype = FixtureSessionFeed(scenario: .prototype).makeModel()
        #expect(prototype.row(id: FixtureSessionFeed.ID.codexDone)?.detail == "wrote results/summary.md")
    }
}
