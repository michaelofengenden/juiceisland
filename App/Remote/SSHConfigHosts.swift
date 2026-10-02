import Darwin
import Foundation
import IslandEngine

/// The `Host` names in the owner's ssh config, for Setup's pop-up (P751): read when Setup shows, from `~/.ssh/config`
/// and the files its `Include` lines name under `~/.ssh` (one level), and never written, kept or sent anywhere. Only
/// plain names: a pattern (`*`, `?`) or a negation (`!`) is no host to add.
enum SSHConfigHosts {
    static let fileLimit = 16

    static func names(in text: String) -> [String] {
        var names: [String] = []
        for (keyword, values) in lines(text) where keyword == "host" {
            for value in values where !value.contains("*") && !value.contains("?") && !value.hasPrefix("!")
                && RemoteDestination.isValid(value) && !names.contains(value) {
                names.append(value)
            }
        }
        return names
    }

    /// The config's lines as a keyword (lowercased) and its values, comments dropped; `Key=value` and quoted values too.
    static func lines(_ text: String) -> [(String, [String])] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if let hash = line.range(of: " #") { line = String(line[..<hash.lowerBound]) }
            let split = line.firstIndex { $0 == " " || $0 == "\t" || $0 == "=" } ?? line.endIndex
            let keyword = line[..<split].lowercased()
            var rest = line[split...].drop { $0 == " " || $0 == "\t" || $0 == "=" }
            var values: [String] = []
            while !rest.isEmpty {
                if rest.first == "\"", let close = rest.dropFirst().firstIndex(of: "\"") {
                    values.append(String(rest[rest.index(after: rest.startIndex)..<close]))
                    rest = rest[rest.index(after: close)...]
                } else {
                    let end = rest.firstIndex { $0 == " " || $0 == "\t" } ?? rest.endIndex
                    values.append(String(rest[..<end]))
                    rest = rest[end...]
                }
                rest = rest.drop { $0 == " " || $0 == "\t" }
            }
            return (keyword, values)
        }
    }

    /// Every name in the config and the files it includes, in order.
    static func read(home: URL) -> [String] {
        let folder = home.appendingPathComponent(".ssh", isDirectory: true)
        guard let main = try? String(contentsOf: folder.appendingPathComponent("config"), encoding: .utf8) else { return [] }
        var texts = [main]
        for (keyword, values) in lines(main) where keyword == "include" {
            for pattern in values {
                for path in expand(pattern, folder: folder, home: home) where texts.count < fileLimit {
                    if let text = try? String(contentsOfFile: path, encoding: .utf8) { texts.append(text) }
                }
            }
        }
        var names: [String] = []
        for text in texts {
            for name in Self.names(in: text) where !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// An `Include` pattern's files: relative to `~/.ssh`, `~` the home; only files under `~/.ssh`.
    static func expand(_ pattern: String, folder: URL, home: URL) -> [String] {
        var path = pattern
        if path.hasPrefix("~/") { path = home.path + path.dropFirst(1) } else if !path.hasPrefix("/") { path = folder.path + "/" + path }
        var found = glob_t()
        defer { globfree(&found) }
        guard glob(path, 0, nil, &found) == 0 else { return [] }
        let paths = (0..<Int(found.gl_matchc)).compactMap { found.gl_pathv[$0].map { String(cString: $0) } }
        return paths.filter { URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") }
    }
}
