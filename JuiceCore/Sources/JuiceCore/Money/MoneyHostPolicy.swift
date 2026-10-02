import Foundation

/// Where a request carries its key (Juice Island spec §8 decision 14): one place per endpoint, and nowhere else.
public enum MoneyKeyPlacement: Equatable, Sendable {
    /// `Authorization: Bearer <key>`: every source but these three.
    case bearer
    /// The key alone in its own header: Anthropic's `x-api-key`, ElevenLabs' `xi-api-key` (lower case).
    case header(String)
    /// `Authorization: <scheme> <key>`: fal.ai's `Key`.
    case scheme(String)

    /// The header (lower case) that carries the key.
    public var headerName: String {
        switch self {
        case .bearer, .scheme: "authorization"
        case .header(let name): name
        }
    }

    /// The header's value for `key`.
    public func value(_ key: MoneyKey) -> String {
        switch self {
        case .bearer: "Bearer \(key.value)"
        case .header: key.value
        case .scheme(let scheme): "\(scheme) \(key.value)"
        }
    }

    /// The key a header value carries in this place, or nil when the value is not shaped as this place's.
    func key(in value: String) -> String? {
        switch self {
        case .bearer: value.hasPrefix("Bearer ") && value.count > 7 ? String(value.dropFirst(7)) : nil
        case .header: value.isEmpty ? nil : value
        case .scheme(let scheme): value.hasPrefix(scheme + " ") && value.count > scheme.count + 1 ? String(value.dropFirst(scheme.count + 1)) : nil
        }
    }
}

/// Every request the money client may send, as (host, method, path) with the query names and headers it may carry
/// (Juice spec §8.1; Juice Island spec §8 decision 14). The one file in our sources that names the forbidden hosts
/// (Juice Island spec §5.1 rule 2, §5.2; guardrail check 3): it names `api.anthropic.com` to allow exactly one request
/// there, `GET /v1/organizations/cost_report` with an Admin API key (§7 amendment 10), and names `chatgpt.com` and the
/// usage endpoints only to refuse them. Any other request under `/v1/organizations/` needs the owner's approval and a new
/// amendment first, and no method but `GET` is ever allowed on that host. Each source has one host; a path with an id in
/// it (xAI's team, Fireworks' account) takes only an id of its pattern in that one segment.
public enum MoneyEndpoint: String, CaseIterable, Sendable {
    case openRouterKey, openRouterCredits
    case anthropicCostReport
    case openAICosts
    case runPodGraphQL
    case hetznerServers, hetznerVolumes, hetznerPrimaryIPs, hetznerFloatingIPs, hetznerPricing
    case deepSeekBalance
    case moonshotBalance
    case xAIPrepaidBalance
    case fireworksBillingSummary
    case falBilling
    case elevenLabsSubscription
    case vastUser, vastInstances
    case digitalOceanBalance

    public var source: MoneySource {
        switch self {
        case .openRouterKey, .openRouterCredits: .openRouter
        case .anthropicCostReport: .anthropic
        case .openAICosts: .openAI
        case .runPodGraphQL: .runPod
        case .hetznerServers, .hetznerVolumes, .hetznerPrimaryIPs, .hetznerFloatingIPs, .hetznerPricing: .hetzner
        case .deepSeekBalance: .deepSeek
        case .moonshotBalance: .moonshot
        case .xAIPrepaidBalance: .xAI
        case .fireworksBillingSummary: .fireworks
        case .falBilling: .fal
        case .elevenLabsSubscription: .elevenLabs
        case .vastUser, .vastInstances: .vastAI
        case .digitalOceanBalance: .digitalOcean
        }
    }

    public var host: String {
        switch source {
        case .openRouter: "openrouter.ai"
        case .anthropic: MoneyHostPolicy.anthropicHost
        case .openAI: "api.openai.com"
        case .runPod: "api.runpod.io"
        case .hetzner: "api.hetzner.cloud"
        case .deepSeek: "api.deepseek.com"
        case .moonshot: "api.moonshot.ai"
        case .xAI: "management-api.x.ai"
        case .fireworks: "api.fireworks.ai"
        case .fal: "api.fal.ai"
        case .elevenLabs: "api.elevenlabs.io"
        case .vastAI: "console.vast.ai"
        case .digitalOcean: "api.digitalocean.com"
        }
    }

    /// The path; `{id}` stands for the one segment `idPattern` validates.
    public var path: String {
        switch self {
        case .openRouterKey: "/api/v1/key"
        case .openRouterCredits: "/api/v1/credits"
        case .anthropicCostReport: "/v1/organizations/cost_report"
        case .openAICosts: "/v1/organization/costs"
        case .runPodGraphQL: "/graphql"
        case .hetznerServers: "/v1/servers"
        case .hetznerVolumes: "/v1/volumes"
        case .hetznerPrimaryIPs: "/v1/primary_ips"
        case .hetznerFloatingIPs: "/v1/floating_ips"
        case .hetznerPricing: "/v1/pricing"
        case .deepSeekBalance: "/user/balance"
        case .moonshotBalance: "/v1/users/me/balance"
        case .xAIPrepaidBalance: "/v1/billing/teams/{id}/prepaid/balance"
        case .fireworksBillingSummary: "/v1/accounts/{id}/billing/summary"
        case .falBilling: "/v1/account/billing"
        case .elevenLabsSubscription: "/v1/user/subscription"
        case .vastUser: "/api/v0/users/current"
        case .vastInstances: "/api/v1/instances"
        case .digitalOceanBalance: "/v2/customers/my/balance"
        }
    }

    /// The whole segment an id must be, when the path has one: xAI's team id is a lower-case UUID, Fireworks' account id
    /// lower-case letters, digits and hyphens. Neither can hold a `/`, a `%`, a `.` or a query, so an id never reaches
    /// another path.
    public var idPattern: String? {
        switch self {
        case .xAIPrepaidBalance: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        case .fireworksBillingSummary: "[a-z0-9][a-z0-9-]{0,62}"
        default: nil
        }
    }

    public var method: String { self == .runPodGraphQL ? "POST" : "GET" }

    /// Query names the request may carry; nothing else, and never a key (`MoneyHostPolicy.keyLikeQuery`).
    public var allowedQuery: Set<String> {
        switch self {
        case .anthropicCostReport: ["starting_at", "ending_at", "bucket_width", "limit", "page"]
        case .openAICosts: ["start_time", "end_time", "bucket_width", "limit", "page"]
        case .hetznerServers, .hetznerVolumes, .hetznerPrimaryIPs, .hetznerFloatingIPs: ["page", "per_page"]
        case .fireworksBillingSummary: ["startTime", "endTime"]
        case .falBilling: ["expand"]
        case .vastInstances: ["limit", "after_token", "select_cols"]
        case .openRouterKey, .openRouterCredits, .runPodGraphQL, .hetznerPricing, .deepSeekBalance, .moonshotBalance, .xAIPrepaidBalance,
             .elevenLabsSubscription, .vastUser, .digitalOceanBalance: []
        }
    }

    /// How the key travels: Anthropic's in `x-api-key`, ElevenLabs' in `xi-api-key`, fal.ai's as `Authorization: Key`,
    /// everyone else's as a bearer token.
    public var keyPlacement: MoneyKeyPlacement {
        switch source {
        case .anthropic: .header("x-api-key")
        case .elevenLabs: .header("xi-api-key")
        case .fal: .scheme("Key")
        default: .bearer
        }
    }

    /// Header names (lower case) the request may carry: `Accept`, the app's `User-Agent` and the key's one header;
    /// Anthropic's cost report also `anthropic-version` (exactly these four), RunPod's GraphQL its `Content-Type`.
    public var allowedHeaders: Set<String> {
        var names: Set<String> = ["accept", "user-agent", keyPlacement.headerName]
        if self == .anthropicCostReport { names.insert("anthropic-version") }
        if allowsBody { names.insert("content-type") }
        return names
    }

    public var allowsBody: Bool { self == .runPodGraphQL }

    /// The endpoint's URL with `query` (names from `allowedQuery`) and, for a path with an id, `id` in its segment. The id
    /// is put in as given (percent-encoded where it must be), so one that is not its pattern's is the policy's to refuse.
    public func url(query: [URLQueryItem] = [], id: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path.replacingOccurrences(of: "{id}", with: id ?? "")
        if !query.isEmpty { components.queryItems = query }
        return components.url ?? URL(string: "https://\(host)/")!
    }

    /// `candidate` (percent-encoded, as sent) is this endpoint's path: the same segments, and the id's segment exactly of
    /// its pattern.
    public func matches(path candidate: String) -> Bool {
        guard idPattern != nil else { return candidate == path }
        let want = path.split(separator: "/", omittingEmptySubsequences: false)
        let have = candidate.split(separator: "/", omittingEmptySubsequences: false)
        guard want.count == have.count else { return false }
        return zip(want, have).allSatisfy { expected, given in expected == "{id}" ? accepts(id: String(given)) : expected == given }
    }

    /// Whether `id` may stand in this endpoint's path.
    public func accepts(id: String) -> Bool {
        guard let idPattern else { return false }
        return id.range(of: "^" + idPattern + "$", options: .regularExpression) != nil
    }

    /// An id as the owner may paste it, as the path would take it: trimmed and lower-cased, and for Fireworks without
    /// the `accounts/` its console and `firectl` write before it. What is left must still be the pattern's one segment.
    public func normalizedID(_ text: String) -> String {
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "accounts/"
        return self == .fireworksBillingSummary && id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }
}

extension MoneySource {
    /// The endpoint whose path carries the source's id (`accountIDName`); nil for a source with none.
    public var idEndpoint: MoneyEndpoint? {
        switch self {
        case .xAI: .xAIPrepaidBalance
        case .fireworks: .fireworksBillingSummary
        default: nil
        }
    }

    /// The id Settings › Money keeps for `text` (`MoneyEndpoint.normalizedID`), or nil when it is not one of the
    /// source's pattern: a typo, another kind of id, a key pasted in the wrong field.
    public func acceptedID(_ text: String) -> String? {
        guard let endpoint = idEndpoint else { return nil }
        let id = endpoint.normalizedID(text)
        return endpoint.accepts(id: id) ? id : nil
    }

    /// Settings › Money's word for text that is not such an id: `Not a team ID`, `Not an account ID`.
    public var notAnIDWord: String? {
        guard let name = accountIDName, let first = name.first else { return nil }
        let lower = first.lowercased() + name.dropFirst()
        return ("aeiou".contains(first.lowercased()) ? "Not an " : "Not a ") + lower
    }
}

public enum MoneyHostPolicy {
    public static let anthropicHost = "api.anthropic.com"
    public static let anthropicVersion = "2023-06-01"
    static let adminKeyPrefix = "sk-ant-admin"
    static let claudeTokenPrefixes = ["sk-ant-oat", "sk-ant-ort"]
    static let anthropicKeyPrefix = "sk-ant-"
    static let forbiddenHost = "chatgpt.com"
    /// Every money request's User-Agent starts with this (`MoneyHTTPClient.userAgent`; tests add their own suffix).
    static let appAgentPrefix = "JuiceIsland"
    static let forbiddenPathParts = ["/api/oauth/", "/backend-api/", "oauth/usage", "wham/usage"]
    /// A key found in the request's URL, body or another header is refused from this length on, so a short value never
    /// matches ordinary text by chance.
    static let keyEchoMinimum = 8

    public struct Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        public var reason: String
        public var description: String { reason }
    }

    /// A JSON Web Token anywhere in `value` (`eyJ…` then two more dot-separated parts): the shape of a ChatGPT or Codex
    /// sign-in token. No money source's key has it, so a value shaped like one is never sent, and never saved as a key.
    static func carriesSignInToken(_ value: String) -> Bool {
        value.range(of: #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\."#, options: .regularExpression) != nil
    }

    /// A query name that could carry a key (P143): `api_key` (Vast.ai documents one), `key`, `access_token`, `auth`, a
    /// secret, a password or a signature. Vast.ai's `after_token` is a page cursor, the one `token` name allowed.
    static func keyLikeQuery(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "after_token" { return false }
        return ["key", "token", "auth", "secret", "password", "signature"].contains { lower.contains($0) }
    }

    /// The endpoint a URL is, when it is exactly one of the allowed ones.
    public static func endpoint(host: String, path: String) -> MoneyEndpoint? {
        MoneyEndpoint.allCases.first { $0.host == host && $0.matches(path: path) }
    }

    /// nil when `request` may go out exactly as it is; the reason otherwise. Checked on the final request, right before
    /// it is handed to the network (a redirect is never followed, so nothing else goes out).
    public static func check(_ request: URLRequest) -> Refusal? {
        func refuse(_ reason: String) -> Refusal { Refusal(reason: reason) }
        guard let url = request.url?.absoluteURL, let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return refuse("no URL")
        }
        let host = components.percentEncodedHost ?? ""
        let lowerHost = host.lowercased()
        let trimmedHost = lowerHost.hasSuffix(".") ? String(lowerHost.dropLast()) : lowerHost
        // chatgpt.com and its subdomains, in any case, with or without the trailing dot: never.
        if trimmedHost == forbiddenHost || trimmedHost.hasSuffix("." + forbiddenHost) { return refuse("forbidden host") }
        let path = components.percentEncodedPath
        let lowerPath = path.lowercased()
        let decodedPath = (path.removingPercentEncoding ?? path).lowercased()
        if forbiddenPathParts.contains(where: { lowerPath.contains($0) || decodedPath.contains($0) }) {
            return refuse("forbidden path")
        }
        guard components.scheme == "https" else { return refuse("not https") }
        guard components.user == nil, components.password == nil else { return refuse("user info in the URL") }
        guard components.port == nil else { return refuse("a port in the URL") }
        guard components.fragment == nil else { return refuse("fragment") }
        let method = request.httpMethod ?? "GET"
        if trimmedHost == anthropicHost, method != "GET" { return refuse("only GET on this host") }
        guard let endpoint = endpoint(host: host, path: path) else { return refuse("not an allowed request") }
        guard method == endpoint.method else { return refuse("method not allowed") }
        let names = (components.percentEncodedQueryItems ?? []).map(\.name)
        if components.percentEncodedQuery != nil, names.isEmpty { return refuse("query not allowed") }
        guard names.allSatisfy(endpoint.allowedQuery.contains), !names.contains(where: keyLikeQuery) else {
            return refuse("query not allowed")
        }
        let body = request.httpBody ?? Data()
        if !body.isEmpty, !endpoint.allowsBody { return refuse("body not allowed") }
        if request.httpBodyStream != nil { return refuse("body stream not allowed") }

        let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value }
        guard headers.keys.allSatisfy(endpoint.allowedHeaders.contains) else { return refuse("header not allowed") }
        if headers["cookie"] != nil { return refuse("cookie") }
        if request.httpShouldHandleCookies { return refuse("cookies not disabled") }
        // The app's own User-Agent (`JuiceIsland/…`), never one resembling claude-code.
        guard let agent = headers["user-agent"], agent.hasPrefix(appAgentPrefix), !agent.lowercased().contains("claude") else {
            return refuse("user agent")
        }

        // Claude credentials: a Claude OAuth token goes nowhere; any sk-ant- value goes only to Anthropic's cost report,
        // and there only in `x-api-key` (checked by header name, so a copy of the key in another header is refused).
        let urlPlaces = [url.absoluteString, url.absoluteString.removingPercentEncoding ?? "", String(decoding: body, as: UTF8.self)]
        let places = Array(headers.values) + urlPlaces
        if places.contains(where: { value in claudeTokenPrefixes.contains { value.contains($0) } }) {
            return refuse("Claude token")
        }
        if places.contains(where: carriesSignInToken) { return refuse("sign-in token") }
        if endpoint == .anthropicCostReport {
            guard headers["authorization"] == nil else { return refuse("authorization header") }
            guard headers["anthropic-version"] == anthropicVersion else { return refuse("anthropic-version") }
            guard let key = headers["x-api-key"], key.hasPrefix(adminKeyPrefix) else { return refuse("not an admin key") }
            let elsewhere = headers.filter { $0.key != "x-api-key" }.map(\.value) + urlPlaces
            if elsewhere.contains(where: { $0.contains(anthropicKeyPrefix) }) { return refuse("key outside x-api-key") }
            guard headers.keys.sorted() == endpoint.allowedHeaders.sorted() else { return refuse("headers") }
            return nil
        }
        if places.contains(where: { $0.contains(anthropicKeyPrefix) }) { return refuse("Anthropic key to another host") }
        // Every other endpoint: the key in its one place, shaped as that place's (`Bearer …`, `Key …`, or alone in its own
        // header), and nowhere else: not in the URL, the body or another header (P143).
        let placement = endpoint.keyPlacement
        guard let value = headers[placement.headerName], let key = placement.key(in: value), !key.contains(" ") else {
            return refuse(placement == .bearer ? "no bearer key" : "no key in \(placement.headerName)")
        }
        if key.count >= keyEchoMinimum {
            let elsewhere = headers.filter { $0.key != placement.headerName }.map(\.value) + urlPlaces
            if elsewhere.contains(where: { $0.contains(key) }) { return refuse("key outside \(placement.headerName)") }
        }
        return nil
    }
}
