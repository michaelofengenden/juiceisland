import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Which usage model runs (spec §5.3, §8 decision 10): only the release identity reads accounts itself. The live model
/// is never made in the dev identity or in tests.
@MainActor
struct UsageModelChoiceTests {
    @Test
    func identityComesFromTheBundleID() {
        #expect(AppIdentity(bundleIdentifier: "com.ofengenden.juice") == .production)
        #expect(AppIdentity(bundleIdentifier: "com.ofengenden.juice.dev") == .development)
        for other in [nil, "", "com.apple.dt.xctest.tool", "com.ofengenden.juice.devx", "com.ofengenden.juice.dev.tests", "com.ofengenden"] {
            #expect(AppIdentity(bundleIdentifier: other) == .other, "\(other ?? "nil")")
        }
        // This test process is never the release build.
        #expect(AppIdentity.current != .production)
    }

    @Test
    func onlyTheReleaseIdentityReadsItself() {
        #expect(UsageModelKind.choose(identity: .production, source: .juiceReadings) == .live)
        #expect(UsageModelKind.choose(identity: .production, source: .demo) == .demo)
        #expect(UsageModelKind.choose(identity: .development, source: .juiceReadings) == .juiceReadings)
        #expect(UsageModelKind.choose(identity: .development, source: .demo) == .demo)
        #expect(UsageModelKind.choose(identity: .other, source: .juiceReadings) == .juiceReadings)
        #expect(UsageModelKind.choose(identity: .other, source: .demo) == .demo)
        #expect(UsageSource.juiceReadings.title(in: .production) == "Live")
        #expect(UsageSource.juiceReadings.title(in: .development) == UsageSource.juiceReadings.title)
    }

    @Test
    func theAppEnvironmentNeverMakesTheLiveModelOutsideTheReleaseIdentity() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        for identity in [AppIdentity.current, .development, .other] {
            let settings = AppSettings.ephemeral()
            settings.usageSource = .juiceReadings
            let env = AppEnvironment.app(settings: settings, juiceDirectory: fakes.directory, identity: identity,
                                         live: { Issue.record("live model made in \(identity)"); return fakes.model() })
            #expect(env.usage is JuiceReadingsUsageModel)
            settings.usageSource = .demo
            for _ in 0..<100 where !(env.usage is DemoUsageModel) { try await Task.sleep(for: .milliseconds(10)) }
            #expect(env.usage is DemoUsageModel)
        }
        // The default identity is this process's own: still the read-only mirror.
        let settings = AppSettings.ephemeral()
        settings.usageSource = .juiceReadings
        #expect(AppEnvironment.app(settings: settings, juiceDirectory: fakes.directory).usage is JuiceReadingsUsageModel)
        #expect(fakes.entries.isEmpty)
    }

    @Test
    func theReleaseIdentityStartsTheLiveModelAndStopsItOnASwitch() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [LiveFakes.work])
        let settings = AppSettings.ephemeral()
        settings.usageSource = .juiceReadings
        let env = AppEnvironment.app(settings: settings, juiceDirectory: fakes.directory, identity: .production, live: { fakes.model() })
        let live = try #require(env.usage as? LiveUsageModel)
        #expect(live.phase == .reading)
        await live.settle()
        #expect(fakes.reads == ["read \(LiveFakes.work.id)"])
        settings.usageSource = .demo
        for _ in 0..<100 where !(env.usage is DemoUsageModel) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(env.usage is DemoUsageModel)
        #expect(live.phase == .idle && !live.scheduler.isRunning)
    }
}

/// The single-reader guard (spec §5.3, P69): another reader is any other process with Juice's bundle id or a `Juice.app`
/// bundle, a second instance of this app included.
@MainActor
struct StandaloneJuiceGuardTests {
    let own = URL(fileURLWithPath: "/Applications/Juice Island.app")

    func guardWith(_ apps: [RunningAppInfo]) -> StandaloneJuiceGuard {
        StandaloneJuiceGuard(ownProcessIdentifier: 100, runningApps: { apps })
    }

    @Test
    func findsStandaloneJuiceByBundleIDOrBundleName() {
        let byID = RunningAppInfo(processIdentifier: 7, bundleIdentifier: "com.ofengenden.juice", bundleURL: URL(fileURLWithPath: "/Users/person1/Apps/Charge.app"))
        let byName = RunningAppInfo(processIdentifier: 8, bundleIdentifier: "com.example.other", bundleURL: URL(fileURLWithPath: "/Applications/Juice.app"))
        let byNameSlash = RunningAppInfo(processIdentifier: 9, bundleIdentifier: nil, bundleURL: URL(fileURLWithPath: "/Applications/Juice.app/"))
        for app in [byID, byName, byNameSlash] {
            #expect(guardWith([app]).standaloneJuiceIsRunning(), "\(app)")
        }
    }

    @Test
    func neverCountsItselfOrOtherApps() {
        // The release build shares Juice's bundle id: its own process is not "the other Juice".
        let me = RunningAppInfo(processIdentifier: 100, bundleIdentifier: "com.ofengenden.juice", bundleURL: own)
        let dev = RunningAppInfo(processIdentifier: 102, bundleIdentifier: "com.ofengenden.juice.dev",
                                 bundleURL: URL(fileURLWithPath: "/Users/person1/output/app.noindex/Juice Island Dev.app"))
        let others = [RunningAppInfo(processIdentifier: 103, bundleIdentifier: "com.apple.finder", bundleURL: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")),
                      RunningAppInfo(processIdentifier: 104, bundleIdentifier: nil, bundleURL: URL(fileURLWithPath: "/Applications/Juicer.app")),
                      RunningAppInfo(processIdentifier: 105, bundleIdentifier: nil, bundleURL: nil)]
        #expect(!guardWith([me, dev] + others).standaloneJuiceIsRunning())
    }

    /// A second instance of this app (the same bundle, another process) reads too: it counts, so the two never read
    /// at once (each waits until the other quits).
    @Test
    func aSecondInstanceOfThisAppCounts() {
        let me = RunningAppInfo(processIdentifier: 100, bundleIdentifier: "com.ofengenden.juice", bundleURL: own)
        let again = RunningAppInfo(processIdentifier: 101, bundleIdentifier: "com.ofengenden.juice", bundleURL: own)
        #expect(guardWith([me, again]).standaloneJuiceIsRunning())
    }

    @Test
    func aJustTerminatedJuiceCanBeLeftOut() {
        let juice = LiveFakes.juiceApp
        #expect(guardWith([juice]).standaloneJuiceIsRunning())
        #expect(!guardWith([juice]).standaloneJuiceIsRunning(excluding: [juice.processIdentifier]))
    }
}
