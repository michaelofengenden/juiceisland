import Foundation
import Synchronization

/// One money request before it goes out: the endpoint (from `MoneyHostPolicy`'s list), its query, the id its path
/// needs (xAI's team, Fireworks' account), the key and an optional body. The key is attached here, for this request only.
public struct MoneyRequest: Sendable {
    public var endpoint: MoneyEndpoint
    public var query: [URLQueryItem]
    public var id: String?
    public var key: MoneyKey
    public var body: Data?

    public init(_ endpoint: MoneyEndpoint, query: [URLQueryItem] = [], id: String? = nil, key: MoneyKey, body: Data? = nil) {
        self.endpoint = endpoint
        self.query = query
        self.id = id
        self.key = key
        self.body = body
    }
}

public struct MoneyResponse: Sendable {
    public var status: Int
    public var body: Data
    /// `Retry-After` in seconds (a number or an HTTP date), when the answer carried one.
    public var retryAfter: TimeInterval?

    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.body = body
        self.retryAfter = retryAfter
    }

    /// The body of a 2xx answer; 401 and 403 are a key without the role, 429 a pause, anything else a failure.
    public func ok() throws(MoneyReadError) -> Data {
        switch status {
        case 200..<300: return body
        case 401, 403: throw .notAvailableWithThisKey
        case 429: throw .rateLimited(retryAfter: retryAfter)
        default: throw .http(status)
        }
    }
}

/// What Diagnostics › Money shows of a request: method, host, path and the status. Never the query or a header, and a
/// path with an id in it as its endpoint names it (`/v1/billing/teams/{id}/prepaid/balance`), never with the id.
public struct MoneyRequestRecord: Sendable, Equatable {
    public var at: Date
    public var source: MoneySource
    /// The account whose read sent it (`MoneyHTTPClient.account`); nil for a request sent outside a scheduled read.
    public var account: MoneyAccount?
    public var method: String
    public var host: String
    public var path: String
    /// The HTTP status, or nil when nothing came back.
    public var status: Int?
    /// `sent`, or why nothing was sent (a refusal) or nothing came back.
    public var outcome: String

    public var line: String {
        "\(method) \(host)\(path) · " + (status.map(String.init) ?? outcome)
    }
}

/// The only type that sends HTTP (Juice Island spec §5.2; guardrail check 3): an ephemeral session with no cookies,
/// no cache and no redirects followed. Each request is built here with only its allowed headers, the app's own
/// User-Agent and the key in its one allowed place, then checked by `MoneyHostPolicy` right before it is handed to the
/// network; a refusal sends nothing. Tests pass `protocolClasses` so every request lands in a stub.
public final class MoneyHTTPClient: Sendable {
    public static let userAgent = "JuiceIsland/1.0 (money; macOS)"
    public static let timeout: TimeInterval = 15
    static let logLimit = 40

    private let session: URLSession
    private let userAgent: String
    private let timeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let records = Mutex<[MoneyRequestRecord]>([])

    /// The account whose read is running: the scheduler sets it around a reader's read, so each request is recorded for
    /// that account (two keys of one source keep their own Diagnostics lines) without a reader passing it along.
    @TaskLocal public static var account: MoneyAccount?

    public init(protocolClasses: [AnyClass]? = nil, userAgent: String = MoneyHTTPClient.userAgent,
                timeout: TimeInterval = MoneyHTTPClient.timeout, clock: @escaping @Sendable () -> Date = { Date() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [:]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
        self.userAgent = userAgent
        self.timeout = timeout
        self.clock = clock
    }

    deinit { session.invalidateAndCancel() }

    /// The newest requests first (Diagnostics › Money).
    public var recentRequests: [MoneyRequestRecord] { records.withLock { Array($0.reversed()) } }

    /// The request exactly as it would go out (tests read it; `send` checks it).
    public func urlRequest(for request: MoneyRequest) -> URLRequest {
        let endpoint = request.endpoint
        var urlRequest = URLRequest(url: endpoint.url(query: request.query, id: request.id), cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: timeout)
        urlRequest.httpMethod = endpoint.method
        urlRequest.httpShouldHandleCookies = false
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let placement = endpoint.keyPlacement
        urlRequest.setValue(placement.value(request.key), forHTTPHeaderField: placement.headerName)
        if endpoint == .anthropicCostReport {
            urlRequest.setValue(MoneyHostPolicy.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    public func send(_ request: MoneyRequest) async throws(MoneyReadError) -> MoneyResponse {
        try await send(urlRequest(for: request), source: request.endpoint.source)
    }

    /// Sends a request that is already built, after the policy check. Everything goes through here.
    public func send(_ urlRequest: URLRequest, source: MoneySource) async throws(MoneyReadError) -> MoneyResponse {
        let method = urlRequest.httpMethod ?? "GET"
        let components = urlRequest.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let host = components?.percentEncodedHost ?? "?"
        let sentPath = components?.percentEncodedPath ?? "?"
        let path = Self.recordedPath(host: host, path: sentPath)
        let account = Self.account
        func record(_ status: Int?, _ outcome: String) {
            let entry = MoneyRequestRecord(at: clock(), source: source, account: account, method: method, host: host, path: path,
                                           status: status, outcome: outcome)
            records.withLock { list in
                list.append(entry)
                if list.count > Self.logLimit { list.removeFirst(list.count - Self.logLimit) }
            }
        }
        if let refusal = MoneyHostPolicy.check(urlRequest) {
            record(nil, "refused: \(refusal.reason)")
            throw .refusedByPolicy(refusal.reason)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                record(nil, "no HTTP answer")
                throw MoneyReadError.unreadableResponse("no HTTP answer")
            }
            record(http.statusCode, "sent")
            return MoneyResponse(status: http.statusCode, body: data,
                                 retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"), now: clock()))
        } catch let error as MoneyReadError {
            throw error
        } catch let error as URLError {
            let mapped: MoneyReadError = switch error.code {
            case .timedOut: .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .internationalRoamingOff, .dataNotAllowed: .offline
            default: .unreadableResponse("network error \(error.code.rawValue)")
            }
            record(nil, mapped.hoverReason)
            throw mapped
        } catch {
            record(nil, "failed")
            throw .unreadableResponse("network error")
        }
    }

    /// The path as Diagnostics shows it: on a host whose path takes an id (xAI's, Fireworks'), the endpoint's own path
    /// (`/v1/billing/teams/{id}/prepaid/balance`), whatever was sent, so an id (a valid one, or text the policy refused)
    /// stays out of Diagnostics; any other path as sent.
    static func recordedPath(host: String, path: String) -> String {
        MoneyEndpoint.allCases.first { $0.idPattern != nil && $0.host == host }?.path ?? path
    }

    /// The longest `Retry-After` taken as given: a week. A server's `inf`, `nan` or `1e400` never reaches a sleep, which
    /// would trap on a value that is not finite.
    static let retryAfterLimit: TimeInterval = 7 * 86_400

    /// `Retry-After`: delta seconds or an HTTP date, within 0 and a week.
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        func bounded(_ seconds: TimeInterval) -> TimeInterval? {
            seconds.isNaN ? nil : min(retryAfterLimit, max(0, seconds))
        }
        if let seconds = TimeInterval(value) { return bounded(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).flatMap { bounded($0.timeIntervalSince(now)) }
    }
}

/// Refuses every redirect: the task ends with the 3xx answer, and the key is sent once.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
