import Foundation
import IslandEngine
import JuiceCore
import Observation
import SwiftUI

/// Setup's OpenCode row (P480): the plugin file's state against the installed OpenCode, in a word or two, and the one
/// button a click may use (Install, Update or Remove), or why there is none.
struct OpenCodeSetupRow: Equatable, Sendable {
    /// "OpenCode 2.0.18"; "OpenCode" before the version was asked or when it could not be.
    var title: String
    /// `~/.config/opencode`.
    var folder: String
    var word: String
    var tone: HookSetupRow.Tone
    var action: OpenCodePluginAction?
    var refusal: String?
    var busy: Bool

    var buttonTitle: String? {
        action.map {
            switch $0 {
            case .install: "Install"
            case .update: "Update"
            case .remove: "Remove"
            }
        }
    }

    var canClick: Bool { action != nil && refusal == nil && !busy }

    static func make(file: OpenCodePluginFile, version: OpenCodeVersion?, clickRefusal: String?, busy: Bool,
                     folder: String) -> OpenCodeSetupRow {
        let choice = OpenCodePluginChoice.of(file, version: version)
        return OpenCodeSetupRow(title: version.map { "OpenCode \($0.text)" } ?? "OpenCode", folder: folder, word: choice.word,
                                tone: choice.amber ? .amber : .normal, action: choice.action,
                                refusal: clickRefusal ?? choice.refusal, busy: busy)
    }

    /// `~/…` for a folder under `home`.
    static func shown(_ folder: URL, home: String) -> String {
        let path = folder.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The live row's facts (`ProfileHooks.openCode`). The plugin file is read at launch and each time Setup appears;
/// `opencode --version` runs only while Setup shows, at most once a minute (P487). Nothing is written except on the
/// owner's click (`perform`).
@MainActor
@Observable
final class OpenCodePluginModel {
    private(set) var file: OpenCodePluginFile?
    private(set) var version: OpenCodeVersion?
    /// `opencode` is on this Mac's PATH, its config folder exists or a plugin file is there.
    private(set) var isOnMac = false
    private(set) var busy = false
    private(set) var clickRefusal: String?

    @ObservationIgnored let installer: OpenCodePluginInstaller
    @ObservationIgnored private let locate: @Sendable () -> Bool
    @ObservationIgnored private let probe: @Sendable () async -> OpenCodeVersion?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var lastProbe: Date?
    @ObservationIgnored private var probing = false
    static let probeGap: TimeInterval = 60

    init(installer: OpenCodePluginInstaller = OpenCodePluginInstaller(),
         locate: @escaping @Sendable () -> Bool = { ToolLocator.locate("opencode") != nil },
         probe: @escaping @Sendable () async -> OpenCodeVersion? = { await OpenCodeVersionProbe.run() },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.installer = installer
        self.locate = locate
        self.probe = probe
        self.now = now
    }

    /// A model that finds no OpenCode: a folder that does not exist, no `opencode` and no version (tests, renders).
    static var inert: OpenCodePluginModel {
        OpenCodePluginModel(installer: OpenCodePluginInstaller(configDirectory: URL(fileURLWithPath: "/nonexistent/opencode")),
                            locate: { false }, probe: { nil })
    }

    /// Reads the file (and whether OpenCode is here) off the main actor; with `askVersion`, also asks the version,
    /// unless it was asked less than a minute ago.
    func refresh(askVersion: Bool) async {
        let installer = installer
        let locate = locate
        let (file, found) = await Task.detached(priority: .utility) {
            (installer.readFile(), installer.configFolderExists || locate())
        }.value
        self.file = file
        isOnMac = found || file != .missing
        // Setup shown again: a refused click may be tried again.
        if askVersion { clickRefusal = nil }
        guard askVersion, isOnMac, !probing else { return }
        if let lastProbe, now().timeIntervalSince(lastProbe) < Self.probeGap, lastProbe <= now() { return }
        probing = true
        lastProbe = now()
        let probe = probe
        let asked = await Task.detached(priority: .utility) { await probe() }.value
        probing = false
        version = asked
    }

    func row(home: String = NSHomeDirectory()) -> OpenCodeSetupRow? {
        guard isOnMac, let file else { return nil }
        return OpenCodeSetupRow.make(file: file, version: version, clickRefusal: clickRefusal, busy: busy,
                                     folder: OpenCodeSetupRow.shown(installer.configDirectory, home: home))
    }

    /// The row's button, on the owner's click only. A refusal or a failed write is kept for the row until Setup is
    /// shown again.
    /// `only`: Remove from all agents' Remove, which takes out Juice's own plugin whatever its revision and nothing else.
    /// Juice's plugin has a file of its own, so Open Island running stands in the way of nothing (P934).
    func perform(only: OpenCodePluginAction? = nil) async {
        guard !busy, let file else { return }
        let action: OpenCodePluginAction
        if let only {
            guard only == .remove, case .ours = file else { return }
            action = .remove
        } else {
            guard let chosen = OpenCodePluginChoice.of(file, version: version).action else { return }
            action = chosen
        }
        busy = true
        clickRefusal = nil
        let installer = installer
        let outcome: String? = await Task.detached(priority: .userInitiated) {
            do {
                switch action {
                case .install, .update: try installer.install()
                case .remove: try installer.remove()
                }
                return nil
            } catch let error as OpenCodePluginError {
                return error.refusal
            } catch {
                return OpenCodePluginError.writeFailed("").refusal
            }
        }.value
        busy = false
        await refresh(askVersion: false)
        clickRefusal = outcome
    }
}

/// One OpenCode row on its own (the providers' renders); Settings › Agents draws it as an agent's row (`AgentRowView`).
struct OpenCodeSetupRowView: View {
    let row: OpenCodeSetupRow
    @Environment(AppEnvironment.self) private var env

    /// OpenCode reads its plugins when it starts (OpenCode 2 when its background service starts).
    static func help(_ action: OpenCodePluginAction?) -> String {
        switch action {
        case .install: "Put \(Product.name)'s plugin in OpenCode's plugins folder; OpenCode loads it when it next starts"
        case .update: "Replace the plugin with this build's; OpenCode loads it when it next starts"
        case .remove: "Take the plugin out of OpenCode's plugins folder"
        case nil: ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            AgentMarkView(agent: .other(.openCode), size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(Fonts.sys(13, .medium)).foregroundStyle(SettingsTheme.ink).lineLimit(1)
                MonoText(row.folder)
            }
            .frame(width: 150, alignment: .leading)
            Text(row.word).font(Fonts.sys(12.5))
                .foregroundStyle(row.tone == .amber ? SettingsTheme.statusAmber : SettingsTheme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let refusal = row.refusal, !row.busy {
                if refusal != row.word {
                    Text(refusal).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink3).lineLimit(2)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 170, alignment: .trailing)
                }
            } else if let title = row.buttonTitle {
                PushButton(title: row.busy ? "…" : title, blue: row.action != .remove, quiet: row.action == .remove, small: true) {
                    env.hooks.performOpenCode()
                }
                .disabled(!row.canClick)
                .help(Self.help(row.action))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 46)
    }
}
