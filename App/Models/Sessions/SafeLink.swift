import AppKit
import Foundation

/// The links a Done card opens (P431): an agent's `http` or `https` address, nothing else, and only in the default
/// browser. An agent writes whatever it likes, so a target is taken only when it is a plain web address: no other
/// scheme (`file:`, `javascript:`, an app's own), no user or password before the host (`https://bank.example@evil.test`
/// reads as the first and goes to the second), a host, no whitespace or control character, at most `maxLength`
/// characters. A link's text that names another address shows the target instead (`misleads`), and a click opens the
/// target with the browser that opens `https` pages, never an app that claims the address. Nothing is fetched or read
/// before the click, and a click is the only way one opens.
enum SafeLink {
    static let maxLength = 2_048

    /// `raw` as a link, or nil when it is anything but a plain `http` or `https` address.
    static func url(_ raw: String) -> URL? {
        guard !raw.isEmpty, raw.count <= maxLength,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil, let host = parts.host, !host.isEmpty,
              let url = parts.url else { return nil }
        return url
    }

    /// Whether a link's text names an address other than where it goes (`[https://bank.example](https://evil.test)`,
    /// `[docs.example.com](https://evil.test)`): text that reads as a web address on another host.
    static func misleads(label: String, target: URL) -> Bool {
        guard let named = namedHost(label.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "`*_<>"))),
              let host = target.host() else { return false }
        return bare(named) != bare(host)
    }

    /// The host a text names when it reads as a web address (`https://a.example/x`, `a.example`, `www.a.example/x`); nil
    /// for prose ("the outline", "README.md" is a file, not a host: a host needs a dot and a known-looking last label).
    static func namedHost(_ text: String) -> String? {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.contains("://") { return URLComponents(string: text)?.host.flatMap { $0.isEmpty ? nil : $0 } }
        let host = String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" })
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let last = labels.last, last.count >= 2, last.allSatisfy(\.isLetter), !fileExtensions.contains(last.lowercased())
        else { return nil }
        return host
    }

    /// Endings that make a dotted word a file's name rather than a host's ("notes.md", "main.swift").
    private static let fileExtensions: Set<String> = [
        "md", "txt", "swift", "py", "js", "ts", "tsx", "jsx", "json", "yml", "yaml", "toml", "sh", "rb", "go", "rs", "c", "h",
        "cpp", "hpp", "m", "mm", "java", "kt", "cs", "css", "html", "htm", "xml", "pdf", "png", "jpg", "jpeg", "gif", "svg",
        "csv", "lock", "log", "plist", "zsh", "bash", "sql", "env", "cfg", "ini", "conf", "patch", "diff", "zip", "gz", "tar",
    ]

    private static func bare(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }

    /// Opens `url` in the default browser: the app that opens `https` pages, given the address explicitly, so no other
    /// app that claims its host takes it. False, and nothing opened, for anything `url(_:)` would not take, or with no
    /// browser. `open` does the opening (tests pass a recorder; nothing is opened in a test).
    @MainActor @discardableResult
    static func open(_ url: URL, browser: () -> URL? = defaultBrowser,
                     open: (URL, URL) -> Void = { url, app in
                         NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                     }) -> Bool {
        guard let safe = Self.url(url.absoluteString), let app = browser() else { return false }
        open(safe, app)
        return true
    }

    /// The app macOS opens `https` pages with.
    static func defaultBrowser() -> URL? {
        guard let page = URL(string: "https://example.com") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: page)
    }
}
