import Foundation
import Testing
@testable import IslandEngine
import OpenIslandCore

struct HookEventListDriftTests {
    private static func eventNames(in data: Data?) throws -> Set<String> {
        let contents = try #require(data)
        let root = try JSONSerialization.jsonObject(with: contents) as? [String: Any]
        let hooks = try #require(root?["hooks"] as? [String: Any])
        return Set(hooks.keys)
    }

    @Test
    func claudeListMatchesWhatUpstreamInstalls() throws {
        let mutation = try ClaudeHookInstaller.installSettingsJSON(existingData: nil, hookCommand: "'/x/OpenIslandHooks' --source claude")
        #expect(try Self.eventNames(in: mutation.contents) == Set(ClaudeHookEvents.all))
    }

    @Test
    func codexListMatchesWhatUpstreamInstalls() throws {
        let mutation = try CodexHookInstaller.installHooksJSON(existingData: nil, hookCommand: "'/x/OpenIslandHooks'")
        #expect(try Self.eventNames(in: mutation.contents) == Set(CodexHookEvents.all))
    }
}

struct CodexTrustScannerTests {
    @Test
    func findsApprovedTablesWithoutReadingHashes() {
        let config = """
        model = "gpt-5"
        [hooks.state]

        [hooks.state."/Users/test/.codex-side/hooks.json:stop:0:0"]
        trusted_hash = "secret-value"

        [hooks.state."/Users/test/.codex-side/hooks.json:session_start:0:0"]
        # trusted_hash removed by hand

        [features]
        hooks = true
        """
        let trusted = CodexTrustScanner.trustedKeys(inConfig: config)
        #expect(trusted == ["/Users/test/.codex-side/hooks.json:stop:0:0"])
        #expect(!trusted.contains { $0.contains("secret-value") })
    }

    @Test
    func keysUseCodexSnakeCaseNames() {
        #expect(CodexTrustScanner.snakeCase("UserPromptSubmit") == "user_prompt_submit")
        #expect(CodexTrustScanner.key(hooksFile: "/h/.codex/hooks.json", event: "PermissionRequest", group: 1, hook: 0)
                == "/h/.codex/hooks.json:permission_request:1:0")
    }
}

struct CodexFeatureKeyTests {
    @Test
    func versionDecidesTheFeatureKey() {
        #expect(CodexFeatureKey.from(versionLine: "codex-cli 0.151.0") == .current)
        #expect(CodexFeatureKey.from(versionLine: "codex-cli 0.129.2") == .legacy)
        #expect(CodexFeatureKey.from(versionLine: "codex-cli 1.0.0") == .current)
        #expect(CodexFeatureKey.from(versionLine: nil) == .current)
        #expect(CodexFeatureKey.from(versionLine: "garbage") == .current)
    }
}

struct ProfileHookIntentStoreTests {
    @Test
    func intentsRoundTripPerProfile() throws {
        let suite = "ProfileHookIntentStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProfileHookIntentStore(defaults: defaults)
        #expect(store.intent(for: "claude:/h/.claude-work") == .untouched)
        store.setIntent(.installed, for: "claude:/h/.claude-work")
        store.setIntent(.removed, for: "codex:/h/.codex-side")
        #expect(store.intent(for: "claude:/h/.claude-work") == .installed)
        #expect(store.intent(for: "codex:/h/.codex-side") == .removed)
    }
}
