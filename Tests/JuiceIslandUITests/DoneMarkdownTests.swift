import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// P430 to P432: a Done card's tables, fenced code and links (`MessageMarkup.blocks`, `DoneMessageView`, `SafeLink`).
@MainActor
struct DoneMarkdownTests {
    typealias Span = MessageMarkup.Span
    typealias Block = MessageMarkup.Block

    private func table(_ blocks: [Block], _ index: Int = 0) -> MessageMarkup.Table? {
        let tables = blocks.compactMap { block -> MessageMarkup.Table? in if case let .table(table) = block { table } else { nil } }
        return tables.indices.contains(index) ? tables[index] : nil
    }

    private func boxes(_ blocks: [Block]) -> [[String]] {
        blocks.compactMap { block in if case let .code(lines) = block { lines } else { nil } }
    }

    // MARK: Tables (P430)

    @Test func aTableIsAGridWithItsColumnsAlignment() throws {
        let blocks = MessageMarkup.blocks("Benchmarks:\n\n| Suite | Before | Change |\n|:--|--:|:-:|\n| **parse** | 412 ms | −77% |\n| `sync` | 88 ms |\n\nNoise.")
        #expect(blocks.count == 3)
        let table = try #require(table(blocks))
        #expect(table.alignments == [.leading, .trailing, .center])
        #expect(table.header == [[Span(text: "Suite")], [Span(text: "Before")], [Span(text: "Change")]])
        #expect(table.rows == [
            [[Span(text: "parse", style: .bold)], [Span(text: "412 ms")], [Span(text: "−77%")]],
            // A short row is filled with empty cells.
            [[Span(text: "sync", style: .mono)], [Span(text: "88 ms")], []],
        ])
        #expect(blocks.last == .line([Span(text: "Noise.")], rows: nil))
    }

    @Test func aTableWithoutOuterPipesOrWithEscapedOnes() throws {
        let plain = try #require(table(MessageMarkup.blocks("a | b\n--- | ---\n1 | 2")))
        #expect(plain.header == [[Span(text: "a")], [Span(text: "b")]] && plain.rows == [[[Span(text: "1")], [Span(text: "2")]]])
        let escaped = try #require(table(MessageMarkup.blocks("| op | means |\n|---|---|\n| `a \\| b` | either |\n| x | y | extra |")))
        #expect(escaped.rows[0][0] == [Span(text: "a | b", style: .mono)])
        // A long row's extra cells go.
        #expect(escaped.rows[1].count == 2)
    }

    @Test func pipesWithNoDelimiterRowStayALineOfCells() {
        #expect(MessageMarkup.blocks("| a | b |\n| c | d |") == [.line([Span(text: "a · b")], rows: nil), .line([Span(text: "c · d")], rows: nil)])
        // A delimiter row whose columns do not match the header's is no table either.
        #expect(table(MessageMarkup.blocks("| a | b |\n|---|\n| 1 | 2 |")) == nil)
    }

    @Test func aTableEndsAtABlankLineOrALineWithNoPipe() throws {
        let blocks = MessageMarkup.blocks("| a |\n|---|\n| 1 |\nafter\n| 2 |")
        #expect(try #require(table(blocks)).rows.count == 1)
        #expect(blocks.contains(.line([Span(text: "after")], rows: nil)))
    }

    @Test func aRowStillReadsItsTableAsOneLinePerRow() {
        // The rows' plain line and the plan's box are unchanged: cells joined by " · ".
        #expect(MessageMarkup.plain("| a | b |\n|:--|--:|\n| 1 | 2 |") == "a · b 1 · 2")
    }

    // MARK: Fenced code (P430)

    @Test func aFenceIsABoxOfItsLinesAsWritten() {
        let text = "Run:\n\n```sh\nswift test --filter X\n```\n\nand\n\n~~~swift\nfunc f() {\n\tlet x = 1\n\n    return **x**  \n}\n\n\n~~~"
        #expect(boxes(MessageMarkup.blocks(text)) == [["swift test --filter X"], ["func f() {", "    let x = 1", "", "    return **x**", "}"]])
        // Nothing inside a fence is Markdown or a link.
        let linked = MessageMarkup.blocks("```\nsee [x](https://example.com) and https://example.com\n```")
        #expect(boxes(linked) == [["see [x](https://example.com) and https://example.com"]])
        // An unclosed fence still shows; an empty one shows nothing.
        #expect(boxes(MessageMarkup.blocks("```\nrm -rf build")) == [["rm -rf build"]])
        #expect(MessageMarkup.blocks("```\n\n```").isEmpty)
    }

    // MARK: Links (P431)

    @Test func webLinksAreLinksAndNothingElseIs() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(MessageMarkup.blocks("See [the outline](https://example.com/a) first") ==
            [.line([Span(text: "See "), Span(text: "the outline", link: url), Span(text: " first")], rows: nil)])
        #expect(MessageMarkup.blocks("<https://example.com/a>") == [.line([Span(text: "https://example.com/a", link: url)], rows: nil)])
        // A bare address, without the sentence's end or a bracket it did not open.
        let wiki = try #require(URL(string: "https://en.wikipedia.org/wiki/Grid_(graphic_design)"))
        #expect(MessageMarkup.blocks("PR: https://example.com/a. And (https://en.wikipedia.org/wiki/Grid_(graphic_design)).") == [.line([
            Span(text: "PR: "), Span(text: "https://example.com/a", link: url), Span(text: ". And ("),
            Span(text: "https://en.wikipedia.org/wiki/Grid_(graphic_design)", link: wiki), Span(text: ")."),
        ], rows: nil)])
        // A styled link's text keeps its style and the link.
        #expect(MessageMarkup.blocks("[**bold** link](https://example.com/a)") ==
            [.line([Span(text: "bold", style: .bold, link: url), Span(text: " link", link: url)], rows: nil)])
        // Any other scheme, a relative target, credentials before the host, and an image: text only.
        for text in ["[f](file:///etc/hosts)", "[j](javascript:alert(1))", "[m](mailto:a@example.com)", "[r](docs/readme.md)",
                     "[c](https://user:pass@example.com/)", "[t](https://bank.example@evil.example/)", "![chart](https://example.com/c.png)",
                     "<ftp://example.com/x>", "ftp://example.com/x", "xhttps://example.com", "https://", "file:///tmp/x"] {
            let spans = MessageMarkup.blocks(text).flatMap { block -> [Span] in if case let .line(spans, _) = block { spans } else { [] } }
            #expect(spans.allSatisfy { $0.link == nil }, "\(text)")
        }
    }

    @Test func textThatNamesAnotherAddressShowsWhereTheLinkGoes() throws {
        let target = try #require(URL(string: "https://login.example.net/verify"))
        for label in ["https://bank.example", "bank.example", "www.bank.example/login"] {
            #expect(MessageMarkup.blocks("[\(label)](https://login.example.net/verify)") ==
                [.line([Span(text: "https://login.example.net/verify", link: target)], rows: nil)], "\(label)")
        }
        // Text naming the same host, or no host at all (prose, a file's name), stays.
        #expect(!SafeLink.misleads(label: "www.login.example.net", target: target))
        #expect(!SafeLink.misleads(label: "the verify page", target: target))
        #expect(!SafeLink.misleads(label: "notes.md", target: target) && !SafeLink.misleads(label: "`main.swift`", target: target))
    }

    @Test func rowsAndThePlanNeverCarryALink() {
        let text = "See [it](https://example.com/x), <https://example.com/y> and https://example.com/z"
        #expect(MessageMarkup.lines(text).joined().allSatisfy { $0.link == nil })
        #expect(MessageText.styled(text).runs.allSatisfy { $0.link == nil })
        #expect(MessageMarkup.plain(text) == "See it, https://example.com/y and https://example.com/z")
    }

    @Test func theCardsTextCarriesOnlyItsWebLinks() throws {
        let blocks = MessageMarkup.blocks("See [it](https://example.com/x) and [that](file:///tmp/a) and `https://example.com/code`")
        guard case let .line(spans, _)? = blocks.first else { Issue.record("no line"); return }
        let styled = DoneMessageView.styled([spans])
        #expect(String(styled.characters) == "See it and that and https://example.com/code")
        #expect(styled.runs.compactMap(\.link) == [try #require(URL(string: "https://example.com/x"))])
    }

    @Test func aClickOpensOnlyAWebAddressInTheDefaultBrowser() throws {
        var opened: [(URL, URL)] = []
        let browser = URL(fileURLWithPath: "/Applications/Browser.app")
        let web = try #require(URL(string: "https://example.com/x"))
        #expect(SafeLink.open(web, browser: { browser }, open: { opened.append(($0, $1)) }))
        for raw in ["file:///etc/hosts", "javascript:alert(1)", "vscode://file/tmp/x", "https://user@example.com/"] {
            #expect(!SafeLink.open(try #require(URL(string: raw)), browser: { browser }, open: { opened.append(($0, $1)) }), "\(raw)")
        }
        #expect(!SafeLink.open(web, browser: { nil }, open: { opened.append(($0, $1)) }))
        #expect(opened.map(\.0) == [web] && opened.map(\.1) == [browser])
    }

    // MARK: The card's line limit (P432)

    @Test func aLimitedCardHoldsNoMoreLinesThanItsLimit() throws {
        // Two lines: a line of text leaves one, too few for a header and a row, so the table waits behind "…".
        let intro = MessageMarkup.blocks(FixtureSessionFeed.repliesTableMessage, rows: 2)
        #expect(intro == [.line([Span(text: "Benchmarks after the change:…")], rows: 1)])
        // A table first: its header and a row, the "…" in the row's last cell.
        let first = MessageMarkup.blocks("| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |", rows: 2)
        #expect(try #require(table(first)).rows == [[[Span(text: "1")], [Span(text: "2…")]]])
        // A box cut short says so on its last line shown.
        #expect(boxes(MessageMarkup.blocks("```\none\ntwo\nthree\n```", rows: 2)) == [["one", "two …"]])
        // A long line counts a line per 100 characters, the last one also gets what is left.
        let long = String(repeating: "word ", count: 50)
        #expect(MessageMarkup.blocks(long, rows: 6) == [.line([Span(text: long.trimmingCharacters(in: .whitespaces))], rows: 6)])
        // A line given fewer lines than it takes is cut by its text's own limit, which ends it in "…".
        #expect(MessageMarkup.blocks("a\n" + long, rows: 2) == [.line([Span(text: "a")], rows: 1),
                                                                 .line([Span(text: long.trimmingCharacters(in: .whitespaces))], rows: 1)])
        // Whatever the message, the lines given out never pass the limit.
        let messages = [FixtureSessionFeed.repliesTableMessage, FixtureSessionFeed.repliesCodeMessage, FixtureSessionFeed.repliesLinksMessage,
                        FixtureSessionFeed.repliesWideMessage, FixtureSessionFeed.markdownMessage, long + "\n" + long]
        for message in messages {
            for limit in 1...8 {
                let used = MessageMarkup.blocks(message, rows: limit).reduce(0) { total, block in
                    switch block {
                    case let .line(_, rows): total + (rows ?? 99)
                    case let .table(table): total + 1 + table.rows.count
                    case let .code(lines): total + lines.count
                    }
                }
                #expect(used <= limit, "\(limit): \(message.prefix(20))")
            }
        }
    }

    @Test func anUnlimitedCardShowsTheWholeMessage() throws {
        let blocks = MessageMarkup.blocks(FixtureSessionFeed.repliesCodeMessage)
        #expect(boxes(blocks).count == 2)
        #expect(blocks.allSatisfy { if case let .line(_, rows) = $0 { rows == nil } else { true } })
        #expect(!blocks.description.contains("…"))
    }

    @Test func consecutiveLinesAreOneTextOfTheirLines() {
        let groups = DoneMessageView.groups([.line([Span(text: "a")], rows: 1), .line([Span(text: "b")], rows: 2),
                                            .code(["x"]), .line([Span(text: "c")], rows: nil)])
        #expect(groups == [.text([[Span(text: "a")], [Span(text: "b")]], rows: 3), .code(["x"]), .text([[Span(text: "c")]], rows: nil)])
    }

    /// The parse runs on the main thread for every Done card: a long line of marks, of pipes, of addresses or of a fence
    /// costs its length (P88's bound, kept).
    @Test func longLinesStillCostTheirLength() {
        let lines = [
            String(repeating: "| a ", count: 5_000) + "\n|" + String(repeating: "---|", count: 5_000),
            String(repeating: "https://example.com/a ", count: 1_000), String(repeating: "h", count: 20_000),
            "```\n" + String(repeating: "x", count: 50_000), String(repeating: "[a](https://e.x/) ", count: 1_200),
            String(repeating: "*a ", count: 6_667), String(repeating: "<", count: 20_000),
        ]
        let clock = ContinuousClock()
        let spent = clock.measure {
            for line in lines {
                _ = MessageMarkup.blocks(line)
                _ = MessageMarkup.blocks(line, rows: 2)
            }
        }
        #expect(spent < .seconds(1), "\(spent)")
        // A table has at most `tableColumns` columns.
        #expect(table(MessageMarkup.blocks(lines[0]))?.header.count == MessageMarkup.tableColumns)
    }

    @Test func theDemoCardsCarryTheirReplies() throws {
        let model = FixtureSessionFeed(scenario: .replies).makeModel()
        for id in [FixtureSessionFeed.RepliesID.table, FixtureSessionFeed.RepliesID.code, FixtureSessionFeed.RepliesID.links,
                   FixtureSessionFeed.RepliesID.wide] {
            guard case let .done(card) = model.card(for: id) else { Issue.record("no Done card for \(id)"); continue }
            #expect(!MessageMarkup.blocks(card.message).isEmpty)
        }
        // The row keeps one plain line, links as their text.
        #expect(model.row(id: FixtureSessionFeed.RepliesID.links)?.detail?.hasPrefix("Opened the pull request: https://github.com/example") == true)
    }

    // MARK: Text size (P402, P491)

    /// Settings › Island › Text size reaches a Done card's message, its tables and its code boxes, as it reaches the plan,
    /// the command and the question: each is taller at 15 pt than at 12, by about 15/12, and wider for a grid or a box.
    @Test func textSizeStepsTheMessageItsTablesAndItsCodeBoxes() {
        func size(_ text: String, _ points: Int) -> CGSize {
            let view = DoneMessageView(text: text).environment(\.islandSize, IslandSize(width: 480, text: points))
            return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 408, height: 4000))
        }
        let message = "Wrote the notes.\nThen ran the suite, **all green**, see `notes.md`."
        let table = "| Suite | Before |\n|---|--:|\n| parse | 412 ms |\n| sync | 88 ms |"
        let code = "```\nswift test --filter Notes\nswift build\n```"
        for text in [message, table, code] {
            let small = size(text, 12), large = size(text, 15)
            #expect(large.height > small.height * 1.12, "\(text): \(small) → \(large)")
        }
        // Plain text fills the lane at either size; a grid and a box grow sideways with their text.
        let plainTable = "| a | b |\n|---|---|\n| one | two |"
        let small = NSHostingController(rootView: MessageTableView(table: tableOf(plainTable))).sizeThatFits(in: CGSize(width: 408, height: 400))
        let large = NSHostingController(rootView: MessageTableView(table: tableOf(plainTable)).environment(\.islandSize, IslandSize(width: 480, text: 15)))
            .sizeThatFits(in: CGSize(width: 408, height: 400))
        #expect(large.width > small.width, "\(small) → \(large)")
    }

    private func tableOf(_ text: String) -> MessageMarkup.Table {
        table(MessageMarkup.blocks(text)) ?? MessageMarkup.Table(alignments: [], header: [], rows: [])
    }
}
