import Foundation
import IslandHookNotes

/// The plugin files Juice writes whole into an agent's own plugin folder (`AgentHookSpec.Layout.plugin`): Kilo's copy of
/// the OpenCode plugin, Pi's and Oh My Pi's extension, Amp's plugin (P923, P1150 to P1164). Each kind's source, its
/// revision, and what a file there is, read from its first line only.
public enum AgentPlugins {
    /// The file Connect writes for `kind`, dialing `socketPath`.
    public static func source(_ kind: AgentKind, socketPath: String) -> String {
        switch kind {
        case .pi, .ohmypi: PiExtension.source(socketPath: socketPath, kind: kind)
        case .amp: AmpPlugin.source(socketPath: socketPath)
        default: OpenCodePlugin.source(socketPath: socketPath, kind: kind)
        }
    }

    /// This build's revision of `kind`'s file: one of Juice's older than it reads as Update.
    public static func revision(_ kind: AgentKind) -> Int {
        switch kind {
        case .pi, .ohmypi: PiExtension.revision
        case .amp: AmpPlugin.revision
        default: OpenCodePlugin.revision
        }
    }

    /// What a file at `kind`'s plugin path is: Juice's at some revision, or anyone else's (never replaced or removed).
    public static func read(_ data: Data, kind: AgentKind) -> OpenCodePluginFile {
        let marker: String
        switch kind {
        case .pi, .ohmypi: marker = PiExtension.marker
        case .amp: marker = AmpPlugin.marker
        default: return OpenCodePluginFile.of(contents: data)
        }
        let head = String(decoding: data.prefix(256), as: UTF8.self)
        let firstLine = head.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard firstLine.hasPrefix(marker) else { return .foreign }
        let digits = firstLine.dropFirst(marker.count).prefix { $0.isNumber }
        return Int(digits).map { .ours(revision: $0) } ?? .foreign
    }

    /// `text` as a JavaScript string literal (JSON's quoting, slashes kept plain), as the OpenCode plugin bakes its socket.
    static func jsString(_ text: String) -> String {
        (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self).dropFirst().dropLast() }.map(String.init) ?? "\"\""
    }
}
