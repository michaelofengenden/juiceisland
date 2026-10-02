import Foundation
import Security

/// Where the app and its widget meet (spec §4.7): the App Group both are entitled to and the URL scheme the app handles,
/// each read from the bundle's own Info.plist (`JIAppGroup`, `JIURLScheme`, filled from `project.yml`). The group is
/// team-prefixed (`TEAMID0000.<the app's bundle id>`), so it needs no provisioning profile; the scheme is the app's bundle
/// id. Both follow the build's identity, so the release build (`com.ofengenden.juice`) and a dev build
/// (`com.ofengenden.juice.dev`) never read each other's snapshot or answer each other's links, and neither answers
/// standalone Juice's `juice://` (P345). nil in `swift test` and renders, whose bundle has neither key.
struct WidgetIdentity: Equatable, Sendable {
    var appGroup: String
    var scheme: String

    init(appGroup: String, scheme: String) {
        self.appGroup = appGroup
        self.scheme = scheme
    }

    init?(info: [String: Any]?) {
        guard let group = info?["JIAppGroup"] as? String, let scheme = info?["JIURLScheme"] as? String,
              !group.isEmpty, !scheme.isEmpty, !group.contains("$("), !scheme.contains("$(") else { return nil }
        self.init(appGroup: group, scheme: scheme.lowercased())
    }

    static var main: WidgetIdentity? { WidgetIdentity(info: Bundle.main.infoDictionary) }

    /// The team the group is named for: its first part.
    var team: String { String(appGroup.prefix { $0 != "." }) }

    /// Whether a process signed by `team` may use the group with no prompt. macOS 15 and later asks the owner before
    /// an app reads or writes a group container its signature does not vouch for ("would like to access data from other
    /// apps"), and an ad hoc signature (every dev build) names no team: only a build signed by the group's own team
    /// writes, so no prompt ever shows (P342).
    func allows(signingTeam team: String?) -> Bool { team != nil && team == self.team }
}

/// The team identifier of this process's code signature; nil when ad hoc or unsigned.
enum SigningTeam {
    static func current() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// The snapshot file (`island-widget.json`) in a folder: the App Group container, or a temporary folder in tests.
/// The app writes it atomically (a new file renamed over the old), so the widget never reads half of one; the widget
/// only reads it.
struct WidgetStore: Sendable {
    static let fileName = "island-widget.json"
    let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// The group's container. `containerURL` never returns nil on macOS, whether or not the process may use the group,
    /// so the caller decides that first (`WidgetIdentity.allows`).
    static func appGroup(_ group: String) -> WidgetStore? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group).map { WidgetStore(directory: $0) }
    }

    /// The last snapshot; nil when there is none, it cannot be read, or another version wrote it.
    func read() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: file),
              let snapshot = try? Self.decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    func write(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(snapshot).write(to: file, options: [.atomic])
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// A widget's tap, as a URL in the app's scheme: `<scheme>://session/<id>` for a row, `<scheme>://open` for the rest
/// of the widget. The app does what a click on that row does in the island or the window (the card of one that needs
/// you, else the jump), never more: a link answers nothing, so any app that opens one can at most show a card (P341).
enum WidgetLink: Equatable, Sendable {
    case open
    case session(String)

    /// Session ids are the engine's (UUIDs, Codex thread ids, other agents' own); anything longer is not one.
    static let idLimit = 256
    private static let idCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    func url(scheme: String) -> URL? {
        switch self {
        case .open:
            return URL(string: "\(scheme)://open")
        case let .session(id):
            guard !id.isEmpty, id.count <= Self.idLimit,
                  let encoded = id.addingPercentEncoding(withAllowedCharacters: Self.idCharacters) else { return nil }
            return URL(string: "\(scheme)://session/\(encoded)")
        }
    }

    init?(url: URL, scheme: String) {
        guard url.scheme?.lowercased() == scheme.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.percentEncodedPath
        switch components.host?.lowercased() {
        case "open" where path.isEmpty || path == "/":
            self = .open
        case "session":
            let encoded = String(path.dropFirst())
            guard path.hasPrefix("/"), !encoded.contains("/"), let id = encoded.removingPercentEncoding,
                  !id.isEmpty, id.count <= Self.idLimit else { return nil }
            self = .session(id)
        default:
            return nil
        }
    }
}
