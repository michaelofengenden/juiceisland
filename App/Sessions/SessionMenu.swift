import AppKit
import IslandEngine
import JuiceCore
import SwiftUI

/// What a session's right-click menu offers (a row or a card's header, in the island and the window): the jump, its
/// title and folder, Archive on a finished row (P131), and Stop only where the island can stop the agent safely: a
/// Claude approval or plan the island holds, which it answers No and stop (⌃⇧D, the request the menu was built for,
/// P170). A running session has no safe stop (the engine never signals an agent's process), so it has none (P320).
/// A session stopped on its usage limit offers its card's other account under the jump ("Open in lab", P707), so the
/// row keeps it when the card folded away, never opened or was dismissed.
enum SessionMenuItem: Equatable, Sendable {
    case jump, copyTitle, copyFolder, openFolder, archive, stop
    case openIn(LimitAlternative)

    var title: String {
        switch self {
        case .jump: "Jump to session"
        case let .openIn(alternative): alternative.action
        case .copyTitle: "Copy title"
        case .copyFolder: "Copy folder path"
        case .openFolder: "Open in Finder"
        case .archive: "Archive"
        case .stop: "Stop"
        }
    }
}

enum SessionMenuModel {
    /// The menu's groups, a divider between each; a group with nothing in it is left out, so a row with no folder and
    /// nothing to archive or stop has two. `alternative`: the other account the row's limit offers (`alternative(_:logins:)`).
    static func groups(_ row: SessionRow, card: SessionCard?, alternative: LimitAlternative? = nil) -> [[SessionMenuItem]] {
        let folder: [SessionMenuItem] = row.folder == nil ? [] : [.copyFolder, .openFolder]
        var last: [SessionMenuItem] = []
        if row.canArchive { last.append(.archive) }
        if stop(card) != nil { last.append(.stop) }
        return [[.jump] + (alternative.map { [.openIn($0)] } ?? []), [.copyTitle] + folder, last].filter { !$0.isEmpty }
    }

    /// The best other account for a row stopped on its usage limit while it holds, as its card offers it (P704, P707).
    static func alternative(_ row: SessionRow, logins: [ProviderLogins]) -> LimitAlternative? {
        row.limit.flatMap { LimitAlternative.best(for: $0, logins: logins) }
    }

    /// The request Stop answers No and stop: a Claude approval or plan the island holds and can stop (`canStop`), not
    /// while its answer is on its way. nil: no Stop.
    static func stop(_ card: SessionCard?) -> StopTarget? {
        switch card {
        case let .approval(model) where model.isAnswerable && model.canStop && model.send != .sending:
            StopTarget(sessionID: model.sessionID, request: model.request?.id)
        case let .plan(model) where model.isAnswerable && model.canStop && model.send != .sending:
            StopTarget(sessionID: model.sessionID, request: model.request?.id)
        default:
            nil
        }
    }

    struct StopTarget: Equatable, Sendable {
        var sessionID: String
        /// The engine request the card showed: once it is gone, the Stop answers nothing (P170).
        var request: String?
    }
}

/// Carries out a menu item. The pasteboard and the Finder are injected, so tests never touch the owner's clipboard or
/// open a Finder window.
@MainActor
struct SessionMenuPerformer {
    var sessions: any SessionsModel
    /// The surface's own jump: the island folds and hands back its keys first (a row click's jump), the window jumps.
    var jump: @MainActor (String) -> Void
    var pasteboard: NSPasteboard = .general
    /// A new Finder window rooted at the folder (never `open`, which would launch a folder that is a bundle).
    var openFolder: @MainActor (String) -> Void = { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: $0) }

    func perform(_ item: SessionMenuItem, row: SessionRow, card: SessionCard?) {
        switch item {
        case .jump:
            jump(row.id)
        case .copyTitle:
            copy(row.task)
        case .copyFolder:
            if let folder = row.folder { copy(folder) }
        case .openFolder:
            if let folder = row.folder { openFolder(folder) }
        case .archive:
            // The model archives only a finished session (P131).
            if row.canArchive { sessions.dismiss(row.id) }
        case .stop:
            guard let target = SessionMenuModel.stop(card) else { return }
            sessions.approve(target.sessionID, .denyAndStop, request: target.request)
        case let .openIn(alternative):
            sessions.openFresh(row.id, in: alternative)
        }
    }

    private func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// The menu's items for `row`, built when the menu opens, with the card it had then.
struct SessionMenu: View {
    let row: SessionRow
    @Environment(AppEnvironment.self) private var env
    @Environment(\.sessionJump) private var surfaceJump

    var body: some View {
        let card = env.sessions.card(for: row.id)
        let performer = SessionMenuPerformer(sessions: env.sessions, jump: surfaceJump ?? { [sessions = env.sessions] in sessions.jump($0) })
        let groups = SessionMenuModel.groups(row, card: card,
                                             alternative: SessionMenuModel.alternative(row, logins: env.usage.logins))
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index], id: \.title) { item in
                Button(item.title) { performer.perform(item, row: row, card: card) }
            }
        }
    }
}

extension View {
    /// The session's right-click menu.
    func sessionMenu(_ row: SessionRow) -> some View {
        contextMenu { SessionMenu(row: row) }
    }
}

private struct SessionJumpKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    /// The surface's jump for a session's menu (the island's folds it and hands back its keys); nil: the model's.
    var sessionJump: (@MainActor (String) -> Void)? {
        get { self[SessionJumpKey.self] }
        set { self[SessionJumpKey.self] = newValue }
    }
}
