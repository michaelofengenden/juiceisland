import JuiceCore
import Foundation

// juice-probe claude|codex <profile-folder> [--every SECONDS] [--count N]
// Reads one real account through the real reader, prints one redacted line per read, then a summary.

@main
struct Probe {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        var every: TimeInterval = 60
        var count = 1
        func take(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            let value = args[index + 1]
            args.removeSubrange(index...index + 1)
            return value
        }
        if let value = take("--every"), let seconds = TimeInterval(value) { every = seconds }
        if let value = take("--count"), let n = Int(value) { count = n }
        guard args.count == 2, let provider = Provider(rawValue: args[0]) else {
            print("usage: juice-probe claude|codex <profile-folder> [--every SECONDS] [--count N]")
            exit(2)
        }
        let folder = (args[1] as NSString).expandingTildeInPath
        let account = Account(provider: provider, folder: folder, alias: (folder as NSString).lastPathComponent)

        guard let executable = ToolLocator.locate(provider.rawValue) else {
            print("\(provider.rawValue) not found on PATH \(ToolLocator.loginShellPATH())")
            exit(1)
        }
        print("probe \(Juice.version) · \(provider.displayName) · \(executable.path) · \(folder) · every \(Int(every)) s × \(count)")

        let reader: any AccountReader = provider == .claude ? ClaudeCLIReader(executable: executable) : CodexReaderPool(executable: executable)
        var durations: [TimeInterval] = []
        var failures = 0
        for i in 1...count {
            let started = Date()
            let result = await reader.read(account, now: started)
            let elapsed = Date().timeIntervalSince(started)
            durations.append(elapsed)
            let stamp = ISO8601DateFormatter().string(from: started)
            switch result {
            case .success(let reading):
                let windows = reading.windows.map { "\($0.displayLabel)=\(Int($0.usedPercent))% resets \($0.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "?")" }
                print("[\(i)] \(stamp) ok \(String(format: "%.2f", elapsed)) s · plan \(reading.plan ?? "?") · left \(Rules.percentLeft(reading))% · \(windows.joined(separator: " · "))\(reading.ordinaryUsageAllowed ? "" : " · BLOCKED")")
            case .failure(let error):
                failures += 1
                print("[\(i)] \(stamp) FAIL \(String(format: "%.2f", elapsed)) s · \(error)")
            }
            if i < count { try? await Task.sleep(for: .seconds(every)) }
        }
        if let pool = reader as? CodexReaderPool { await pool.shutdownAll() }
        let sorted = durations.sorted()
        print("summary: \(count) reads, \(failures) failed, min \(String(format: "%.2f", sorted.first ?? 0)) s, median \(String(format: "%.2f", sorted[sorted.count / 2])) s, max \(String(format: "%.2f", sorted.last ?? 0)) s")
    }
}
