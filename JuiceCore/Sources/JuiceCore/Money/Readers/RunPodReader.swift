import Foundation

/// RunPod's balance and burn, behind an interface: the GraphQL API is deprecated and retires in early 2027 with no
/// REST v2 balance yet (Juice spec §8.1), so a replacement only swaps this.
public protocol RunPodBalanceAPI: Sendable {
    func figures(key: MoneyKey, client: MoneyHTTPClient) async throws -> RunPodFigures
}

/// `POST /graphql` with `myself { clientBalance currentSpendPerHr spendLimit pods { … } }`, the key as a bearer token
/// (never in the URL).
public struct RunPodGraphQLAPI: RunPodBalanceAPI {
    public static let query = "query { myself { clientBalance currentSpendPerHr spendLimit pods { name costPerHr desiredStatus machine { gpuDisplayName } } } }"

    public init() {}

    public func figures(key: MoneyKey, client: MoneyHTTPClient) async throws -> RunPodFigures {
        let body = try JSONSerialization.data(withJSONObject: ["query": Self.query], options: [.sortedKeys])
        return try Self.parse(try await client.send(MoneyRequest(.runPodGraphQL, key: key, body: body)).ok())
    }

    struct Answer: Decodable {
        struct Payload: Decodable {
            struct Myself: Decodable {
                struct Pod: Decodable {
                    struct Machine: Decodable { var gpuDisplayName: String? }
                    var name: String?
                    var costPerHr: MoneyJSON.Number?
                    var desiredStatus: String?
                    var machine: Machine?
                }
                var clientBalance: MoneyJSON.Number?
                var currentSpendPerHr: MoneyJSON.Number?
                var spendLimit: MoneyJSON.Number?
                var pods: [Pod]?
            }
            var myself: Myself?
        }
        struct Problem: Decodable { var message: String? }
        var data: Payload?
        var errors: [Problem]?
    }

    static func parse(_ data: Data) throws -> RunPodFigures {
        let answer = try MoneyJSON.decode(Answer.self, data, "RunPod")
        guard let myself = answer.data?.myself, let balance = myself.clientBalance?.value else {
            let text = (answer.errors ?? []).compactMap(\.message).joined(separator: " ").lowercased()
            if text.contains("unauthorized") || text.contains("authenticat") || text.contains("api key") {
                throw MoneyReadError.notAvailableWithThisKey
            }
            throw MoneyReadError.unreadableResponse("RunPod")
        }
        let pods = (myself.pods ?? []).map { pod in
            RunPodFigures.Pod(name: pod.name ?? "pod", costPerHour: pod.costPerHr?.value ?? 0,
                              running: (pod.desiredStatus ?? "").uppercased() == "RUNNING", gpu: pod.machine?.gpuDisplayName)
        }
        return RunPodFigures(balance: balance, burnPerHour: myself.currentSpendPerHr?.value, spendLimit: myself.spendLimit?.value,
                             pods: pods)
    }
}

public struct RunPodReader: MoneyReader {
    public let source = MoneySource.runPod
    let api: any RunPodBalanceAPI

    public init(api: any RunPodBalanceAPI = RunPodGraphQLAPI()) { self.api = api }

    public func read(key: MoneyKey, context: MoneyReadContext, client: MoneyHTTPClient) async throws -> MoneyReading {
        MoneyReading(source: source, readAt: context.now, figures: .balance(try await api.figures(key: key, client: client).kind))
    }

    /// Each read stands alone: nothing is kept.
    public func forget() async {}
}
