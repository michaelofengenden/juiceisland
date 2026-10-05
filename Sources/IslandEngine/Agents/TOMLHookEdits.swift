import Foundation

/// Juice's `[[hooks]]` tables in Kimi's `config.toml`, read and edited in place (P1130). Each entry is a table of its
/// own:
///
///     [[hooks]]
///     event = "Stop"
///     command = "'/…/bin/JuiceHooks' --source kimi"
///     timeout = 10
///
/// Connect appends Juice's tables at the end of the file, each after a blank line, and Remove takes each of them out
/// with the blank line before it, so Connect then Remove gives the file back byte for byte; every other line, comment
/// and table stays as it was. A file this cannot write back exactly is never written (`Problem.unwritable`, Add by
/// hand): one that does not end in a newline or has a carriage return, one that names `hooks` other than as `[[hooks]]`
/// tables (`hooks = []`, `[hooks]`, a `[hooks.x]` sub-table), one that is not UTF-8 or whose strings or brackets do not
/// close (`Problem.invalid`). Pure: data in, data out.
public enum TOMLHookEdits {
    /// Kimi Code (smol-toml) and the older Kimi CLI (Python's tomllib) both read `[[hooks]]` tables wherever they sit in
    /// the file, before or after other tables (checked with both, 2026-10-03).
    public static let tableHeader = "[[hooks]]"

    // MARK: Reading

    public static func read(_ data: Data?, expected: [HookEntrySpec], owners: HookFileEdits.Owners) throws -> HookFileEdits.Reading {
        guard let data else { return HookFileEdits.Reading() }
        let file = try Scan(data)
        var reading = HookFileEdits.Reading()
        reading.hasHooks = !file.tables.isEmpty
        for table in file.tables {
            guard let command = table.command else {
                reading.others += 1
                continue
            }
            if owners.isOurs(command) {
                reading.ours += 1
            } else if owners.isOld(command) {
                reading.old += 1
            } else {
                reading.others += 1
                if HookFileEdits.isVibeIsland(command) { reading.vibe += 1 }
            }
        }
        reading.complete = expected.filter { spec in file.tables.contains { isCorrect($0, spec: spec, owners: owners) } }
        return reading
    }

    /// Whether Juice can write the file back exactly (`nil`: no file, which Connect makes).
    public static func canWrite(_ data: Data?) -> Bool {
        guard let data else { return true }
        return (try? Scan(data))?.writable == true
    }

    /// The file names `hooks` as something other than `[[hooks]]` tables: Add by hand's tables go in its place.
    public static func namesHooksOtherwise(_ data: Data) -> Bool { (try? Scan(data))?.hooksOtherwise ?? false }

    // MARK: Edits

    /// Juice's tables as `expected` has them, at the end of the file: nothing changes when they are all there as Juice
    /// writes them and none of Juice's is wrong; otherwise every one of Juice's (and of its older ones) comes out and the
    /// whole set goes in again. A missing file starts empty.
    public static func installing(_ data: Data?, expected: [HookEntrySpec], command: String,
                                  owners: HookFileEdits.Owners) throws -> Data {
        let original = data ?? Data()
        let file = try Scan(original)
        guard file.writable else { throw HookFileEdits.Problem.unwritable }
        let mine = file.tables.filter { $0.command.map { owners.isOurs($0) || owners.isOld($0) } ?? false }
        let allCorrect = mine.count == expected.count
            && expected.allSatisfy { spec in mine.contains { isCorrect($0, spec: spec, owners: owners) } }
        if allCorrect { return original }
        var text = try removingTables(file, owners: owners)
        text += (text.isEmpty ? "" : "\n") + tables(expected, command: command)
        return Data(text.utf8)
    }

    /// Takes every table of Juice's out, each with the blank line before it; never another's. nil: nothing is left of the
    /// file, so it goes (Connect made it, or it held only Juice's).
    public static func removing(_ data: Data, owners: HookFileEdits.Owners) throws -> Data? {
        let file = try Scan(data)
        guard file.tables.contains(where: { $0.command.map { owners.isOurs($0) || owners.isOld($0) } ?? false }) else { return data }
        guard file.writable else { throw HookFileEdits.Problem.unwritable }
        let text = try removingTables(file, owners: owners)
        return text.isEmpty ? nil : Data(text.utf8)
    }

    /// Juice's tables as Connect writes them, a blank line between each: Add by hand's lines too.
    public static func tables(_ expected: [HookEntrySpec], command: String) -> String {
        expected.map { table($0, command: command) }.joined(separator: "\n")
    }

    static func table(_ spec: HookEntrySpec, command: String) -> String {
        var lines = [tableHeader, "event = \(quoted(spec.event))"]
        if let matcher = spec.matcher { lines.append("matcher = \(quoted(matcher))") }
        lines.append("command = \(quoted(command))")
        if let timeout = spec.timeout { lines.append("timeout = \(timeout)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A TOML basic string.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    // MARK: Pieces

    static func isCorrect(_ table: Scan.Table, spec: HookEntrySpec, owners: HookFileEdits.Owners) -> Bool {
        guard let command = table.command, owners.isOurs(command) else { return false }
        return table.event == spec.event && table.matcher == spec.matcher && table.timeout == spec.timeout && table.otherKeys == 0
    }

    /// The file without Juice's tables: each table's own lines (its header to its last key, never the blank lines or
    /// comments after it, which belong to what follows) and one blank line just before it.
    static func removingTables(_ file: Scan, owners: HookFileEdits.Owners) throws -> String {
        var drop = IndexSet()
        for table in file.tables where table.command.map({ owners.isOurs($0) || owners.isOld($0) }) ?? false {
            drop.insert(integersIn: table.lines)
            let before = table.lines.lowerBound - 1
            if before >= 0, !drop.contains(before), file.lines[before].trimmingCharacters(in: .whitespaces).isEmpty {
                drop.insert(before)
            }
        }
        return file.lines.enumerated().filter { !drop.contains($0.offset) }.map { $0.element + "\n" }.joined()
    }

    // MARK: The scan

    /// A line-by-line reading of a TOML file, enough to find its `[[hooks]]` tables and their simple keys without ever
    /// mistaking a line inside a string, an array or an inline table for a header.
    struct Scan {
        struct Table {
            /// Its header line to its last key's last line.
            var lines: Range<Int>
            var event: String?
            var command: String?
            var matcher: String?
            var timeout: Int?
            /// Keys besides those four, or values this does not read: never as Juice writes it.
            var otherKeys = 0
        }

        /// The file's lines, without their newlines (the last one, empty, after the final newline, left out).
        var lines: [String] = []
        var tables: [Table] = []
        /// Juice can write it back exactly.
        var writable = true
        /// `hooks` is there as something other than `[[hooks]]` tables (`hooks = []`, `[hooks]`, `[hooks.x]`).
        var hooksOtherwise = false

        init(_ data: Data) throws {
            guard let text = String(data: data, encoding: .utf8) else { throw HookFileEdits.Problem.invalid }
            if text.contains("\r") { writable = false }
            if !text.isEmpty, !text.hasSuffix("\n") { writable = false }
            var split = text.components(separatedBy: "\n")
            if split.last == "" { split.removeLast() }
            lines = split
            var state = State()
            var current: Table?
            var inHooks = false
            var seenHeader = false
            for (index, line) in lines.enumerated() {
                if state.isOpen {
                    // A line inside a multi-line string, array or inline table: part of the statement above.
                    try state.consume(Array(line.utf8)[...])
                    if inHooks, var table = current {
                        table.lines = table.lines.lowerBound..<(index + 1)
                        current = table
                    }
                    continue
                }
                let bytes = Array(line.utf8)
                var start = 0
                while start < bytes.count, bytes[start] == 0x20 || bytes[start] == 0x09 { start += 1 }
                guard start < bytes.count, bytes[start] != UInt8(ascii: "#") else { continue }
                if bytes[start] == UInt8(ascii: "[") {
                    let header = try Self.header(bytes[start...])
                    seenHeader = true
                    if let table = current { tables.append(table) }
                    current = nil
                    inHooks = false
                    if header.path.first == "hooks" {
                        guard header.path == ["hooks"], header.isArray else {
                            writable = false
                            hooksOtherwise = true
                            continue
                        }
                        current = Table(lines: index..<(index + 1))
                        inHooks = true
                    }
                    continue
                }
                let pair = try Self.pair(bytes[start...], state: &state)
                if !inHooks {
                    // `hooks = […]` or `hooks.x = …` above every table: the array Juice's tables would add to, as something
                    // else.
                    if !seenHeader, pair.key.first == "hooks" {
                        writable = false
                        hooksOtherwise = true
                    }
                    continue
                }
                guard var table = current else { continue }
                table.lines = table.lines.lowerBound..<(index + 1)
                switch (pair.key, pair.value) {
                case (["event"], let .string(value)?) where table.event == nil: table.event = value
                case (["command"], let .string(value)?) where table.command == nil: table.command = value
                case (["matcher"], let .string(value)?) where table.matcher == nil: table.matcher = value
                case (["timeout"], let .integer(value)?) where table.timeout == nil: table.timeout = value
                default: table.otherKeys += 1
                }
                current = table
            }
            guard !state.isOpen else { throw HookFileEdits.Problem.invalid }
            if let table = current { tables.append(table) }
        }

        enum Value: Equatable {
            case string(String)
            case integer(Int)
        }

        /// A header line: `[a.b]` or `[[a.b]]`, its path's keys unquoted, and nothing after it but a comment.
        static func header(_ bytes: ArraySlice<UInt8>) throws -> (path: [String], isArray: Bool) {
            var index = bytes.startIndex
            let isArray = bytes.count > 1 && bytes[index + 1] == UInt8(ascii: "[")
            index += isArray ? 2 : 1
            var cursor = Cursor(bytes: bytes, index: index)
            let path = try cursor.keyPath(until: UInt8(ascii: "]"))
            guard cursor.take(UInt8(ascii: "]")), !isArray || cursor.take(UInt8(ascii: "]")) else { throw HookFileEdits.Problem.invalid }
            cursor.skipSpace()
            guard cursor.atEnd || cursor.peek == UInt8(ascii: "#") else { throw HookFileEdits.Problem.invalid }
            return (path, isArray)
        }

        /// A `key = value` line: its key path, and its value when it is a one-line string or an integer. A value that
        /// opens a multi-line string, array or inline table leaves `state` open for the lines after it.
        static func pair(_ bytes: ArraySlice<UInt8>, state: inout State) throws -> (key: [String], value: Value?) {
            var cursor = Cursor(bytes: bytes, index: bytes.startIndex)
            let key = try cursor.keyPath(until: UInt8(ascii: "="))
            guard cursor.take(UInt8(ascii: "=")) else { throw HookFileEdits.Problem.invalid }
            cursor.skipSpace()
            let rest = bytes[cursor.index...]
            var simple = Cursor(bytes: rest, index: rest.startIndex)
            let value = simple.simpleValue()
            if value != nil {
                simple.skipSpace()
                if simple.atEnd || simple.peek == UInt8(ascii: "#") { return (key, value) }
            }
            try state.consume(rest)
            return (key, nil)
        }
    }

    /// What is still open at the end of a line: a multi-line string, or how deep in arrays and inline tables.
    struct State {
        enum Quote { case basic, literal }
        var multiline: Quote?
        var depth = 0

        var isOpen: Bool { multiline != nil || depth > 0 }

        /// Reads one line's worth of a value (from just after `=`, or a whole continuation line).
        mutating func consume(_ bytes: ArraySlice<UInt8>) throws {
            var index = bytes.startIndex
            let end = bytes.endIndex
            func has(_ text: String, at position: Int) -> Bool {
                let needle = Array(text.utf8)
                return position + needle.count <= end && Array(bytes[position..<(position + needle.count)]) == needle
            }
            while index < end {
                if let quote = multiline {
                    let close = quote == .basic ? "\"\"\"" : "'''"
                    if quote == .basic, bytes[index] == UInt8(ascii: "\\") {
                        index += 2
                        continue
                    }
                    if has(close, at: index) {
                        index += 3
                        // Up to two more quotes belong to the string.
                        let mark = quote == .basic ? UInt8(ascii: "\"") : UInt8(ascii: "'")
                        var extra = 0
                        while extra < 2, index < end, bytes[index] == mark {
                            index += 1
                            extra += 1
                        }
                        multiline = nil
                        continue
                    }
                    index += 1
                    continue
                }
                switch bytes[index] {
                case UInt8(ascii: "#"):
                    return
                case UInt8(ascii: "\""):
                    if has("\"\"\"", at: index) {
                        multiline = .basic
                        index += 3
                        continue
                    }
                    index += 1
                    var closed = false
                    while index < end {
                        if bytes[index] == UInt8(ascii: "\\") {
                            index += 2
                            continue
                        }
                        if bytes[index] == UInt8(ascii: "\"") {
                            closed = true
                            index += 1
                            break
                        }
                        index += 1
                    }
                    guard closed else { throw HookFileEdits.Problem.invalid }
                case UInt8(ascii: "'"):
                    if has("'''", at: index) {
                        multiline = .literal
                        index += 3
                        continue
                    }
                    guard let close = bytes[(index + 1)...].firstIndex(of: UInt8(ascii: "'")) else { throw HookFileEdits.Problem.invalid }
                    index = close + 1
                case UInt8(ascii: "["), UInt8(ascii: "{"):
                    depth += 1
                    index += 1
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    depth -= 1
                    guard depth >= 0 else { throw HookFileEdits.Problem.invalid }
                    index += 1
                default:
                    index += 1
                }
            }
        }
    }

    /// Reads keys and simple values out of one line's bytes.
    struct Cursor {
        let bytes: ArraySlice<UInt8>
        var index: Int

        var atEnd: Bool { index >= bytes.endIndex }
        var peek: UInt8? { atEnd ? nil : bytes[index] }

        mutating func skipSpace() {
            while let byte = peek, byte == 0x20 || byte == 0x09 { index += 1 }
        }

        mutating func take(_ byte: UInt8) -> Bool {
            skipSpace()
            guard peek == byte else { return false }
            index += 1
            return true
        }

        /// `a.b."c d".'e'` up to `stop`, each key unquoted.
        mutating func keyPath(until stop: UInt8) throws -> [String] {
            var path: [String] = []
            while true {
                skipSpace()
                guard let byte = peek else { throw HookFileEdits.Problem.invalid }
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    guard let text = basicString() else { throw HookFileEdits.Problem.invalid }
                    path.append(text)
                } else if byte == UInt8(ascii: "'") {
                    guard let close = bytes[(index + 1)...].firstIndex(of: UInt8(ascii: "'")) else { throw HookFileEdits.Problem.invalid }
                    path.append(String(decoding: bytes[(index + 1)..<close], as: UTF8.self))
                    index = close + 1
                } else {
                    let start = index
                    while let byte = peek, Self.isBare(byte) { index += 1 }
                    guard index > start else { throw HookFileEdits.Problem.invalid }
                    path.append(String(decoding: bytes[start..<index], as: UTF8.self))
                }
                skipSpace()
                if peek == UInt8(ascii: ".") {
                    index += 1
                    continue
                }
                guard peek == stop else { throw HookFileEdits.Problem.invalid }
                return path
            }
        }

        static func isBare(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }

        /// A one-line basic string, a literal string or a decimal integer; nil for anything else (the cursor then stays).
        mutating func simpleValue() -> TOMLHookEdits.Scan.Value? {
            let start = index
            guard let byte = peek else { return nil }
            if byte == UInt8(ascii: "\""), !(index + 2 < bytes.endIndex && bytes[index + 1] == byte && bytes[index + 2] == byte) {
                index += 1
                if let text = basicString() { return .string(text) }
            } else if byte == UInt8(ascii: "'"), !(index + 2 < bytes.endIndex && bytes[index + 1] == byte && bytes[index + 2] == byte),
                      let close = bytes[(index + 1)...].firstIndex(of: byte) {
                let text = String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
                index = close + 1
                return .string(text)
            } else if byte == UInt8(ascii: "+") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                var digits = ""
                if byte == UInt8(ascii: "+") { index += 1 }
                while let next = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(next) || next == UInt8(ascii: "_") {
                    if next != UInt8(ascii: "_") { digits.append(Character(UnicodeScalar(next))) }
                    index += 1
                }
                let after = peek
                if let number = Int(digits), after == nil || after == 0x20 || after == 0x09 || after == UInt8(ascii: "#") {
                    return .integer(number)
                }
            }
            index = start
            return nil
        }

        /// The rest of a basic string, after its opening quote, escapes read; nil when it does not close on this line.
        mutating func basicString() -> String? {
            var scalars = String.UnicodeScalarView()
            var chunk = index
            func flush(_ upTo: Int) {
                scalars.append(contentsOf: String(decoding: bytes[chunk..<upTo], as: UTF8.self).unicodeScalars)
            }
            while let byte = peek {
                if byte == UInt8(ascii: "\"") {
                    flush(index)
                    index += 1
                    return String(scalars)
                }
                if byte == UInt8(ascii: "\\") {
                    flush(index)
                    index += 1
                    guard let escape = peek else { return nil }
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "e"): scalars.append("\u{1B}")
                    case UInt8(ascii: "u"), UInt8(ascii: "U"), UInt8(ascii: "x"):
                        let count = escape == UInt8(ascii: "u") ? 4 : escape == UInt8(ascii: "U") ? 8 : 2
                        guard index + count <= bytes.endIndex,
                              let value = UInt32(String(decoding: bytes[index..<(index + count)], as: UTF8.self), radix: 16),
                              let scalar = Unicode.Scalar(value) else { return nil }
                        scalars.append(scalar)
                        index += count
                    default:
                        return nil
                    }
                    chunk = index
                    continue
                }
                index += 1
            }
            return nil
        }
    }
}
