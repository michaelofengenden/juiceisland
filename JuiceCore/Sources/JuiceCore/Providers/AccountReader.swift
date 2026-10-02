import Foundation

public protocol AccountReader: Sendable {
    func read(_ account: Account, now: Date) async -> Result<AccountReading, ReadError>
}

extension ReadError {
    /// Maps a CLI that exited without answering to a `ReadError`, from its output.
    public static func classify(exitStatus: Int32, stdout: String, stderr: String) -> ReadError {
        let text = (stderr + "\n" + stdout).lowercased()
        if text.contains("not logged in") || text.contains("please run /login") || text.contains("invalid api key")
            || text.contains("authentication_error") || text.contains("oauth token") {
            return .signInRequired
        }
        let hasRateLimitWord = text.contains("rate_limit") || text.contains("rate limit") || text.contains("too many requests")
        // A bare "429" can appear in unrelated numbers (a duration_ms, a UUID); only trust it when it is a
        // standalone token on a line that also talks about a status/error/http/retry.
        let contextWords = ["status", "error", "http", "retry"]
        let has429WithContext = text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            guard line.range(of: #"(^|[^0-9])429([^0-9]|$)"#, options: .regularExpression) != nil else { return false }
            return contextWords.contains { line.contains($0) }
        }
        if hasRateLimitWord || has429WithContext {
            let retry = text.range(of: #"retry-after:\s*(\d+)"#, options: .regularExpression)
                .flatMap { Double(text[$0].split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") }
            return .rateLimited(retryAfter: retry)
        }
        if text.contains("unknown option") || text.contains("unrecognized") || text.contains("invalid value") {
            return .cliUpdateNeeded(String(redact(stderr.trimmingCharacters(in: .whitespacesAndNewlines)).suffix(300)))
        }
        if text.contains("enotfound") || text.contains("econnrefused") || text.contains("network is unreachable")
            || text.contains("fetch failed") || text.contains("offline") {
            return .offline
        }
        // Masked before it is truncated: cutting a token in half would still leave part of it in readings.json.
        let detail = redact(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        return .failed(detail.isEmpty ? "exit \(exitStatus)" : String(detail.suffix(300)))
    }
}
