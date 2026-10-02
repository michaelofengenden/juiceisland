import Foundation
import IslandEngine
import SwiftUI

/// The one quiet line a row click leaves when its jump did not land on the session's own tab: under the row in the
/// window, under the header in the island. An exact jump leaves nothing; a demo row says "Demo session".
struct JumpNote: Equatable, Sendable {
    var id = UUID()
    var sessionID: String
    var text: String

    /// How long a note stays before it clears itself.
    static let lifetime: Duration = .seconds(6)
    static let demo = "Demo session"

    /// The note for a jump's outcome, named by its failure; nil when the exact tab came forward.
    static func text(for outcome: JumpOutcome) -> String? {
        let host = outcome.host
        let generic = "Brought \(host) forward, but not the session's own tab"
        switch outcome.result {
        case .matched:
            return nil
        case .noTarget:
            return "No terminal known for this session yet"
        case .folderOpened:
            return "No app or terminal known · opened its folder in Finder"
        case .activatedOnly:
            guard let failure = outcome.failure else { return generic }
            return reason(failure, host: host, tool: outcome.tool)
        case .fallbackActivated:
            guard let failure = outcome.failure else { return generic }
            if failure == .automationDenied { return reason(failure, host: host) }
            return "\(reason(failure, host: host, tool: outcome.tool)) · brought \(host) forward"
        case .failed:
            return outcome.failure.map { reason($0, host: host, tool: outcome.tool) } ?? "Could not jump to \(host)"
        }
    }

    static func reason(_ failure: JumpFailure, host: String, tool: String? = nil) -> String {
        switch failure {
        case .automationDenied: "Allow \(Product.name) to control \(host) in System Settings › Privacy & Security › Automation"
        case .unknownHost: "\(Product.name) can't jump into \(host) yet"
        case .timedOut: "\(host) did not answer in time"
        case .scriptFailed: "Could not find the session's tab in \(host)"
        case .openFailed: "Could not open \(host)"
        case .hostNotRunning: "\(host) isn't running"
        case .cliMissing: "\(tool ?? host) not found"
        case .detached: "Its tmux session isn't attached"
        case .ambiguous: "Several \(host) tabs match"
        case .wrongTab: "Brought \(host) forward, but not the session's own tab"
        case .threadLinkFailed: "\(host) didn't open the thread"
        case .threadUnknown: "Brought \(host) forward; the thread isn't known"
        }
    }
}

/// The island shows its note under the header, so rows and card headers inside it draw none of their own.
private struct JumpNoteInIslandHeaderKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var jumpNoteInIslandHeader: Bool {
        get { self[JumpNoteInIslandHeaderKey.self] }
        set { self[JumpNoteInIslandHeaderKey.self] = newValue }
    }
}

/// The note under one row (11/18 `ink2`, one line, the full text on hover); nothing while the row has none.
struct JumpNoteLine: View {
    let sessionID: String
    @Environment(AppEnvironment.self) private var env
    @Environment(\.jumpNoteInIslandHeader) private var inIslandHeader

    var body: some View {
        if !inIslandHeader, let note = env.sessions.jumpNote, note.sessionID == sessionID {
            JumpNoteText(note: note)
        }
    }
}

/// The island's note, under its header, for whichever row was clicked.
struct IslandJumpNote: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        if let note = env.sessions.jumpNote {
            JumpNoteText(note: note)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct JumpNoteText: View {

    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let note: JumpNote

    var body: some View {
        Text(note.text)
            .font(Fonts.sys(11))
            .foregroundStyle(palette.ink2)
            .lineLimit(1).truncationMode(.tail)
            .lineBox(18)
            .help(note.text)
            .accessibilityLabel(note.text)
    }
}
