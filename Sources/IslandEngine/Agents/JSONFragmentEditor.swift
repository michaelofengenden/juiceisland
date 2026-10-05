import Foundation

/// A JSON value Juice writes into another tool's config: its keys in the order given, so the text is the same at every
/// write (P916).
public indirect enum JSONFragment: Equatable, Sendable {
    case object([(String, JSONFragment)])
    case array([JSONFragment])
    case string(String)
    case int(Int)
    case bool(Bool)

    public static func == (lhs: JSONFragment, rhs: JSONFragment) -> Bool {
        switch (lhs, rhs) {
        case let (.object(a), .object(b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(a), .array(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.bool(a), .bool(b)): a == b
        default: false
        }
    }

    /// The value as text. `indent` nil writes it on one line, as a compact file has it; otherwise every line after the
    /// first starts with `base` plus one `indent` per level, and the closing bracket with `base`.
    public func render(indent: String?, base: String = "") -> String {
        switch self {
        case let .string(text): return Self.quoted(text)
        case let .int(number): return String(number)
        case let .bool(flag): return flag ? "true" : "false"
        case let .array(items):
            guard !items.isEmpty else { return "[]" }
            guard let indent else { return "[" + items.map { $0.render(indent: nil) }.joined(separator: ",") + "]" }
            let inner = base + indent
            return "[\n" + items.map { inner + $0.render(indent: indent, base: inner) }.joined(separator: ",\n") + "\n" + base + "]"
        case let .object(members):
            guard !members.isEmpty else { return "{}" }
            guard let indent else {
                return "{" + members.map { Self.quoted($0.0) + ":" + $0.1.render(indent: nil) }.joined(separator: ",") + "}"
            }
            let inner = base + indent
            return "{\n" + members.map { inner + Self.quoted($0.0) + ": " + $0.1.render(indent: indent, base: inner) }
                .joined(separator: ",\n") + "\n" + base + "}"
        }
    }

    /// JSON's quoting, with `/` left as it is (P25: no escaped slashes in a path).
    public static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}

/// A JSON file read for where each value sits, so Juice can add or take out its own entries and leave every other
/// byte as it was (P916). Strict JSON only: a comment, a trailing comma, a byte-order mark or anything else that is not
/// JSON is refused, and such a file gets "Add by hand" instead of a write (P25).
public struct JSONSpanDocument: Sendable {
    public enum Problem: Error, Equatable, Sendable {
        /// `//` or `/* */`: JSONC, which Juice never rewrites.
        case comments
        case invalid
    }

    public final class Node: @unchecked Sendable {
        public enum Kind: Sendable { case object, array, string, number, literal }
        public let kind: Kind
        /// The value's first byte.
        public let start: Int
        /// The byte after its last.
        public internal(set) var end: Int = 0
        /// An object's members: the key, where its opening quote is, and the value.
        public internal(set) var members: [(key: String, keyStart: Int, value: Node)] = []
        public internal(set) var elements: [Node] = []
        /// A string's decoded text.
        public internal(set) var text: String?
        /// A number or literal as written.
        public internal(set) var raw: String?

        init(kind: Kind, start: Int) {
            self.kind = kind
            self.start = start
        }

        public func member(_ key: String) -> Node? { members.first { $0.key == key }?.value }

        public var int: Int? { kind == .number ? raw.flatMap { Int($0) } : nil }
    }

    public let bytes: [UInt8]
    public let root: Node

    public init(data: Data) throws {
        bytes = Array(data)
        var parser = Parser(bytes: bytes)
        parser.skipSpace()
        if parser.problem != nil { throw parser.problem! }
        guard let value = parser.value() else { throw parser.problem ?? .invalid }
        parser.skipSpace()
        if let problem = parser.problem { throw problem }
        guard parser.index == bytes.count else { throw Problem.invalid }
        root = value
    }

    public var text: String { String(decoding: bytes, as: UTF8.self) }

    // MARK: Style

    /// One level of indentation as the file writes it; nil when the root object is on one line (a compact file).
    public var indentUnit: String? {
        guard root.kind == .object || root.kind == .array else { return nil }
        let first = root.kind == .object ? root.members.first.map(\.keyStart) : root.elements.first?.start
        guard let first else {
            // An empty root: pretty when it spans lines or is a new file's `{}`.
            return "  "
        }
        let gap = bytes[(root.start + 1)..<first]
        guard gap.contains(UInt8(ascii: "\n")) else { return nil }
        let own = lineIndent(at: root.start)
        let inner = lineIndent(at: first)
        guard inner.count > own.count, inner.hasPrefix(own) else { return "  " }
        return String(inner.dropFirst(own.count))
    }

    /// The spaces and tabs a line starts with, for the line that holds `offset`.
    func lineIndent(at offset: Int) -> String {
        var lineStart = offset
        while lineStart > 0, bytes[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
        var end = lineStart
        while end < bytes.count, bytes[end] == UInt8(ascii: " ") || bytes[end] == UInt8(ascii: "\t") { end += 1 }
        return String(decoding: bytes[lineStart..<end], as: UTF8.self)
    }

    // MARK: Edits (each returns the whole new text; the caller reads it again before the next edit)

    /// Adds `value` as the last element of `array`, in the file's own layout.
    public func appending(_ value: JSONFragment, to array: Node) -> Data {
        precondition(array.kind == .array)
        return inserting(at: array, items: array.elements.map { ($0.start, $0.end) }) { indent, base in
            value.render(indent: indent, base: base)
        }
    }

    /// Adds `"key": value` as the last member of `object`, in the file's own layout.
    public func adding(key: String, value: JSONFragment, to object: Node) -> Data {
        precondition(object.kind == .object)
        return inserting(at: object, items: object.members.map { ($0.keyStart, $0.value.end) }) { indent, base in
            JSONFragment.quoted(key) + (indent == nil ? ":" : ": ") + value.render(indent: indent, base: base)
        }
    }

    /// Takes out element `index` of `array` with exactly the separator `appending` put before it, so adding and then
    /// removing the last element gives the same bytes back.
    public func removing(element index: Int, of array: Node) -> Data {
        removing(index, in: array, items: array.elements.map { ($0.start, $0.end) })
    }

    public func removing(member index: Int, of object: Node) -> Data {
        removing(index, in: object, items: object.members.map { ($0.keyStart, $0.value.end) })
    }

    private func inserting(at container: Node, items: [(start: Int, end: Int)], _ text: (String?, String) -> String) -> Data {
        let unit = indentUnit
        var out = bytes
        if let last = items.last {
            let before = items.count > 1 ? items[items.count - 2].end : container.start + 1
            // The whitespace that led to the last item, after its comma: the new item gets the same.
            var gapStart = before
            if items.count > 1 {
                while gapStart < last.start, bytes[gapStart] != UInt8(ascii: ",") { gapStart += 1 }
                gapStart += 1
            }
            let gap = String(decoding: bytes[gapStart..<last.start], as: UTF8.self)
            let pretty = gap.contains("\n")
            let rendered = text(pretty ? (unit ?? "  ") : nil, pretty ? lineIndent(at: last.start) : "")
            out.insert(contentsOf: Array(("," + gap + rendered).utf8), at: last.end)
        } else {
            let open = container.start + 1, close = container.end - 1
            if let unit {
                let base = lineIndent(at: container.start)
                let inner = base + unit
                out.replaceSubrange(open..<close, with: Array(("\n" + inner + text(unit, inner) + "\n" + base).utf8))
            } else {
                out.replaceSubrange(open..<close, with: Array(text(nil, "").utf8))
            }
        }
        return Data(out)
    }

    private func removing(_ index: Int, in container: Node, items: [(start: Int, end: Int)]) -> Data {
        var out = bytes
        if items.count == 1 {
            out.replaceSubrange((container.start + 1)..<(container.end - 1), with: [])
        } else if index == items.count - 1 {
            out.removeSubrange(items[index - 1].end..<items[index].end)
        } else {
            out.removeSubrange(items[index].start..<items[index + 1].start)
        }
        return Data(out)
    }

    // MARK: Parser

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        var problem: Problem?

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                case UInt8(ascii: "/"):
                    if index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "/") || bytes[index + 1] == UInt8(ascii: "*") {
                        problem = .comments
                    } else {
                        problem = problem ?? .invalid
                    }
                    return
                default: return
                }
            }
        }

        mutating func fail(_ found: Problem = .invalid) -> Node? {
            problem = problem ?? found
            return nil
        }

        mutating func value() -> Node? {
            guard problem == nil, index < bytes.count else { return fail() }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object()
            case UInt8(ascii: "["): return array()
            case UInt8(ascii: "\""):
                let node = Node(kind: .string, start: index)
                guard let text = string() else { return nil }
                node.text = text
                node.end = index
                return node
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return scalar(.number)
            case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"): return scalar(.literal)
            default: return fail()
            }
        }

        mutating func scalar(_ kind: Node.Kind) -> Node? {
            let node = Node(kind: kind, start: index)
            let allowed: Set<UInt8> = kind == .number ? Set(Array("-+.eE0123456789".utf8)) : Set(Array("truefalsn".utf8))
            while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
            let raw = String(decoding: bytes[node.start..<index], as: UTF8.self)
            if kind == .literal, !["true", "false", "null"].contains(raw) { return fail() }
            if kind == .number, Double(raw) == nil { return fail() }
            node.raw = raw
            node.end = index
            return node
        }

        mutating func object() -> Node? {
            let node = Node(kind: .object, start: index)
            index += 1
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                node.end = index
                return node
            }
            while true {
                skipSpace()
                guard problem == nil, index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return fail() }
                let keyStart = index
                guard let key = string() else { return nil }
                skipSpace()
                guard problem == nil, index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return fail() }
                index += 1
                skipSpace()
                guard let member = value() else { return nil }
                node.members.append((key, keyStart, member))
                skipSpace()
                guard problem == nil, index < bytes.count else { return fail() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "}") else { return fail() }
                index += 1
                node.end = index
                return node
            }
        }

        mutating func array() -> Node? {
            let node = Node(kind: .array, start: index)
            index += 1
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                node.end = index
                return node
            }
            while true {
                skipSpace()
                guard let element = value() else { return nil }
                node.elements.append(element)
                skipSpace()
                guard problem == nil, index < bytes.count else { return fail() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "]") else { return fail() }
                index += 1
                node.end = index
                return node
            }
        }

        /// A string from its opening quote; `index` ends after the closing one.
        mutating func string() -> String? {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run = index
            func flush(_ upTo: Int) {
                scalars.append(contentsOf: String(decoding: bytes[run..<upTo], as: UTF8.self).unicodeScalars)
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flush(index)
                    index += 1
                    return String(scalars)
                }
                if byte < 0x20 { _ = fail(); return nil }
                if byte == UInt8(ascii: "\\") {
                    flush(index)
                    guard index + 1 < bytes.count else { _ = fail(); return nil }
                    let next = bytes[index + 1]
                    index += 2
                    switch next {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        guard let unit = hex4() else { _ = fail(); return nil }
                        if (0xD800...0xDBFF).contains(unit), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                           bytes[index + 1] == UInt8(ascii: "u") {
                            index += 2
                            guard let low = hex4(), (0xDC00...0xDFFF).contains(low),
                                  let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) else {
                                _ = fail(); return nil
                            }
                            scalars.append(scalar)
                        } else if let scalar = Unicode.Scalar(unit) {
                            scalars.append(scalar)
                        } else {
                            scalars.append("\u{FFFD}")
                        }
                    default:
                        _ = fail()
                        return nil
                    }
                    run = index
                    continue
                }
                index += 1
            }
            _ = fail()
            return nil
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[index..<(index + 4)], as: UTF8.self), radix: 16)
            else { return nil }
            index += 4
            return value
        }
    }
}
