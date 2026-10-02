import Foundation
import Testing
@testable import JuiceCore

/// The only network money tests ever reach: a `URLProtocol` that answers from a test's own routes and fails every
/// request it was not given. Each test gets its own `MoneyStubServer`, found by the client's unique User-Agent, so
/// tests stay independent while they run in parallel. Nothing leaves the process.
final class MoneyStubServer: @unchecked Sendable {
    struct Route {
        var method: String
        var host: String
        var path: String
        var status: Int
        var body: Data
        var headers: [String: String]
        /// Answer this route with a redirect to this URL instead.
        var redirect: URL?
        /// Match only a request whose query contains this.
        var query: String?
    }

    private let lock = NSLock()
    private var routes: [Route] = []
    private var _received: [URLRequest] = []
    private var _unexpected: [String] = []
    let agent = "JuiceIsland-test-\(UUID().uuidString)"

    init() { MoneyStubRegistry.register(self) }
    deinit { MoneyStubRegistry.unregister(agent) }

    /// A client whose every request lands here.
    func client(clock: @escaping @Sendable () -> Date = { Date() }) -> MoneyHTTPClient {
        MoneyHTTPClient(protocolClasses: [MoneyStubProtocol.self], userAgent: agent, clock: clock)
    }

    func on(_ method: String = "GET", _ host: String, _ path: String, status: Int = 200, json: String = "{}",
            headers: [String: String] = [:], redirect: URL? = nil, query: String? = nil) {
        lock.withLock {
            routes.append(Route(method: method, host: host, path: path, status: status, body: Data(json.utf8), headers: headers,
                                redirect: redirect, query: query))
        }
    }

    func on(_ endpoint: MoneyEndpoint, status: Int = 200, json: String = "{}", headers: [String: String] = [:], query: String? = nil) {
        on(endpoint.method, endpoint.host, endpoint.path, status: status, json: json, headers: headers, query: query)
    }

    func on(_ endpoint: MoneyEndpoint, fixture name: String, query: String? = nil) throws {
        on(endpoint, json: String(decoding: try moneyFixture(name), as: UTF8.self), query: query)
    }

    /// Requests that reached the stub for `endpoint`.
    func count(_ endpoint: MoneyEndpoint) -> Int {
        received.filter { $0.url?.host() == endpoint.host && $0.url?.path() == endpoint.path }.count
    }

    var received: [URLRequest] { lock.withLock { _received } }
    var unexpected: [String] { lock.withLock { _unexpected } }

    func route(for request: URLRequest) -> Route? {
        lock.withLock {
            _received.append(request)
            let method = request.httpMethod ?? "GET"
            let host = request.url?.host() ?? ""
            let path = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
            let query = request.url?.query(percentEncoded: false) ?? ""
            // The last matching route wins, so a test can change an answer between reads.
            if let route = routes.last(where: { $0.method == method && $0.host == host && $0.path == path
                && ($0.query.map { query.contains($0) } ?? true) }) { return route }
            _unexpected.append("\(method) \(host)\(path)")
            return nil
        }
    }
}

enum MoneyStubRegistry {
    nonisolated(unsafe) private static var servers: [String: MoneyStubServer] = [:]
    private static let lock = NSLock()

    static func register(_ server: MoneyStubServer) { lock.withLock { servers[server.agent] = server } }
    static func unregister(_ agent: String) { _ = lock.withLock { servers.removeValue(forKey: agent) } }
    static func server(_ agent: String?) -> MoneyStubServer? { lock.withLock { agent.flatMap { servers[$0] } } }
}

final class MoneyStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let server = MoneyStubRegistry.server(request.value(forHTTPHeaderField: "User-Agent"))
        guard let server, let route = server.route(for: request), let url = request.url else {
            if server == nil { Issue.record("a money request reached the stub with no test server") }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if let target = route.redirect {
            let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: route.body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: route.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

func moneyFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/money"))
    return try Data(contentsOf: url)
}

/// A temporary folder removed at the end of the test's scope.
final class MoneyTempDir: @unchecked Sendable {
    let url: URL
    var path: String { url.path }

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        url = base.appendingPathComponent("money-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes `text` at `relative` (folders created) and returns the full path.
    @discardableResult
    func write(_ relative: String, _ text: String) throws -> String {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file.path
    }

    func fence(accountFolders: [String] = []) -> MoneyKeyFileGuard {
        MoneyKeyFileGuard(home: path, accountFolders: accountFolders)
    }
}

/// Fake keys only; none of them is real.
enum FakeKeys {
    static let openRouter = "sk-or-v1-" + String(repeating: "0", count: 64)
    static let anthropicAdmin = "sk-ant-admin01-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE-0000000000AA"
    static let anthropicAPI = "sk-ant-api03-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE-0000000000AA"
    static let claudeOAuth = "sk-ant-oat01-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE-0000000000AA"
    static let claudeRefresh = "sk-ant-ort01-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE-0000000000AA"
    static let openAIAdmin = "sk-admin-FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
    static let runPod = "rpa_FAKEFAKEFAKEFAKEFAKEFAKEFAKEFAKE"
    static let hetzner = "FAKEhetznerTOKEN0000000000000000000000000000000000000000000000"
    /// Shaped like a ChatGPT or Codex sign-in token (a JWT); its parts are fake.
    static let signInJWT = "eyJhbGciOiJGQUtFIn0.eyJGQUtFIjoiRkFLRSJ9.RkFLRUZBS0VGQUtFRkFLRQ"
}
