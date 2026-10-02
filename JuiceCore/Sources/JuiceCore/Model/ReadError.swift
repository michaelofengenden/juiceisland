import Foundation

/// Why a read failed. Codable so the last failure can be persisted and shown in Diagnostics.
public enum ReadError: Error, Codable, Sendable, Equatable, Hashable {
    case cliNotFound
    case cliUpdateNeeded(String)
    case signInRequired
    case rateLimited(retryAfter: TimeInterval?)
    case timeout
    case offline
    case incomplete(String)
    case failed(String)

    /// What replaces anything token-shaped in stored or displayed CLI text.
    public static let redactionMark = "\u{2039}redacted\u{203A}"

    /// Shapes that must never be written down (spec §8.3): Anthropic/OpenAI API keys, an Authorization bearer
    /// value, and a JWT. The API-key shape comes first so a bearer that is one collapses to a single mark.
    private static let secretPatterns = [
        #"sk-ant-[A-Za-z0-9_-]{8,}"#,
        #"sk-[A-Za-z0-9_-]{8,}"#,
        #"(?i)bearer\s+\S+"#,
        #"eyJ[A-Za-z0-9_-]{10,}(\.[A-Za-z0-9_-]+){1,2}"#,
    ]

    /// Masks token-shaped text. Juice never reads a credential; this only makes sure a CLI that printed one cannot
    /// get it persisted into readings.json or shown in Diagnostics. Over-masking is the safe direction here.
    public static func redact(_ text: String) -> String {
        var masked = text
        for pattern in secretPatterns {
            masked = masked.replacingOccurrences(of: pattern, with: redactionMark, options: .regularExpression)
        }
        return masked
    }

    public var shortDescription: String {
        switch self {
        case .cliNotFound: "CLI not found"
        case .cliUpdateNeeded: "CLI update needed"
        case .signInRequired: "Sign-in required"
        case .rateLimited: "Rate limited"
        case .timeout: "Timed out"
        case .offline: "Offline"
        case .incomplete(let what): "Reading incomplete: \(what)"
        case .failed(let why): "Read failed: \(why)"
        }
    }
}
