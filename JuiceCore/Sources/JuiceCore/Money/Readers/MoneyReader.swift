import Foundation

/// What a reader knows about the read it is asked for.
public struct MoneyReadContext: Sendable {
    public var now: Date
    public var settings: MoneySourceSettings

    public init(now: Date, settings: MoneySourceSettings = MoneySourceSettings()) {
        self.now = now
        self.settings = settings
    }
}

extension MoneyReadContext {
    /// The id `endpoint`'s path needs, from Settings › Money: trimmed, lower-cased (`MoneyEndpoint.normalizedID`), and
    /// of the endpoint's pattern. Without one, or with one not of the pattern, nothing is sent (`idMissing`,
    /// `idInvalid`, named as Settings names it).
    static func id(_ value: String?, for endpoint: MoneyEndpoint) throws(MoneyReadError) -> String {
        let name = endpoint.source.accountIDName ?? "ID"
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .idMissing(name) }
        let id = endpoint.normalizedID(value)
        guard endpoint.accepts(id: id) else { throw .idInvalid(name) }
        return id
    }
}

/// One money source's reader: builds its requests from `MoneyEndpoint`, sends them through the client and parses the
/// answers into a `MoneyReading`. It gets the key for this read only and keeps nothing of it.
public protocol MoneyReader: Sendable {
    var source: MoneySource { get }
    func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading
    /// Drops whatever the reader kept from earlier reads: the key changed, and another key may see another account.
    /// Every reader says so itself (no default), so an actor's own `forget` is never passed over for an empty one.
    func forget() async
}

enum MoneyJSON {
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, _ what: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MoneyReadError.unreadableResponse(what)
        }
    }

    /// A number the APIs send as a JSON number or as a decimal string (Hetzner's prices, Anthropic's cents). A string
    /// like `inf`, `nan` or `1e400` is not a number here, and neither is anything past `limit`: no figure drawn from an
    /// answer can be infinite or too large to format.
    struct Number: Decodable, Sendable {
        static let limit = 1e12
        var value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let parsed: Double? = if let number = try? container.decode(Double.self) {
                number
            } else if let text = try? container.decode(String.self) {
                Double(text)
            } else {
                nil
            }
            guard let parsed, parsed.isFinite, abs(parsed) < Self.limit else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number")
            }
            value = parsed
        }
    }
}

extension MoneyHostPolicy {
    /// Refuses a key before any request is built: a Claude OAuth token or a sign-in token shaped like a JWT (ChatGPT's,
    /// Codex's) for any source, any `sk-ant-` value for a source other than Anthropic, and for Anthropic anything but an
    /// Admin key (Juice Island spec §5.1 rule 2).
    public static func keyRefusal(_ key: MoneyKey, for source: MoneySource) -> MoneyReadError? {
        let value = key.value
        // Anywhere in the value, not just at its start: a one-line file that wraps a token (compact JSON) is refused too.
        if claudeTokenPrefixes.contains(where: { value.contains($0) }) || carriesSignInToken(value) { return .keyNotUsable }
        if source == .anthropic { return value.hasPrefix(adminKeyPrefix) ? nil : .keyNotUsable }
        return value.contains(anthropicKeyPrefix) ? .keyNotUsable : nil
    }
}
