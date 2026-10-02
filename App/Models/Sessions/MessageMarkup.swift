import Foundation

/// An agent's last message (or its plan) as the cards and rows draw it. Agents write Markdown, and Codex adds its own
/// directives (`:codex-file-citation{path="…"}`); drawn as they arrive they read `**three pages**`. This keeps a safe
/// subset, parsed here by hand and never executed: **bold**, *italic*, `code`; a directive or a `【F:…】` citation as
/// its file's name in mono (else its label, else nothing); an image as its text only (nothing is fetched).
///
/// Two readings. `lines` (a row's one line, `plain`, and the plan's box): a link as its text only, a heading's text
/// bold, a list item after "•", a table row as its cells ("a · b"), a fence's lines in mono; fences, rules, quote marks
/// and blank lines go, so a line limit is spent on text. `blocks` (the Done card, P430 to P432): the same lines, and a
/// table (a header row over a delimiter row, GFM) as a grid with its columns' alignment, a fence as a box of its lines
/// as written, and an `http` or `https` link, written as a link, an autolink or a bare address, as a link the card opens
/// in the default browser (`SafeLink`); any other target stays text. Owner: stream C.
enum MessageMarkup {
    struct Style: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let bold = Style(rawValue: 1)
        static let italic = Style(rawValue: 2)
        /// Code, and a cited file's name.
        static let mono = Style(rawValue: 4)
    }

    struct Span: Equatable, Sendable {
        var text: String
        var style: Style = []
        /// Where a click goes: an `http` or `https` address `SafeLink` let through; only `blocks` sets it.
        var link: URL? = nil
    }

    /// One part of a Done card's message (`blocks`).
    enum Block: Equatable, Sendable {
        /// A line of text; `rows`: the lines the card gives it (nil: as many as it takes).
        case line([Span], rows: Int?)
        case table(Table)
        /// A fence's lines as written (tabs as four spaces), its blank lines inside kept.
        case code([String])
    }

    struct Table: Equatable, Sendable {
        enum Alignment: Equatable, Sendable { case leading, center, trailing }
        var alignments: [Alignment]
        /// Each row as its cells, as many as the header has; the header first.
        var header: [[Span]]
        var rows: [[[Span]]]
    }

    /// Past this many characters a line is kept as written: an unmatched mark's search can run to the line's end, so
    /// a long log-like line would cost its length squared on every pass.
    static let parsedLineLength = 2_000
    /// A table has at most this many columns; the rest of a wider row is dropped (a grid that wide says nothing).
    static let tableColumns = 12
    /// A card line holds about this many characters: `blocks` counts a longer line of text as more than one of the
    /// card's lines, and reads at most eight times what the lines hold.
    static let charactersPerRow = 100

    /// The message's lines, blank ones dropped, each as styled spans. Stops once `budget` characters are out, reading
    /// at most eight times as many (markup rarely takes more); a message stopped before its end ends in "…".
    static func lines(_ text: String, budget: Int = .max) -> [[Span]] {
        var lines: [[Span]] = []
        var count = 0
        let read = budget < .max / 8 ? text.prefix(budget * 8) : Substring(text)
        var scanner = Scanner(rest: read, links: false)
        while count < budget, let item = scanner.next() {
            let spans: [Span]
            switch item {
            case .fenceOpen, .fenceClose: continue
            case let .code(line): spans = line.isEmpty ? [] : [Span(text: line, style: .mono)]
            case let .line(line): spans = line
            case let .tableHeader(cells, _), let .tableRow(cells): spans = flattened(cells)
            }
            guard !spans.isEmpty else { continue }
            lines.append(spans)
            count += spans.reduce(0) { $0 + $1.text.count }
        }
        if !scanner.rest.isEmpty || read.endIndex < text.endIndex {
            if lines.isEmpty { lines = [[]] }
            lines[lines.count - 1] = merged(lines[lines.count - 1] + [Span(text: "…")])
        }
        return lines
    }

    /// One line for a row: the lines joined by spaces, cut after `limit` characters with "…". The row cuts it again
    /// to its width; the limit keeps a long message from being read whole on every pass.
    static func plain(_ text: String, limit: Int = 300) -> String {
        let joined = lines(text, budget: limit + 1)
            .map { $0.map(\.text).joined().trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }

    /// The message as a Done card draws it (P430 to P432): its lines, tables and fenced code, links kept. With `rows`
    /// (a card under a line limit) it holds at most that many of the card's lines: a line of text counts a line per
    /// `charactersPerRow` characters, a table a line per row with its header and at least one row, a box a line per
    /// line; the last line of text also gets what is left over, and a message stopped before its end ends in "…" (in
    /// its last line, its table's last cell or its box's last line). Reads at most eight times what the lines hold.
    static func blocks(_ text: String, rows limit: Int? = nil) -> [Block] {
        let read = limit.map { text.prefix(max(1, $0) * charactersPerRow * 8) } ?? Substring(text)
        var scanner = Scanner(rest: read, links: true)
        var blocks: [Block] = []
        var used = 0
        var stopped = false
        /// The last block is a box whose fence is still open.
        var boxOpen = false
        func left() -> Int { limit.map { $0 - used } ?? .max }
        loop: while let item = scanner.next() {
            switch item {
            case .fenceOpen:
                boxOpen = false
            case .fenceClose:
                if boxOpen { blocks = trimmedBox(blocks) }
                boxOpen = false
            case let .code(line):
                if boxOpen, case var .code(lines)? = blocks.last {
                    guard left() >= 1 else { stopped = true; break loop }
                    lines.append(line)
                    blocks[blocks.count - 1] = .code(lines)
                    used += 1
                } else if !line.isEmpty {
                    // A box starts at its first line with text.
                    guard left() >= 1 else { stopped = true; break loop }
                    blocks.append(.code([line]))
                    boxOpen = true
                    used += 1
                }
            case let .line(spans):
                guard left() >= 1 else { stopped = true; break loop }
                let cost = max(1, (spans.reduce(0) { $0 + $1.text.count } + charactersPerRow - 1) / charactersPerRow)
                let rows = min(cost, left())
                blocks.append(.line(spans, rows: limit == nil ? nil : rows))
                used += rows
            case let .tableHeader(cells, alignments):
                // A header with no row under it says nothing: it needs room for one row too.
                guard left() >= 2 else { stopped = true; break loop }
                blocks.append(.table(Table(alignments: alignments, header: cells, rows: [])))
                used += 1
            case let .tableRow(cells):
                guard case var .table(table)? = blocks.last else { continue }
                guard left() >= 1 else { stopped = true; break loop }
                table.rows.append(cells)
                blocks[blocks.count - 1] = .table(table)
                used += 1
            }
        }
        if boxOpen { blocks = trimmedBox(blocks) }
        if stopped || !scanner.rest.isEmpty || read.endIndex < text.endIndex {
            blocks = endedEarly(blocks)
        } else if let limit, case let .line(spans, rows?)? = blocks.last {
            // The last line of text may wrap into the lines nothing else took.
            blocks[blocks.count - 1] = .line(spans, rows: rows + max(0, limit - used))
        }
        return blocks
    }

    /// The last box without its trailing blank lines (and gone when it holds nothing else).
    private static func trimmedBox(_ blocks: [Block]) -> [Block] {
        guard case var .code(lines)? = blocks.last else { return blocks }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var kept = blocks
        if lines.isEmpty { kept.removeLast() } else { kept[kept.count - 1] = .code(lines) }
        return kept
    }

    /// A message read only in part says so where it stops: "…" after its last line, in its table's last cell, or on its
    /// box's last line.
    private static func endedEarly(_ blocks: [Block]) -> [Block] {
        var blocks = blocks
        switch blocks.last {
        case nil:
            blocks = [.line([Span(text: "…")], rows: 1)]
        case let .line(spans, rows)?:
            blocks[blocks.count - 1] = .line(merged(spans + [Span(text: "…")]), rows: rows)
        case var .table(table)?:
            if table.rows.isEmpty {
                table.header[table.header.count - 1] = merged(table.header[table.header.count - 1] + [Span(text: "…")])
            } else {
                var last = table.rows[table.rows.count - 1]
                last[last.count - 1] = merged(last[last.count - 1] + [Span(text: "…")])
                table.rows[table.rows.count - 1] = last
            }
            blocks[blocks.count - 1] = .table(table)
        case var .code(lines)?:
            lines[lines.count - 1] += lines[lines.count - 1].isEmpty ? "…" : " …"
            blocks[blocks.count - 1] = .code(lines)
        }
        return blocks
    }

    // MARK: Blocks
    /// What the scanner found on a line (or two: a table's header takes its delimiter row with it).
    private enum Item {
        case line([Span])
        case fenceOpen, fenceClose
        /// A line inside a fence, as written (tabs as four spaces, trailing spaces gone); "" for a blank one.
        case code(String)
        case tableHeader([[Span]], [Table.Alignment])
        case tableRow([[Span]])
    }

    /// Walks a message line by line. `links`: parse `http` and `https` links as links (`blocks`), else as text.
    private struct Scanner {
        var rest: Substring
        let links: Bool
        var fence: Character?
        /// The columns of the table whose rows follow, while one does.
        var columns: Int?

        init(rest: Substring, links: Bool) {
            self.rest = rest
            self.links = links
        }

        mutating func next() -> Item? {
            while let line = takeLine() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // An opening fence may name its language; a closing one is its marks alone.
                if let marker = fenceMarker(trimmed) {
                    if fence == nil {
                        fence = marker
                        columns = nil
                        return .fenceOpen
                    }
                    if marker == fence, trimmed.allSatisfy({ $0 == marker }) {
                        fence = nil
                        return .fenceClose
                    }
                }
                if fence != nil { return .code(codeLine(line)) }
                if let count = columns {
                    // A table's rows run to its first blank line or line with no pipe.
                    if !trimmed.isEmpty, trimmed.contains("|") { return .tableRow(padded(cells(trimmed), count)) }
                    columns = nil
                }
                if trimmed.contains("|"), let alignments = delimiterAlignments(peekLine()), case let header = cells(trimmed),
                   header.count == alignments.count {
                    _ = takeLine()
                    columns = header.count
                    return .tableHeader(header, alignments)
                }
                let spans = block(trimmed, indent: line.prefix { $0 == " " || $0 == "\t" }.count)
                if !spans.isEmpty { return .line(spans) }
            }
            return nil
        }

        private mutating func takeLine() -> Substring? {
            guard !rest.isEmpty else { return nil }
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let line = rest[..<end]
            rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...]
            return line
        }

        private func peekLine() -> Substring? {
            guard !rest.isEmpty else { return nil }
            return rest[..<(rest.firstIndex(where: \.isNewline) ?? rest.endIndex)]
        }

        /// A table row's cells, parsed: split at each pipe not escaped (`\|` is a pipe in the cell) nor inside a code
        /// span, the outer pipes dropped, at most `tableColumns`.
        private func cells(_ trimmed: String) -> [[Span]] {
            var body = Substring(trimmed)
            if body.hasPrefix("|") { body = body.dropFirst() }
            if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
            var cells: [String] = []
            var cell = ""
            var ticks = 0
            var index = body.startIndex
            while index < body.endIndex {
                let ch = body[index]
                if ch == "\\", body.index(after: index) < body.endIndex, body[body.index(after: index)] == "|" {
                    cell.append("|")
                    index = body.index(index, offsetBy: 2)
                    continue
                }
                if ch == "`" {
                    let run = body[index...].prefix { $0 == "`" }.count
                    ticks = ticks == 0 ? run : ticks == run ? 0 : ticks
                    cell += String(repeating: "`", count: run)
                    index = body.index(index, offsetBy: run)
                    continue
                }
                if ch == "|", ticks == 0 {
                    cells.append(cell)
                    cell = ""
                } else {
                    cell.append(ch)
                }
                index = body.index(after: index)
            }
            cells.append(cell)
            return cells.prefix(tableColumns).map { inline($0.trimmingCharacters(in: .whitespaces), [], links: links) }
        }

        /// A row made as wide as its table: GFM fills a short row with empty cells and drops a long row's extra cells.
        private func padded(_ cells: [[Span]], _ count: Int) -> [[Span]] {
            Array((cells + Array(repeating: [], count: max(0, count - cells.count))).prefix(count))
        }

        /// A delimiter row's columns' alignment (`|:---|:--:|---:|`), nil when the line is not one.
        private func delimiterAlignments(_ line: Substring?) -> [Table.Alignment]? {
            guard let line else { return nil }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard isTableDelimiter(trimmed) else { return nil }
            var body = Substring(trimmed)
            if body.hasPrefix("|") { body = body.dropFirst() }
            if body.hasSuffix("|") { body = body.dropLast() }
            var alignments: [Table.Alignment] = []
            for part in body.split(separator: "|", omittingEmptySubsequences: false) {
                let mark = part.trimmingCharacters(in: .whitespaces)
                guard mark.contains("-"), mark.dropFirst().dropLast().allSatisfy({ $0 == "-" }) else { return nil }
                switch (mark.hasPrefix(":"), mark.hasSuffix(":")) {
                case (true, true): alignments.append(.center)
                case (false, true): alignments.append(.trailing)
                default: alignments.append(.leading)
                }
            }
            return alignments.isEmpty ? nil : Array(alignments.prefix(tableColumns))
        }

        private func fenceMarker(_ trimmed: String) -> Character? {
            if trimmed.hasPrefix("```") { return "`" }
            if trimmed.hasPrefix("~~~") { return "~" }
            return nil
        }

        private func codeLine(_ line: Substring) -> String {
            let text = String(line.prefix(parsedLineLength)).replacingOccurrences(of: "\t", with: "    ")
            return String(text.reversed().drop { $0 == " " }.reversed())
        }

        private func block(_ trimmed: String, indent: Int) -> [Span] {
            guard !trimmed.isEmpty, !isRule(trimmed), !isTableDelimiter(trimmed) else { return [] }
            // A quote: its text, without the marks.
            if trimmed.hasPrefix(">") {
                let inner = trimmed.drop { $0 == ">" || $0 == " " }
                return block(String(inner), indent: 0)
            }
            // A container directive's fence (`:::note`, `:::`): only the text between them shows.
            if trimmed.hasPrefix(":::"), !trimmed.contains("{") { return [] }
            if let heading = heading(trimmed) { return inline(heading, .bold, links: links) }
            for bullet in ["- ", "* ", "+ "] where trimmed.hasPrefix(bullet) {
                let depth = String(repeating: "  ", count: min(indent / 2, 4))
                return merged([Span(text: depth + "• ")] + inline(String(trimmed.dropFirst(2).drop(while: \.isWhitespace)), [], links: links))
            }
            // A row of pipes with no delimiter row under it: its cells on one line.
            if trimmed.hasPrefix("|") { return flattened(cells(trimmed)) }
            return inline(trimmed, [], links: links)
        }
    }

    /// A table row on one line: its cells, " · " between them (`| a | b |` → "a · b").
    private static func flattened(_ cells: [[Span]]) -> [Span] {
        var spans: [Span] = []
        for (index, cell) in cells.enumerated() {
            if index > 0 { spans.append(Span(text: " · ")) }
            spans += cell
        }
        return merged(spans)
    }

    /// `---`, `***`, `___` (spaces allowed), and a setext heading's `===` underline.
    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_=".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// `|---|:---:|`
    private static func isTableDelimiter(_ trimmed: String) -> Bool {
        trimmed.contains("|") && trimmed.contains("-") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    private static func heading(_ trimmed: String) -> String? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        // A closing run of #s goes too, when a space parts it from the text (`# Learn C#` keeps its #).
        var text = rest.trimmingCharacters(in: .whitespaces)
        let closing = text.reversed().prefix { $0 == "#" }.count
        let head = text.dropLast(closing)
        if closing > 0, head.isEmpty || head.last == " " { text = head.trimmingCharacters(in: .whitespaces) }
        return text
    }

    // MARK: Inline

    /// Where a span's links stand: whether links are parsed here (`blocks`, and never inside a link's own text), and the
    /// link the text is part of.
    private struct Links {
        var parses: Bool
        var url: URL?
    }

    /// A line's (or a cell's) first `parsedLineLength` characters parsed, the rest as written in the line's style.
    private static func inline(_ text: String, _ style: Style, links: Bool) -> [Span] {
        var spans: [Span] = []
        let chars = Array(text)
        let parsed = min(chars.count, parsedLineLength)
        inline(chars, 0, parsed, style, Links(parses: links), into: &spans)
        if parsed < chars.count { spans.append(Span(text: String(chars[parsed...]), style: style)) }
        return merged(spans)
    }

    private static func inline(_ c: [Character], _ lo: Int, _ hi: Int, _ style: Style, _ links: Links, into spans: inout [Span]) {
        var pending = ""
        var closers = Closers(lo: lo)
        var citationEnd = NextMark("】")
        var autolinkEnd = NextMark(">")
        var braceEnd = NextMark("}")
        func flush() {
            if !pending.isEmpty { spans.append(Span(text: pending, style: style, link: links.url)) }
            pending = ""
        }
        var i = lo
        // Two citations written back to back are two names, so a space goes between them ("b.pdf c.pdf").
        var fileEnd = -1
        func file(_ name: String, end: Int) {
            if fileEnd == i { spans.append(Span(text: " ", style: style, link: links.url)) }
            spans.append(Span(text: name, style: style.union(.mono), link: links.url))
            fileEnd = end
        }
        while i < hi {
            let ch = c[i]
            switch ch {
            case "\\":
                if i + 1 < hi, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                    pending.append(c[i + 1])
                    i += 2
                    continue
                }
            case "`":
                let n = run(c, i, hi)
                if let close = matchingRun(c, from: i + n, hi, of: "`", length: n) {
                    flush()
                    var code = String(c[(i + n)..<close])
                    if code.count > 2, code.first == " ", code.last == " " { code = String(code.dropFirst().dropLast()) }
                    spans.append(Span(text: code, style: style.union(.mono), link: links.url))
                    i = close + n
                    continue
                }
                pending += String(c[i..<(i + n)])
                i += n
                continue
            case "*", "_":
                let n = run(c, i, hi)
                if n <= 3, let close = emphasisCloser(c, i, n, hi, &closers) {
                    flush()
                    let emphasis: Style = n == 1 ? .italic : n == 2 ? .bold : [.bold, .italic]
                    inline(c, i + n, close, style.union(emphasis), links, into: &spans)
                    i = close + n
                    continue
                }
                pending += String(c[i..<(i + n)])
                i += n
                continue
            case "~":
                let n = run(c, i, hi)
                if n == 2, let close = matchingRun(c, from: i + 2, hi, of: "~", length: 2), close > i + 2 {
                    flush()
                    inline(c, i + 2, close, style, links, into: &spans)
                    i = close + 2
                    continue
                }
                pending += String(c[i..<(i + n)])
                i += n
                continue
            case "!":
                // An image: its text, never fetched and never a link.
                if i + 1 < hi, c[i + 1] == "[", let link = link(c, i + 1, hi) {
                    flush()
                    inline(c, link.text.lowerBound, link.text.upperBound, style, Links(parses: false, url: links.url), into: &spans)
                    i = link.end
                    continue
                }
            case "[":
                if let link = link(c, i, hi) {
                    flush()
                    let target = links.parses ? SafeLink.url(markdownTarget(c[link.target])) : nil
                    if let target, SafeLink.misleads(label: String(c[link.text]), target: target) {
                        // Text that names another address shows where the link goes instead (P431).
                        spans.append(Span(text: target.absoluteString, style: style, link: target))
                    } else {
                        inline(c, link.text.lowerBound, link.text.upperBound, style, Links(parses: false, url: target ?? links.url), into: &spans)
                    }
                    i = link.end
                    continue
                }
            case "【":
                if let close = citationEnd.index(in: c, from: i, hi), let citation = bracketCitation(c, i, close) {
                    flush()
                    if let name = citation.name { file(name, end: citation.end) }
                    i = citation.end
                    continue
                }
            case ":":
                if i == lo || !(c[i - 1].isLetter || c[i - 1].isNumber || c[i - 1] == ":"), let directive = directive(c, i, hi, &braceEnd) {
                    flush()
                    switch directive.shows {
                    case let .file(name): file(name, end: directive.end)
                    case let .label(range): inline(c, range.lowerBound, range.upperBound, style, links, into: &spans)
                    case .nothing: break
                    }
                    i = directive.end
                    continue
                }
            case "<":
                if let close = autolinkEnd.index(in: c, from: i, hi), let autolink = autolink(c, i, close) {
                    if links.parses, let url = SafeLink.url(autolink.url) {
                        flush()
                        spans.append(Span(text: autolink.url, style: style, link: url))
                    } else {
                        pending += autolink.url
                    }
                    i = autolink.end
                    continue
                }
            case "h", "H":
                // A bare address (GFM's autolink literal), where a word starts.
                if links.parses, i == lo || !(isWord(c[i - 1]) || c[i - 1] == "/" || c[i - 1] == "@"),
                   let end = bareAddressEnd(c, i, hi), let url = SafeLink.url(String(c[i..<end])) {
                    flush()
                    spans.append(Span(text: String(c[i..<end]), style: style, link: url))
                    i = end
                    continue
                }
            default:
                break
            }
            pending.append(ch)
            i += 1
        }
        flush()
    }

    /// Where a bare `http://` or `https://` address that starts at `i` ends: at whitespace or `<`, less the punctuation
    /// that ends a sentence (`.`, `,`, `:`, `;`, `!`, `?`, quotes, `*`, `_`, `~`) and a `)` or `]` it did not open; nil
    /// when none starts there or nothing follows the scheme.
    private static func bareAddressEnd(_ c: [Character], _ i: Int, _ hi: Int) -> Int? {
        let schemes: [[Character]] = [Array("https://"), Array("http://")]
        guard let scheme = schemes.first(where: { s in i + s.count <= hi && zip(s, c[i..<(i + s.count)]).allSatisfy { $0 == Character($1.lowercased()) } })
        else { return nil }
        var end = i + scheme.count
        while end < hi, !c[end].isWhitespace, c[end] != "<" { end += 1 }
        while end > i + scheme.count {
            let last = c[end - 1]
            if ".,:;!?'\"*_~".contains(last) {
                end -= 1
            } else if last == ")" || last == "]" {
                let open: Character = last == ")" ? "(" : "["
                let opened = c[i..<end].filter { $0 == open }.count, closed = c[i..<end].filter { $0 == last }.count
                guard closed > opened else { break }
                end -= 1
            } else {
                break
            }
        }
        return end > i + scheme.count ? end : nil
    }

    /// A link's target as written between its parentheses: `<…>` unwrapped, a title after it (`"…"`) dropped.
    private static func markdownTarget(_ written: ArraySlice<Character>) -> String {
        let text = String(written).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("<"), let close = text.firstIndex(of: ">") { return String(text[text.index(after: text.startIndex)..<close]) }
        return String(text.prefix { !$0.isWhitespace })
    }

    /// How many `c[i]` in a row start at `i`.
    private static func run(_ c: [Character], _ i: Int, _ hi: Int) -> Int {
        var j = i
        while j < hi, c[j] == c[i] { j += 1 }
        return j - i
    }

    /// The start of the next run of exactly `length` `mark`s from `start`.
    private static func matchingRun(_ c: [Character], from start: Int, _ hi: Int, of mark: Character, length: Int) -> Int? {
        var j = start
        while j < hi {
            guard c[j] == mark else { j += 1; continue }
            let n = run(c, j, hi)
            if n == length { return j }
            j += n
        }
        return nil
    }

    /// CommonMark's flanking rules, simplified: an opener is not followed by a space (nor by punctuation unless it
    /// follows a space or punctuation), a closer mirrors it, and `_` never opens or closes inside a word, so
    /// `snake_case_name` and `2 * 3 * 4` stay as they are.
    private static func canOpen(_ c: [Character], _ i: Int, _ n: Int, _ hi: Int) -> Bool {
        let next = i + n
        guard next < hi, !c[next].isWhitespace else { return false }
        let before: Character? = i > 0 ? c[i - 1] : nil
        if isPunctuation(c[next]), let before, !(before.isWhitespace || isPunctuation(before)) { return false }
        if c[i] == "_", let before, isWord(before) { return false }
        return true
    }

    private static func canClose(_ c: [Character], _ j: Int, _ m: Int, _ hi: Int) -> Bool {
        let last = c[j - 1]
        guard !last.isWhitespace else { return false }
        let after: Character? = j + m < hi ? c[j + m] : nil
        if isPunctuation(last), let after, !(after.isWhitespace || isPunctuation(after)) { return false }
        if c[j] == "_", let after, isWord(after) { return false }
        return true
    }

    /// What a span's emphasis searches have learned: each opener's closer (`unclosed`, or `unopened` for marks that
    /// cannot open), and for each mark the last index where a run of at least one, two or three of them can close, so
    /// an opener with none after it (a line of `*.swift` globs) fails at once instead of searching to the end.
    private struct Closers {
        static let unclosed = -1, unopened = -2
        let lo: Int
        var known: [Int: Int] = [:]
        var last: [Character: [Int]] = [:]
    }

    /// Where the emphasis opened by the `n` marks at `i` closes: the first run of at least `n` of the same marks that
    /// can close, taking its first `n` (`*more***` closes the `*` and leaves `**` for an outer bold). A nested pair
    /// (`*a **b** c*`) and code spans are stepped over. `closers` keeps each opener's answer, so a line of unmatched
    /// marks is searched once per mark, not once per way to nest them.
    private static func emphasisCloser(_ c: [Character], _ i: Int, _ n: Int, _ hi: Int, _ closers: inout Closers) -> Int? {
        if let known = closers.known[i] { return known < 0 ? nil : known }
        guard canOpen(c, i, n, hi) else {
            closers.known[i] = Closers.unopened
            return nil
        }
        var found: Int?
        defer { closers.known[i] = found ?? Closers.unclosed }
        let mark = c[i]
        if closers.last[mark] == nil { closers.last[mark] = lastClosers(c, closers.lo, hi, of: mark) }
        guard let last = closers.last[mark], last[n - 1] > i + n else { return nil }
        var j = i + n
        while j < hi {
            if c[j] == "`" {
                let m = run(c, j, hi)
                j = matchingRun(c, from: j + m, hi, of: "`", length: m).map { $0 + m } ?? j + m
                continue
            }
            if c[j] == "\\" { j += 2; continue }
            guard c[j] == mark else { j += 1; continue }
            let m = run(c, j, hi)
            if m >= n, j > i + n, canClose(c, j, m, hi) {
                found = j
                return j
            }
            if m <= 3 {
                if let inner = emphasisCloser(c, j, m, hi, &closers) {
                    j = inner + m
                    continue
                }
                // An opener of no more marks searched on from here and found no closer, and this search would step
                // just as it did, so none is ahead: a line of unmatched openers between pairs is walked once, not once
                // per opener.
                if m <= n, closers.known[j] == Closers.unclosed { return nil }
            }
            j += m
        }
        return nil
    }

    /// For runs of at least 1, 2 and 3 `mark`s: the last index in `lo+1..<hi` where such a run can close (-1 for
    /// none), counting every index inside a run, as the search may start a run there.
    private static func lastClosers(_ c: [Character], _ lo: Int, _ hi: Int, of mark: Character) -> [Int] {
        var last = [-1, -1, -1]
        var j = lo + 1
        while j < hi {
            guard c[j] == mark else { j += 1; continue }
            let end = j + run(c, j, hi)
            for k in j..<end where canClose(c, k, end - k, hi) {
                for n in 1...min(3, end - k) { last[n - 1] = k }
            }
            j = end
        }
        return last
    }

    private static func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber }
    private static func isPunctuation(_ ch: Character) -> Bool { ch.isPunctuation || ch.isSymbol }

    /// `[text](target)` from the `[`: the text's range, the target's (between the parentheses) and the index after `)`.
    /// A bracket not followed by a target (`[1]`) is text.
    private static func link(_ c: [Character], _ i: Int, _ hi: Int) -> (text: Range<Int>, target: Range<Int>, end: Int)? {
        guard let close = closing(c, i, hi, open: "[", close: "]"), close + 1 < hi, c[close + 1] == "(",
              let end = closing(c, close + 1, hi, open: "(", close: ")") else { return nil }
        return (i + 1..<close, close + 2..<end, end + 1)
    }

    /// The index of the bracket closing the one at `i`, counting nested pairs. Deeper than 16 it is taken as unclosed,
    /// so a line of unclosed `[` is not searched to its end once per bracket.
    private static func closing(_ c: [Character], _ i: Int, _ hi: Int, open: Character, close: Character) -> Int? {
        var depth = 0
        var j = i
        while j < hi {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == open {
                depth += 1
                if depth > 16 { return nil }
            } else if c[j] == close {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    private enum DirectiveText { case file(String), label(Range<Int>), nothing }

    /// `:name[label]{attributes}` (one to three colons): a `path` or `file` attribute shows as the file's name, else
    /// the label shows, else nothing when it is Codex's (`codex-…`, `code-comment`) or a leaf or container directive
    /// (`::name{…}`), which prose doesn't write. Any other (`:root{color:red}`), and a name with neither `[…]` nor
    /// `{…}` (`Note:foo`, `:smile:`), is text.
    private static func directive(_ c: [Character], _ i: Int, _ hi: Int, _ braceEnd: inout NextMark) -> (shows: DirectiveText, end: Int)? {
        var j = i
        while j < hi, c[j] == ":", j - i < 3 { j += 1 }
        let colons = j - i
        guard j < hi, c[j].isASCII, c[j].isLetter else { return nil }
        let nameStart = j
        while j < hi, c[j].isASCII, c[j].isLetter || c[j].isNumber || c[j] == "-" || c[j] == "_" { j += 1 }
        let name = String(c[nameStart..<j])
        var label: Range<Int>?
        if j < hi, c[j] == "[", let close = closing(c, j, hi, open: "[", close: "]") {
            label = j + 1..<close
            j = close + 1
        }
        var attributes: [String: String]?
        if j < hi, c[j] == "{", braceEnd.index(in: c, from: j, hi) != nil, let close = attributesEnd(c, j, hi) {
            attributes = parseAttributes(c[(j + 1)..<close])
            j = close + 1
        }
        guard label != nil || attributes != nil else { return nil }
        if let path = attributes?["path"] ?? attributes?["file"], let name = fileName(path) { return (.file(name), j) }
        if let label, !label.isEmpty { return (.label(label), j) }
        guard colons > 1 || name.hasPrefix("codex-") || name == "code-comment" else { return nil }
        return (.nothing, j)
    }

    /// The `}` ending attributes that start at `i`, past any quoted value.
    private static func attributesEnd(_ c: [Character], _ i: Int, _ hi: Int) -> Int? {
        var quote: Character?
        var j = i + 1
        while j < hi {
            if let open = quote {
                if c[j] == open { quote = nil }
            } else if c[j] == "\"" || c[j] == "'" {
                quote = c[j]
            } else if c[j] == "}" {
                return j
            }
            j += 1
        }
        return nil
    }

    /// `key="value" key='value' key=value`; `#id` and `.class` are ignored.
    private static func parseAttributes(_ c: ArraySlice<Character>) -> [String: String] {
        var result: [String: String] = [:]
        var j = c.startIndex
        while j < c.endIndex {
            while j < c.endIndex, c[j].isWhitespace { j += 1 }
            let keyStart = j
            while j < c.endIndex, !c[j].isWhitespace, c[j] != "=" { j += 1 }
            let key = String(c[keyStart..<j])
            guard j < c.endIndex, c[j] == "=" else { continue }
            j += 1
            var value = ""
            if j < c.endIndex, c[j] == "\"" || c[j] == "'" {
                let quote = c[j]
                j += 1
                while j < c.endIndex, c[j] != quote { value.append(c[j]); j += 1 }
                j += 1
            } else {
                while j < c.endIndex, !c[j].isWhitespace { value.append(c[j]); j += 1 }
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// The next `mark` at or after an index. The indexes asked for only grow within a span, so each stretch of the
    /// line is searched once: a line of unclosed `【`, `<` or `{` costs its length, not its length squared.
    private struct NextMark {
        let mark: Character
        private var searchedFrom = Int.max
        private var found: Int?

        init(_ mark: Character) { self.mark = mark }

        mutating func index(in c: [Character], from i: Int, _ hi: Int) -> Int? {
            if i < searchedFrom || (found ?? hi) < i {
                searchedFrom = i
                found = c[i..<hi].firstIndex(of: mark)
            }
            return found
        }
    }

    /// `【F:path†L1-L5】` (Codex's older citations), closed at `close`: the file's name; any other `【…】` is text.
    private static func bracketCitation(_ c: [Character], _ i: Int, _ close: Int) -> (name: String?, end: Int)? {
        guard close - i > 3, c[i + 1] == "F", c[i + 2] == ":" else { return nil }
        let inner = c[(i + 3)..<close]
        let path = inner.firstIndex(of: "†").map { inner[..<$0] } ?? inner
        return (fileName(String(path)), close + 1)
    }

    /// `<https://example.com>`, closed at `close`: its address as text.
    private static func autolink(_ c: [Character], _ i: Int, _ close: Int) -> (url: String, end: Int)? {
        let inner = String(c[(i + 1)..<close])
        guard inner.contains("://"), let scheme = inner.split(separator: ":").first, !scheme.isEmpty,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }),
              !inner.contains(where: \.isWhitespace) else { return nil }
        return (inner, close + 1)
    }

    /// The last path component: `/Users/x/notes.pdf` → `notes.pdf`; nil when there is none.
    static func fileName(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let name = trimmed.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// Neighbouring spans in the same style become one.
    private static func merged(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans where !span.text.isEmpty {
            if let last = result.last, last.style == span.style, last.link == span.link {
                result[result.count - 1].text += span.text
            } else {
                result.append(span)
            }
        }
        return result
    }
}
