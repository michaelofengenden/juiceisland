import Darwin
import Foundation
import IslandEngine
import JuiceCore
import OpenIslandCore

// Measures transcript discovery on this Mac's ~/.codex/sessions and ~/.claude/projects, and for `coldstart`,
// `claudeold` and `claudecompare` every profile folder, read-only (P83, P84, P85). It prints counts, sizes, times and
// memory only: nothing a rollout or transcript says, and no folder name, is printed, logged or kept. Profile folders are
// found by their names and their projects/ or sessions/ folder, so no login or settings file is ever looked at.
//
//   swift run -c release RolloutScanMeasure new        our scanner: a first pass, then a second, incremental one
//   swift run -c release RolloutScanMeasure old        upstream's CodexRolloutDiscovery, stopped after 20 s or at 1.5 GB
//   swift run -c release RolloutScanMeasure watch      our scanner, then upstream's rollout watcher on what it found
//   swift run -c release RolloutScanMeasure track      our scanner, then our rollout tracker on what it found
//   swift run -c release RolloutScanMeasure compare    how many sessions get the same first events from both
//   swift run -c release RolloutScanMeasure claude     upstream's ClaudeTranscriptDiscovery, stopped like `old`
//   swift run -c release RolloutScanMeasure coldstart  the engine's whole launch discovery (every Claude profile and
//                                                      Codex home), then the rollout tracker's start on what it found
//   swift run -c release RolloutScanMeasure claudeold  upstream's ClaudeTranscriptDiscovery over every Claude profile
//   swift run -c release RolloutScanMeasure claudenew  our ClaudeTranscriptScanner over every Claude profile
//   swift run -c release RolloutScanMeasure claudecompare  how many sessions our Claude scanner and upstream's give alike
//   swift run -c release RolloutScanMeasure rescan     the Codex app rescan on ~/.codex/sessions: a pass, a second that
//                                                      walks and starts following changes, then one 12 s later

let mode = CommandLine.arguments.dropFirst().first ?? "new"
let root = CodexRolloutDiscovery.defaultRootURL
let megabyte = 1_048_576.0

func memory() -> (resident: Double, footprint: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.resident_size) / megabyte, Double(info.phys_footprint) / megabyte)
}

func peakResident() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / megabyte
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func line(_ label: String, _ fields: [(String, String)]) {
    print(([label] + fields.map { "\($0.0)=\($0.1)" }).joined(separator: " "))
}

func mb(_ value: Double) -> String { String(format: "%.1fMB", value) }
func seconds(_ value: Double) -> String { String(format: "%.2fs", value) }

/// Rollouts modified in the last day, as both discoveries count them, and the size of the newest 40.
func candidates() -> (count: Int, newestBytes: Int, largestBytes: Int) {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return (0, 0, 0) }
    let cutoff = Date.now.addingTimeInterval(-86_400)
    var found: [(Date, Int)] = []
    for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
              let modified = values.contentModificationDate, modified >= cutoff else { continue }
        found.append((modified, values.fileSize ?? 0))
    }
    let newest = found.sorted { $0.0 > $1.0 }.prefix(40).map(\.1)
    return (found.count, newest.reduce(0, +), newest.max() ?? 0)
}

let before = memory()
let files = candidates()
line("rollouts", [("recent", "\(files.count)"), ("newest40", mb(Double(files.newestBytes) / megabyte)),
                  ("largest", mb(Double(files.largestBytes) / megabyte))])
line("baseline", [("resident", mb(before.resident)), ("footprint", mb(before.footprint))])

switch mode {
case "old", "claude":
    final class Finished: @unchecked Sendable {
        private let lock = NSLock()
        private var records: Int?
        func set(_ count: Int) { lock.withLock { records = count } }
        var value: Int? { lock.withLock { records } }
    }
    let finished = Finished()
    let started = Date()
    let cpuStart = cpuSeconds()
    let isClaude = mode == "claude"
    Thread.detachNewThread {
        finished.set(isClaude ? ClaudeTranscriptDiscovery().discoverRecentSessions().count
                              : CodexRolloutDiscovery().discoverRecentSessions().count)
    }
    var lastReport = 0.0
    while true {
        usleep(100_000)
        let elapsed = Date().timeIntervalSince(started)
        let now = memory()
        if let records = finished.value {
            line("\(mode)-finished", [("records", "\(records)"), ("wall", seconds(elapsed)), ("cpu", seconds(cpuSeconds() - cpuStart)),
                                       ("resident", mb(now.resident)), ("footprint", mb(now.footprint)), ("peak", mb(peakResident()))])
            exit(0)
        }
        if elapsed - lastReport >= 2 {
            lastReport = elapsed
            line("\(mode)-running", [("wall", seconds(elapsed)), ("resident", mb(now.resident)), ("footprint", mb(now.footprint))])
        }
        if elapsed >= 20 || now.resident >= 1_536 {
            line("\(mode)-stopped", [("wall", seconds(elapsed)), ("cpu", seconds(cpuSeconds() - cpuStart)),
                                      ("resident", mb(now.resident)), ("footprint", mb(now.footprint)), ("peak", mb(peakResident())),
                                      ("reason", elapsed >= 20 ? "20s" : "1.5GB")])
            exit(0)
        }
    }

case "new", "watch", "track":
    let scanner = CodexRolloutScanner()
    for pass in 1...2 {
        let started = Date()
        let cpuStart = cpuSeconds()
        let records = scanner.discoverRecentSessions()
        let diagnostics = scanner.lastScanDiagnostics
        let now = memory()
        line("new-pass\(pass)", [("records", "\(records.count)"), ("considered", "\(min(diagnostics.candidateCount, 40))"),
                                 ("parsed", "\(diagnostics.parsedFileCount)"), ("cacheHits", "\(diagnostics.cacheHitCount)"),
                                 ("windowed", "\(diagnostics.windowedFileCount)"), ("widened", "\(diagnostics.widenedFileCount)"),
                                 ("lookedBack", "\(diagnostics.lookedBackFileCount)"), ("unreached", "\(diagnostics.unreachedFileCount)"),
                                 ("skippedLines", "\(diagnostics.skippedLineCount)"),
                                 ("bytesRead", mb(Double(diagnostics.bytesRead) / megabyte)),
                                 ("wall", seconds(Date().timeIntervalSince(started))), ("cpu", seconds(cpuSeconds() - cpuStart)),
                                 ("resident", mb(now.resident)), ("footprint", mb(now.footprint)), ("peak", mb(peakResident()))])
        if pass == 2, mode != "new" {
            final class Counter: @unchecked Sendable {
                private let lock = NSLock()
                private var count = 0
                func add() { lock.withLock { count += 1 } }
                var value: Int { lock.withLock { count } }
            }
            let events = Counter()
            let targets = records.compactMap { record in
                record.codexMetadata?.transcriptPath.map { CodexRolloutWatchTarget(sessionID: record.sessionID, transcriptPath: $0) }
            }
            let watchStarted = Date()
            let watchCPU = cpuSeconds()
            let stop: () -> Void
            var trackerBytes: Int?
            if mode == "watch" {
                let watcher = CodexRolloutWatcher()
                watcher.eventHandler = { _ in events.add() }
                watcher.sync(targets: targets)
                stop = watcher.stop
            } else {
                let tracker = CodexRolloutTracker()
                tracker.eventHandler = { _ in events.add() }
                tracker.sync(targets: targets)
                tracker.waitUntilIdle()
                trackerBytes = tracker.bytesRead
                stop = tracker.stop
            }
            let afterWatch = memory()
            line(mode == "watch" ? "watcher-start" : "tracker-start", [("targets", "\(targets.count)"), ("events", "\(events.value)"),
                                   ("bytesRead", trackerBytes.map { mb(Double($0) / megabyte) } ?? "-"),
                                   ("wall", seconds(Date().timeIntervalSince(watchStarted))), ("cpu", seconds(cpuSeconds() - watchCPU)),
                                   ("resident", mb(afterWatch.resident)), ("footprint", mb(afterWatch.footprint)),
                                   ("peak", mb(peakResident()))])
            stop()
        }
    }

case "compare":
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String: [AgentEvent]] = [:]
        func add(_ id: String, _ event: AgentEvent) { lock.withLock { events[id, default: []].append(event) } }
        var value: [String: [AgentEvent]] { lock.withLock { events } }
    }
    enum Event {
        static func sessionID(_ event: AgentEvent) -> String {
            switch event {
            case let .sessionMetadataUpdated(update): update.sessionID
            case let .activityUpdated(update): update.sessionID
            case let .sessionCompleted(update): update.sessionID
            default: "other"
            }
        }
    }
    let records = CodexRolloutScanner().discoverRecentSessions()
    let targets = records.compactMap { record in
        record.codexMetadata?.transcriptPath.map { CodexRolloutWatchTarget(sessionID: record.sessionID, transcriptPath: $0) }
    }
    let upstream = Recorder()
    let watcher = CodexRolloutWatcher()
    watcher.eventHandler = { upstream.add(Event.sessionID($0), $0) }
    watcher.sync(targets: targets)
    watcher.stop()
    let ours = Recorder()
    let tracker = CodexRolloutTracker()
    tracker.eventHandler = { ours.add(Event.sessionID($0), $0) }
    tracker.sync(targets: targets)
    tracker.waitUntilIdle()
    tracker.stop()
    let theirs = upstream.value
    let mine = ours.value
    let same = targets.filter { theirs[$0.sessionID] == mine[$0.sessionID] }.count
    line("compare", [("sessions", "\(targets.count)"), ("identicalEvents", "\(same)"), ("differing", "\(targets.count - same)"),
                     ("upstreamEvents", "\(theirs.values.map(\.count).reduce(0, +))"), ("trackerEvents", "\(mine.values.map(\.count).reduce(0, +))")])

case "coldstart":
    let targets = profileTargets()
    line("profiles", [("claude", "\(targets.filter { $0.provider == .claude }.count)"),
                      ("codex", "\(targets.filter { $0.provider == .codex }.count)")])
    TranscriptReadTally.reset()
    let started = Date()
    let cpuStart = cpuSeconds()
    let result = await SessionEngine.measureStartupDiscovery(profiles: targets)
    let reads = TranscriptReadTally.current
    let after = memory()
    line("coldstart-discovery", [("filesConsidered", "\(reads.filesConsidered)"), ("filesRead", "\(reads.filesRead)"),
                                 ("bytesRead", mb(Double(reads.bytesRead) / megabyte)),
                                 ("codexSessions", "\(result.codexSessionCount)"), ("claudeSessions", "\(result.claudeSessionCount)"),
                                 ("restoredRecords", "\(result.restoredRecordCount)"),
                                 ("wall", seconds(Date().timeIntervalSince(started))), ("cpu", seconds(cpuSeconds() - cpuStart)),
                                 ("resident", mb(after.resident)), ("footprint", mb(after.footprint)), ("peak", mb(peakResident()))])
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
    let events = Counter()
    let tracker = CodexRolloutTracker()
    tracker.eventHandler = { _ in events.add() }
    let trackStarted = Date()
    let trackCPU = cpuSeconds()
    tracker.sync(targets: result.watchTargets)
    tracker.waitUntilIdle()
    let afterTrack = memory()
    line("coldstart-tracker", [("targets", "\(result.watchTargets.count)"), ("events", "\(events.value)"),
                               ("bytesRead", mb(Double(tracker.bytesRead) / megabyte)),
                               ("wall", seconds(Date().timeIntervalSince(trackStarted))), ("cpu", seconds(cpuSeconds() - trackCPU)),
                               ("resident", mb(afterTrack.resident)), ("footprint", mb(afterTrack.footprint)),
                               ("peak", mb(peakResident()))])
    tracker.stop()
    line("coldstart-total", [("wall", seconds(Date().timeIntervalSince(started))), ("cpu", seconds(cpuSeconds() - cpuStart)),
                             ("peak", mb(peakResident()))])

case "claudeold":
    let roots = profileTargets().filter { $0.provider == .claude }.map(\.folder).map(projectsFolder)
    var considered = 0
    var bytes = 0
    for root in roots {
        let found = newestTranscripts(in: root)
        considered += found.count
        bytes += found.reduce(0, +)
    }
    line("claudeold-files", [("profiles", "\(roots.count)"), ("filesConsidered", "\(considered)"),
                             ("bytesToRead", mb(Double(bytes) / megabyte))])
    let started = Date()
    let cpuStart = cpuSeconds()
    var sessions = 0
    for root in roots {
        sessions += ClaudeTranscriptDiscovery(rootURL: root).discoverRecentSessions().count
        let now = memory()
        line("claudeold-profile", [("wall", seconds(Date().timeIntervalSince(started))), ("resident", mb(now.resident)),
                                   ("footprint", mb(now.footprint)), ("peak", mb(peakResident()))])
    }
    line("claudeold-finished", [("sessions", "\(sessions)"), ("wall", seconds(Date().timeIntervalSince(started))),
                                ("cpu", seconds(cpuSeconds() - cpuStart)), ("peak", mb(peakResident()))])

case "claudenew":
    let started = Date()
    let cpuStart = cpuSeconds()
    var sessions = 0
    var totals = ClaudeTranscriptScanDiagnostics()
    let roots = profileTargets().filter { $0.provider == .claude }.map(\.folder).map(projectsFolder)
    for root in roots {
        let scanner = ClaudeTranscriptScanner(rootURL: root)
        sessions += scanner.discoverRecentSessions().count
        let diagnostics = scanner.lastScanDiagnostics
        totals.candidateCount += min(diagnostics.candidateCount, 40)
        totals.parsedFileCount += diagnostics.parsedFileCount
        totals.windowedFileCount += diagnostics.windowedFileCount
        totals.visitedFileCount += diagnostics.visitedFileCount
        totals.bytesRead += diagnostics.bytesRead
    }
    let now = memory()
    line("claudenew-finished", [("profiles", "\(roots.count)"), ("sessions", "\(sessions)"),
                                ("filesConsidered", "\(totals.candidateCount)"), ("filesRead", "\(totals.parsedFileCount)"),
                                ("windowed", "\(totals.windowedFileCount)"), ("walkedFiles", "\(totals.visitedFileCount)"),
                                ("bytesRead", mb(Double(totals.bytesRead) / megabyte)),
                                ("wall", seconds(Date().timeIntervalSince(started))), ("cpu", seconds(cpuSeconds() - cpuStart)),
                                ("footprint", mb(now.footprint)), ("peak", mb(peakResident()))])

case "claudecompare":
    var same = 0
    var total = 0
    var windowed = 0
    for root in profileTargets().filter({ $0.provider == .claude }).map(\.folder).map(projectsFolder) {
        let now = Date()
        let theirs = ClaudeTranscriptDiscovery(rootURL: root).discoverRecentSessions(now: now)
        let scanner = ClaudeTranscriptScanner(rootURL: root)
        let mine = scanner.discoverRecentSessions(now: now)
        windowed += scanner.lastScanDiagnostics.windowedFileCount
        total += theirs.count
        let byID = Dictionary(mine.map { ($0.id, $0) }) { first, _ in first }
        same += theirs.filter { byID[$0.id] == $0 }.count
    }
    line("claudecompare", [("sessions", "\(total)"), ("identical", "\(same)"), ("differing", "\(total - same)"),
                           ("windowedFiles", "\(windowed)")])

case "rescan":
    let scanner = CodexRolloutScanner()
    for pass in 1...3 {
        if pass == 3 { sleep(12) }
        let started = Date()
        let records = scanner.discoverRecentSessions()
        let diagnostics = scanner.lastScanDiagnostics
        line("rescan-pass\(pass)", [("records", "\(records.count)"), ("walkedFiles", "\(diagnostics.walkedFileCount)"),
                                    ("followedChanges", "\(diagnostics.followedChanges)"),
                                    ("changedPaths", "\(diagnostics.changedPathCount)"), ("parsed", "\(diagnostics.parsedFileCount)"),
                                    ("cacheHits", "\(diagnostics.cacheHitCount)"),
                                    ("bytesRead", mb(Double(diagnostics.bytesRead) / megabyte)),
                                    ("wall", String(format: "%.3fs", Date().timeIntervalSince(started))), ("peak", mb(peakResident()))])
    }

default:
    print("usage: RolloutScanMeasure new|old|watch|track|compare|claude|coldstart|claudeold|claudenew|claudecompare|rescan")
    exit(2)
}

/// Every Claude and Codex profile folder in the home folder, the way the app counts them but by name and by the folder
/// discovery reads (projects/ or sessions/) alone, so no login or settings file is looked at. Nothing about a folder
/// is printed but the counts.
func profileTargets() -> [ProfileHookTarget] {
    let home = NSHomeDirectory()
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).sorted()
    var targets: [ProfileHookTarget] = []
    for provider in Provider.allCases {
        let base = provider.defaultFolderName
        let inside = provider == .claude ? "projects" : "sessions"
        for (index, name) in names.enumerated() where name == base || name.hasPrefix(base + "-") {
            if provider == .claude, ProfileDiscovery.ignoredClaudePrefixes.contains(where: name.hasPrefix) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: home + "/" + name + "/" + inside, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            targets.append(ProfileHookTarget(provider: provider, folder: ProfileHookTargets.normalized(home + "/" + name),
                                             alias: "profile \(index)", isDefaultFolder: name == base, accountID: nil,
                                             isMonitored: false))
        }
    }
    return targets
}

func projectsFolder(_ folder: String) -> URL {
    URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("projects", isDirectory: true)
}

/// The sizes of the transcripts upstream's Claude discovery reads whole in `root`: the newest 40 of those modified in
/// the last day, never a subagent's. Metadata only.
func newestTranscripts(in root: URL) -> [Int] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
    let cutoff = Date.now.addingTimeInterval(-86_400)
    var found: [(Date, Int)] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" && !url.path.contains("/subagents/") {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
              let modified = values.contentModificationDate, modified >= cutoff else { continue }
        found.append((modified, values.fileSize ?? 0))
    }
    return found.sorted { $0.0 > $1.0 }.prefix(40).map(\.1)
}
