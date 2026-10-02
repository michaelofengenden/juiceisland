import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

private let claudeCommand = "'/x/OpenIslandHooks' --source claude"
private let codexCommand = "'/x/OpenIslandHooks'"

/// Upstream's own installer output, as a file a profile would hold.
private func installed(_ provider: Provider, userHook: Bool = false) throws -> Data {
    var existing: Data?
    if userHook {
        existing = Data(#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/audit"}]}]}}"#.utf8)
    }
    let mutation = provider == .claude
        ? try ClaudeHookInstaller.installSettingsJSON(existingData: existing, hookCommand: claudeCommand).contents
        : try CodexHookInstaller.installHooksJSON(existingData: existing, hookCommand: codexCommand).contents
    return try #require(mutation)
}

private func editing(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    var hooks = try #require(root["hooks"] as? [String: Any])
    change(&hooks)
    root["hooks"] = hooks
    return try JSONSerialization.data(withJSONObject: root)
}

private let work = ProfileHookTarget(provider: .claude, folder: "/Users/test/.claude-work", alias: "Work",
                                     isDefaultFolder: false, accountID: nil, isMonitored: true)

struct ExpectedHookEntriesDriftTests {
    private static func specs(in data: Data, command: String) throws -> Set<HookEntrySpec> {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
        var result: Set<HookEntrySpec> = []
        for (event, groups) in hooks {
            for group in groups {
                for hook in (group["hooks"] as? [[String: Any]]) ?? [] where hook["command"] as? String == command {
                    result.insert(HookEntrySpec(event: event, matcher: group["matcher"] as? String, timeout: hook["timeout"] as? Int))
                }
            }
        }
        return result
    }

    @Test
    func expectedEntriesMatchWhatUpstreamInstalls() throws {
        #expect(try Self.specs(in: installed(.claude), command: claudeCommand) == Set(ExpectedHookEntries.claude))
        #expect(try Self.specs(in: installed(.codex), command: codexCommand) == Set(ExpectedHookEntries.codex))
        #expect(ExpectedHookEntries.claude.map(\.event) == ClaudeHookEvents.all)
        #expect(Set(ExpectedHookEntries.codex.map(\.event)) == Set(CodexHookEvents.all))
    }
}

struct HookDriftTests {
    @Test
    func deletingOnlyPreToolUseReadsAsOneMissing() throws {
        let complete = try installed(.claude, userHook: true)
        #expect(HookDrift.read(fileData: complete, command: claudeCommand, expected: ExpectedHookEntries.claude) == .complete)

        let drifted = try editing(complete) { hooks in
            let groups = (hooks["PreToolUse"] as? [[String: Any]]) ?? []
            hooks["PreToolUse"] = groups.filter { group in
                !((group["hooks"] as? [[String: Any]]) ?? []).contains { $0["command"] as? String == claudeCommand }
            }
        }
        let missing = [HookEntrySpec(event: "PreToolUse", matcher: "*", timeout: nil)]
        let reading = HookDrift.read(fileData: drifted, command: claudeCommand, expected: ExpectedHookEntries.claude)
        #expect(reading == .drifted(missing: missing))
        #expect(HookDrift.alert(for: work, intent: .untouched, reading: reading)?.text == "Hooks missing in Work · Repair")
        #expect(HookDrift.alert(for: work, intent: .untouched, reading: reading)?.missing == missing)
    }

    @Test
    func aChangedTimeoutOrMatcherCountsAsMissing() throws {
        let complete = try installed(.codex)
        let changed = try editing(complete) { hooks in
            hooks["PermissionRequest"] = [["hooks": [["type": "command", "command": codexCommand, "timeout": 60]]]]
            hooks["SessionStart"] = [["matcher": "startup", "hooks": [["type": "command", "command": codexCommand, "timeout": 45]]]]
        }
        #expect(HookDrift.read(fileData: changed, command: codexCommand, expected: ExpectedHookEntries.codex)
                == .drifted(missing: [ExpectedHookEntries.codex[0], ExpectedHookEntries.codex[2]]))
    }

    @Test
    func anEmptyOrHalfWrittenFileIsBeingEditedAndRaisesNoAlert() throws {
        let complete = try installed(.claude)
        let halfWritten = complete.prefix(complete.count / 2)
        for data in [Data(), Data(halfWritten)] {
            let reading = HookDrift.read(fileData: data, command: claudeCommand, expected: ExpectedHookEntries.claude)
            #expect(reading == .beingEdited)
            #expect(HookDrift.alert(for: work, intent: .installed, reading: reading) == nil)
        }
    }

    @Test
    func noEntriesIsDriftOnlyWhereTheOwnerInstalled() throws {
        let userOnly = Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/local/bin/notify"}]}]}}"#.utf8)
        for data in [userOnly, nil] as [Data?] {
            let reading = HookDrift.read(fileData: data, command: claudeCommand, expected: ExpectedHookEntries.claude)
            #expect(reading == .notInstalled)
            #expect(HookDrift.alert(for: work, intent: .untouched, reading: reading) == nil)
            #expect(HookDrift.alert(for: work, intent: .removed, reading: reading) == nil)
            #expect(HookDrift.alert(for: work, intent: .installed, reading: reading)?.missing.count == 14)
        }
    }

    /// Truncated JSON, then valid JSON 500 ms later: one check, 2 s after the last event, sees the valid file.
    @Test
    func aCheckRunsOnceTwoSecondsAfterTheLastFileEvent() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var schedule = HookDriftSchedule()
        schedule.fileChanged(work.id, at: start)
        schedule.fileChanged(work.id, at: start.addingTimeInterval(0.5))
        schedule.fileChanged("codex:/Users/test/.codex-side", at: start.addingTimeInterval(0.2))
        #expect(schedule.takeDue(now: start.addingTimeInterval(1.9)) == [])
        #expect(schedule.takeDue(now: start.addingTimeInterval(2.3)) == ["codex:/Users/test/.codex-side"])
        #expect(schedule.takeDue(now: start.addingTimeInterval(2.4)) == [])
        #expect(schedule.takeDue(now: start.addingTimeInterval(2.5)) == [work.id])
        #expect(schedule.takeDue(now: start.addingTimeInterval(10)) == [])

        let valid = try installed(.claude)
        let reading = HookDrift.read(fileData: valid, command: claudeCommand, expected: ExpectedHookEntries.claude)
        #expect(HookDrift.alert(for: work, intent: .installed, reading: reading) == nil)
    }

    /// A profile hooked outside the app (a default one, hooked by Open Island) raises the row when every entry
    /// goes: the change from complete does, and so does the intent its first complete reading recorded.
    @Test
    func aProfileHookedOutsideTheAppAlertsWhenEveryEntryGoes() throws {
        let complete = try installed(.claude)
        let reading = HookDrift.read(fileData: complete, command: claudeCommand, expected: ExpectedHookEntries.claude)
        #expect(reading == .complete)
        #expect(HookDrift.recordedIntent(after: reading, intent: .untouched) == .installed)
        #expect(HookDrift.recordedIntent(after: .notInstalled, intent: .untouched) == .untouched)
        #expect(HookDrift.recordedIntent(after: .beingEdited, intent: .removed) == .removed)

        let wiped = try editing(complete) { $0 = [:] }
        let gone = HookDrift.read(fileData: wiped, command: claudeCommand, expected: ExpectedHookEntries.claude)
        #expect(gone == .notInstalled)
        #expect(HookDrift.alert(for: work, intent: .untouched, reading: gone, previous: .complete)?.missing.count == 14)
        #expect(HookDrift.alert(for: work, intent: .installed, reading: gone, previous: nil)?.text == "Hooks missing in Work · Repair")
        #expect(HookDrift.alert(for: work, intent: .untouched, reading: gone, previous: nil) == nil)
        // Right after the owner's own Remove.
        #expect(HookDrift.alert(for: work, intent: .removed, reading: gone, previous: .complete) == nil)
    }

    /// Setup's word reads the same set: a changed timeout makes an installed profile partial, 13 of 14.
    @Test
    func setupShowsDriftAsAPartialCount() throws {
        let changed = try editing(installed(.claude)) { hooks in
            hooks["PermissionRequest"] = [["matcher": "*", "hooks": [["type": "command", "command": claudeCommand, "timeout": 60]]]]
        }
        let reading = HookDrift.read(fileData: changed, command: claudeCommand, expected: ExpectedHookEntries.claude)
        #expect(reading == .drifted(missing: [HookEntrySpec(event: "PermissionRequest", matcher: "*", timeout: 86_400)]))
        func status(_ state: ProfileHookStatus.State) -> ProfileHookStatus {
            ProfileHookStatus(target: work, state: state, intent: .installed, managedEventCount: 14, expectedEventCount: 14,
                              vibeEntryCount: 0, otherHookCount: 0, helperMatchesBundle: true, codexFeatureEnabled: nil,
                              checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        }
        #expect(HookDrift.setupState(status(.installed), reading: reading) == .partial(installed: 13, expected: 14))
        #expect(HookDrift.setupState(status(.installed), reading: .complete) == .installed)
        #expect(HookDrift.setupState(status(.unreadable(file: "settings.json")), reading: reading) == .unreadable(file: "settings.json"))
    }
}
