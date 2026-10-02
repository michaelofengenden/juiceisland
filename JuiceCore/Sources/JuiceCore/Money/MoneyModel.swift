import Foundation

/// The money sources (Juice spec §2.3, §8.1; Juice Island spec §8 decision 14), in the panel's reading order: the five
/// first (OpenRouter, Anthropic, OpenAI | RunPod, Hetzner), then the ones added with the figure kinds. Each reads one
/// host (`MoneyEndpoint.host`) with fixed `GET` paths, except RunPod's GraphQL `POST`.
public enum MoneySource: String, CaseIterable, Codable, Sendable, Hashable {
    case openRouter = "OpenRouter", anthropic = "Anthropic", openAI = "OpenAI", runPod = "RunPod", hetzner = "Hetzner"
    case deepSeek = "DeepSeek", moonshot = "Moonshot", xAI = "xAI", fireworks = "Fireworks", fal = "fal.ai"
    case elevenLabs = "ElevenLabs", vastAI = "Vast.ai", digitalOcean = "DigitalOcean"

    public var name: String { rawValue }

    /// Juice spec §8.1: OpenRouter and RunPod every 2 minutes; everyone else every 5 (the new sources document no
    /// limit this comes near: DigitalOcean allows 250 a minute, and Vast.ai's two or three requests fit its own).
    public var interval: TimeInterval {
        switch self {
        case .openRouter, .runPod: 120
        default: 300
        }
    }

    /// Anthropic and OpenAI take an optional credit with its date (Juice spec §2.3, §6).
    public var takesCredit: Bool { self == .anthropic || self == .openAI }
    /// OpenRouter and RunPod take an optional top-up amount (Juice spec §6).
    public var takesTopUp: Bool { self == .openRouter || self == .runPod }
    /// RunPod and Vast.ai: a balance burnt by the hour, so a runway toned by Settings › Money's amber and red.
    public var hasRunway: Bool { self == .runPod || self == .vastAI }

    /// What its key is, as Settings › Money's key field asks for it: Anthropic's, OpenAI's and fal's admin keys, xAI's
    /// management key, Hetzner's and DigitalOcean's API tokens, everyone else's API key.
    public var keyKind: String {
        switch self {
        case .anthropic, .openAI, .fal: "Admin key"
        case .xAI: "Management key"
        case .hetzner, .digitalOcean: "API token"
        default: "API key"
        }
    }

    /// The id a source's path needs besides its key (xAI's team, Fireworks' account), as Settings › Money names it; nil
    /// for the rest. It is no secret: Settings keeps it, and the request's path carries it (`MoneyEndpoint.idPattern`).
    public var accountIDName: String? {
        switch self {
        case .xAI: "Team ID"
        case .fireworks: "Account ID"
        default: nil
        }
    }

    /// The folders under `~/.config/` searched for a key file when none is picked (Juice spec §6).
    public var configFolders: [String] {
        switch self {
        case .openRouter: ["openrouter"]
        case .anthropic: ["anthropic"]
        case .openAI: ["openai"]
        case .runPod: ["runpod"]
        case .hetzner: ["hetzner", "hcloud"]
        case .deepSeek: ["deepseek"]
        case .moonshot: ["moonshot"]
        case .xAI: ["xai"]
        case .fireworks: ["fireworks"]
        case .fal: ["fal"]
        case .elevenLabs: ["elevenlabs"]
        case .vastAI: ["vastai"]
        case .digitalOcean: ["digitalocean"]
        }
    }

    /// The file names tried in each of those folders, in order. xAI and fal take an admin kind of key only, so a plain
    /// `key` another tool keeps there (an inference key) is never picked up; Vast.ai's CLI keeps its own full-access
    /// key as `vast_api_key`, which is not one of these names either (a scoped key is asked for instead).
    public var keyFileNames: [String] {
        switch self {
        case .anthropic, .openAI: ["admin-key", "admin_key", "key", "api-key", "api_key"]
        case .fal: ["admin-key", "admin_key"]
        case .xAI: ["management-key", "management_key"]
        case .hetzner: ["token", "key", "api-token", "api-key"]
        case .digitalOcean: ["token", "key", "api-token"]
        case .openRouter, .runPod: ["key", "api-key", "api_key", "token"]
        case .deepSeek, .moonshot, .fireworks, .elevenLabs, .vastAI: ["key", "api-key", "api_key"]
        }
    }

    /// Every place the default lookup tries, in its order: each name in each folder (`~/.config/<folder>/<name>`).
    public var lookupPaths: [String] {
        configFolders.flatMap { folder in keyFileNames.map { "~/.config/\(folder)/\($0)" } }
    }

    /// Where Settings › Money's Add key and Replace write a source's key: the first place the lookup tries, so the
    /// lookup finds it first (`~/.config/openrouter/key`, `~/.config/anthropic/admin-key`, `~/.config/hetzner/token`, …).
    public var defaultKeyPath: String { lookupPaths[0] }
}

/// One money account: a source and which of its keys (Juice Island spec §8 decision 14). A source's first key is the
/// account named like the source (`OpenRouter`), so its records, settings and row keep the names they had before a
/// source could hold more keys; a second key of the same source is `OpenRouter 2`, up to `maximumSlots`. Each account has
/// its own key file, reader, record and row.
public struct MoneyAccount: RawRepresentable, Hashable, Codable, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    /// Keys per source: the first and up to three more.
    public static let maximumSlots = 4

    public let source: MoneySource
    /// 1 for the source's first key, 2 up to `maximumSlots` for the others.
    public let slot: Int

    public init(_ source: MoneySource, slot: Int = 1) {
        self.source = source
        self.slot = min(max(slot, 1), Self.maximumSlots)
    }

    /// `OpenRouter`, `OpenRouter 2`; nothing else reads as an account.
    public init?(rawValue: String) {
        if let source = MoneySource(rawValue: rawValue) {
            self.init(source)
            return
        }
        guard let space = rawValue.lastIndex(of: " "), let source = MoneySource(rawValue: String(rawValue[..<space])),
              let slot = Int(rawValue[rawValue.index(after: space)...]), (2...Self.maximumSlots).contains(slot),
              String(slot) == rawValue[rawValue.index(after: space)...] else { return nil }
        self.init(source, slot: slot)
    }

    public var rawValue: String { slot == 1 ? source.rawValue : "\(source.rawValue) \(slot)" }
    public var description: String { rawValue }
    public var isFirst: Bool { slot == 1 }

    /// The name a row shows when the owner gave the account no label: `OpenRouter`, `OpenRouter 2`.
    public var defaultName: String { rawValue }

    /// Every account there can be, each source's slots in order.
    public static var allCases: [MoneyAccount] {
        MoneySource.allCases.flatMap { source in (1...maximumSlots).map { MoneyAccount(source, slot: $0) } }
    }

    /// Each source's first key, in the panel's order: the accounts that are always read (with no key file, a read only
    /// looks for one and sends nothing).
    public static var firsts: [MoneyAccount] { MoneySource.allCases.map { MoneyAccount($0) } }

    /// The panel's order: by source, then slot.
    public static func < (lhs: MoneyAccount, rhs: MoneyAccount) -> Bool {
        let order = MoneySource.allCases
        let (left, right) = (order.firstIndex(of: lhs.source) ?? 0, order.firstIndex(of: rhs.source) ?? 0)
        return left != right ? left < right : lhs.slot < rhs.slot
    }

    /// Where the default lookup looks for this account's key file: the source's places for its first key; for another,
    /// one file beside the source's own, named after it (`~/.config/openrouter/key-2`, `~/.config/anthropic/admin-key-3`).
    public var lookupPaths: [String] {
        isFirst ? source.lookupPaths : [source.defaultKeyPath + "-\(slot)"]
    }

    /// Where Add key and Replace write this account's key: the first place its lookup tries.
    public var defaultKeyPath: String { lookupPaths[0] }

    public static let openRouter = MoneyAccount(.openRouter), anthropic = MoneyAccount(.anthropic), openAI = MoneyAccount(.openAI)
    public static let runPod = MoneyAccount(.runPod), hetzner = MoneyAccount(.hetzner), deepSeek = MoneyAccount(.deepSeek)
    public static let moonshot = MoneyAccount(.moonshot), xAI = MoneyAccount(.xAI), fireworks = MoneyAccount(.fireworks)
    public static let fal = MoneyAccount(.fal), elevenLabs = MoneyAccount(.elevenLabs), vastAI = MoneyAccount(.vastAI)
    public static let digitalOcean = MoneyAccount(.digitalOcean)
}

/// The currencies the sources answer in. An answer in any other is an unexpected answer, never drawn in a wrong one.
public enum MoneyCurrency: String, Codable, Sendable, Hashable, CaseIterable {
    case usd, eur, cny

    /// `$`, `€`, and `¥` for DeepSeek's yuan (no source answers in yen).
    public var symbol: String {
        switch self {
        case .usd: "$"
        case .eur: "€"
        case .cny: "¥"
        }
    }

    /// `USD`, `usd`, `CNY`, `EUR`: the ISO code as an API sends it; nil for any other currency.
    public init?(code: String) {
        self.init(rawValue: code.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// An API key read from its key file for one request and dropped after it. It never prints, never mirrors and is not
/// Codable, so it cannot reach a log, a reading, readings.json or Diagnostics by accident (Juice spec §8.1, §8.3).
public struct MoneyKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String

    public init(_ value: String) { self.value = value }

    public var description: String { "\u{2039}key\u{203A}" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Why a money source has no fresh figure. Codable for the saved state; never carries a key or a response body.
public enum MoneyReadError: Error, Codable, Sendable, Equatable, Hashable {
    /// No key file picked and none found under `~/.config/<provider>/`: the source is hidden.
    case notConfigured
    /// The key file is a CLI credential file or lies in a refused folder; it was never opened.
    case keyFileRefused(String)
    /// The key file is missing, not a regular file or too large.
    case keyFileUnreadable(String)
    /// The key is empty, spans lines, or has the wrong shape for this source; nothing was sent.
    case keyNotUsable
    /// The API answered 401 or 403: the key lacks the role (Anthropic and OpenAI need an Admin key).
    case notAvailableWithThisKey
    /// `MoneyHostPolicy` refused the request before a byte was sent.
    case refusedByPolicy(String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case timeout
    case offline
    case unreadableResponse(String)
    /// The source's path needs an id Settings › Money does not have (xAI's team, Fireworks' account): nothing was sent.
    case idMissing(String)
    /// The id Settings › Money has is not of its pattern (a typo, another kind of id, a key pasted there): nothing was
    /// sent.
    case idInvalid(String)

    /// The Money pane's and Diagnostics' status word.
    public var statusWord: String {
        switch self {
        case .notConfigured: "Not connected"
        case .keyFileRefused: "Key file refused"
        case .keyFileUnreadable: "Key file missing"
        case .keyNotUsable, .notAvailableWithThisKey: "Not available with this key"
        case .refusedByPolicy: "Refused"
        case .rateLimited: "Rate limited"
        case .http(let status): "Read failed (\(status))"
        case .timeout: "Timed out"
        case .offline: "Offline"
        case .unreadableResponse: "Unexpected answer"
        case .idMissing(let name): "\(name) not set"
        case .idInvalid(let name): "\(name) not valid"
        }
    }

    /// The word for this source, saying what to do where the source's own answer tells it (P363): OpenAI's costs refuse
    /// any key but an Admin key, and Hetzner refuses a token it does not know (a Read token is all the servers list
    /// needs). Every other source and failure keeps `statusWord`.
    public func statusWord(for source: MoneySource) -> String {
        switch (self, source) {
        case (.notAvailableWithThisKey, .openAI): "Needs an Admin key (sk-admin-…)"
        case (.notAvailableWithThisKey, .hetzner): "Token rejected · make a Read token"
        default: statusWord
        }
    }

    /// The failure came before any request went out (no key file, a refused one, a key of the wrong kind, the policy):
    /// the API was not asked, so a key saved next waits for no floor.
    public var sentNothing: Bool {
        switch self {
        case .notConfigured, .keyFileRefused, .keyFileUnreadable, .keyNotUsable, .refusedByPolicy, .idMissing, .idInvalid: true
        case .notAvailableWithThisKey, .rateLimited, .http, .timeout, .offline, .unreadableResponse: false
        }
    }

    /// The hover label's reason, lower case.
    public var hoverReason: String {
        switch self {
        case .notConfigured: "not connected"
        case .keyFileRefused(let why): "key file refused: \(why)"
        case .keyFileUnreadable(let why): "key file \(why)"
        case .keyNotUsable, .notAvailableWithThisKey: "not available with this key"
        case .refusedByPolicy: "request refused"
        case .rateLimited: "rate limited"
        case .http(let status): "read failed (\(status))"
        case .timeout: "timed out"
        case .offline: "offline"
        case .unreadableResponse: "unexpected answer"
        case .idMissing(let name): name.lowercased().replacingOccurrences(of: " id", with: " ID") + " not set"
        case .idInvalid(let name): name.lowercased().replacingOccurrences(of: " id", with: " ID") + " not valid"
        }
    }
}

/// What the owner set for a source in Settings › Money. The key file's path only, never the key.
public struct MoneySourceSettings: Sendable, Equatable, Hashable {
    /// The picked key file; nil looks under `~/.config/<provider>/`.
    public var keyPath: String?
    /// Anthropic, OpenAI: the credit and the day it was bought (UTC day).
    public var credit: Double?
    public var creditDate: Date?
    /// OpenRouter, RunPod: the last top-up (measure for "84% left"; OpenRouter's balance when `/credits` is refused
    /// and the key has no limit).
    public var topUp: Double?
    /// xAI's team id, Fireworks' account id (`MoneySource.accountIDName`): part of the path, never a secret.
    public var accountID: String?
    /// The owner's short name for the account, drawn in place of `MoneyAccount.defaultName`; nil keeps that.
    public var label: String?

    public init(keyPath: String? = nil, credit: Double? = nil, creditDate: Date? = nil, topUp: Double? = nil, accountID: String? = nil,
                label: String? = nil) {
        self.keyPath = keyPath
        self.credit = credit
        self.creditDate = creditDate
        self.topUp = topUp
        self.accountID = accountID
        self.label = label
    }
}

/// A source's saved state: the last good reading and the last failure, kept apart so a failure never hides the last
/// figure's real age (Juice spec §9.5). Never holds a key.
public struct MoneySourceRecord: Codable, Sendable, Equatable {
    public var lastGood: MoneyReading?
    public var lastError: MoneyReadError?
    public var lastErrorAt: Date?
    public var lastAttemptAt: Date?
    /// Retry-After plus the margin; no request before this.
    public var pausedUntil: Date?
    public var consecutiveFailures: Int
    /// When the next scheduled read is due (Diagnostics).
    public var nextReadAt: Date?
    /// The key file's name (the last path component only), for Settings › Money.
    public var keyFileName: String?

    public init(lastGood: MoneyReading? = nil, lastError: MoneyReadError? = nil, lastErrorAt: Date? = nil,
                lastAttemptAt: Date? = nil, pausedUntil: Date? = nil, consecutiveFailures: Int = 0, nextReadAt: Date? = nil,
                keyFileName: String? = nil) {
        self.lastGood = lastGood
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.lastAttemptAt = lastAttemptAt
        self.pausedUntil = pausedUntil
        self.consecutiveFailures = consecutiveFailures
        self.nextReadAt = nextReadAt
        self.keyFileName = keyFileName
    }

    /// The failure is newer than the last good reading.
    public var isFailing: Bool {
        guard let lastErrorAt else { return false }
        guard let good = lastGood else { return true }
        return lastErrorAt >= good.readAt
    }

    /// The record once the key changed (Settings › Money's Save and Remove): the old key's reading and failures go, the
    /// last attempt stays (the 30 s floor counts from it), and a 429 pause still running stays with its failure, so the
    /// surfaces say why nothing is read yet.
    public func afterKeyChange(now: Date) -> MoneySourceRecord {
        let paused = pausedUntil.map { $0 > now } ?? false
        return MoneySourceRecord(lastError: paused ? lastError : nil, lastErrorAt: paused ? lastErrorAt : nil, lastAttemptAt: lastAttemptAt,
                                 pausedUntil: paused ? pausedUntil : nil, consecutiveFailures: paused ? consecutiveFailures : 0)
    }

    /// What stays of a further key's record once its key is gone: a 429 pause still running, with its failure, so a key
    /// added in the same place waits it out (Retry-After + 900 s, as the first key does across Remove, P146); nil once
    /// the pause is over or when there is none.
    public func pauseOnly(now: Date) -> MoneySourceRecord? {
        guard let pausedUntil, pausedUntil > now else { return nil }
        return afterKeyChange(now: now)
    }
}
