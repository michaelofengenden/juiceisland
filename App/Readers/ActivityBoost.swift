import Foundation
import JuiceCore
import Observation

/// #12: the release build's readers read an account whose sessions are at work at its boosted floor, never sooner
/// (`LiveUsageModel.sessionsAtWork`). It follows the sessions' rows and names the accounts of the running ones, from
/// the engine's account tags (the transcript path only, spec §3.6); nothing else is read, and without live sessions or
/// the release build's readers it does nothing. It follows the minute clock too: through a long build or test run a
/// session at work sends no hook event and its row stays as it is, while a boost lasts `boostDuration` (10 min); each
/// minute renews it as long as the session runs (P125).
@MainActor
final class ActivityBoost {
    private let sessions: () -> (any SessionsModel)?
    private let atWork: ([String]) -> Void

    convenience init(env: AppEnvironment) {
        self.init(sessions: { [weak env] in env?.sessions }, atWork: { [weak env] running in
            guard let env, let usage = env.liveUsage, let engine = env.liveSessions?.engine else { return }
            usage.sessionsAtWork(inFolders: Self.folders(running) { engine.accountTag(for: $0)?.accountID })
        })
    }

    /// `sessions`: the sessions model as it is now (the environment's changes with Live sessions); `atWork` gets the
    /// running sessions' ids each time the rows or the minute change.
    init(sessions: @escaping () -> (any SessionsModel)?, atWork: @escaping ([String]) -> Void) {
        self.sessions = sessions
        self.atWork = atWork
        observe()
    }

    private func observe() {
        withObservationTracking {
            guard let model = sessions() else { return }
            _ = model.rows
            _ = model.now
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let model = self.sessions() { self.atWork(model.running.map(\.id)) }
                self.observe()
            }
        }
    }

    /// The accounts of these sessions, those the engine tagged.
    static func folders(_ sessions: [String], tag: (String) -> String?) -> Set<String> {
        Set(sessions.compactMap(tag))
    }
}
