import Foundation

/// How long the build should take, as update-app.sh says in the run's log before it writes `building` (P801): the last
/// update build of the same kind (incremental, or clean when the flavor's DerivedData was not there) in the updater's
/// checkout for this app's flavor, `estimate: the last incremental build here took 143 s`. None on a first build, after a
/// build of another kind, or in a prepare.
struct BuildEstimate: Equatable, Sendable {
    var seconds: Int

    /// The first estimate in a run's log, a line of its own as the script's `say` writes it
    /// (`HH:MM:SS estimate: the last <clean|incremental> build here took <seconds> s`); nil when it has none. A commit
    /// subject that says the same words is never one: it follows "updating … to …:" on its line.
    static func parse(_ log: String) -> BuildEstimate? {
        for line in log.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
            guard words.count == 10, isTime(words[0]), words[1 ... 3] == ["estimate:", "the", "last"],
                  ["clean", "incremental"].contains(words[4]), words[5 ... 7] == ["build", "here", "took"], words[9] == "s",
                  words[8].allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Int(words[8]), seconds > 0 else { continue }
            return BuildEstimate(seconds: seconds)
        }
        return nil
    }

    /// "12:00:02".
    private static func isTime(_ word: Substring) -> Bool {
        word.count == 8 && word.enumerated().allSatisfy { index, character in
            index == 2 || index == 5 ? character == ":" : character.isASCII && character.isNumber
        }
    }

    /// The estimate in the log at `url`, read off the main actor: only its first 64 KB, where the line comes long before
    /// the build's own output.
    static func read(logAt url: URL) -> BuildEstimate? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }
}

/// How far an update has come (P800 to P802), for the Update control's fill and words. Every stage boundary is the
/// script's own (the status file's states); inside the build, which has no step count to read (xcodebuild prints none,
/// and a Release build is minutes of whole-module compiles with nothing printed), the time it has run is set against
/// the last such build's, and only while that holds: past it the percent goes and the fill waits at the build's end.
struct UpdateProgress: Equatable, Sendable {
    /// The whole run, 0 to 1: the control's fill.
    var fraction: Double
    /// The build's own percent ("Building 63%"), while an estimate holds it; nil otherwise.
    var buildPercent: Int?
    /// What the estimate leaves of the build, in seconds; nil without one or past it.
    var secondsLeft: Int?
    /// The build has run longer than the last such build: no percent, and the fill holds.
    var overran = false
    /// The run's own words, when its updater says them (the public flavor's feed: "Downloading 45%", "Extracting",
    /// P825); nil for update-app.sh's runs, whose words follow the phase.
    var words: String?

    static let none = UpdateProgress(fraction: 0)

    /// The run's share of the fill each stage takes: an update fetches, builds, then checks the new build before the
    /// swap. Restart to update (an install) checks the prepared app, so that check takes most of the way; when the
    /// prepared app is gone or fails its check, the script fetches and builds after all, and the run goes on as an
    /// update's, from where its fill is (the fill never goes back).
    static let fetchEnd = 0.04
    static let buildEnd = 0.92
    /// A sliver while fetching, so the click shows at once; Restart to update's too, until the script says what it does.
    static let fetching = 0.02
    /// Checking the new build (update, or an install that built), and checking the prepared one (install).
    static let checking = 0.95
    static let installing = 0.6

    /// The progress for `phase`. `install` is a Restart to update run, `begun` once the script has written a state,
    /// `buildStarted` when this app saw `building`, and `buildFrom` the fill the build started from (a build after the
    /// prepared app's check sweeps on from that check's share).
    static func of(phase: UpdatePhase, install: Bool, begun: Bool = true, buildStarted: Date?, buildFrom: Double = fetchEnd,
                   estimate: BuildEstimate?, now: Date) -> UpdateProgress {
        switch phase {
        case .idle, .failed, .updated: return .none
        case .pulling: return UpdateProgress(fraction: fetching)
        case .building: return building(started: buildStarted, from: buildFrom, estimate: estimate, now: now)
        case .installing:
            guard install, buildStarted == nil else { return UpdateProgress(fraction: checking) }
            return UpdateProgress(fraction: begun ? installing : fetching)
        case .restarting, .restartNeeded: return UpdateProgress(fraction: 1)
        }
    }

    private static func building(started: Date?, from: Double, estimate: BuildEstimate?, now: Date) -> UpdateProgress {
        let from = min(max(from, fetchEnd), buildEnd)
        guard let started, let estimate else { return UpdateProgress(fraction: from) }
        let elapsed = max(0, now.timeIntervalSince(started)), total = Double(estimate.seconds)
        let share = elapsed / total
        guard share < 1 else { return UpdateProgress(fraction: buildEnd, overran: true) }
        return UpdateProgress(fraction: from + (buildEnd - from) * share, buildPercent: Int(share * 100),
                              secondsLeft: Int((total - elapsed).rounded(.up)))
    }
}
