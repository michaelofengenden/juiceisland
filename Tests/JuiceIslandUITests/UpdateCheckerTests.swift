import Foundation
import Testing
@testable import JuiceIslandUI

/// A git that answers from a table; no repository is touched.
private final class FakeGit: GitRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let answer: @Sendable ([String]) -> GitOutput

    init(_ answer: @escaping @Sendable ([String]) -> GitOutput) { self.answer = answer }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitOutput {
        lock.withLock { recorded.append(arguments) }
        guard arguments.count > 2, arguments[0] == "-C" else { return .failure("fatal: no -C") }
        return answer(Array(arguments.dropFirst(2)))
    }
}

/// The checker over a fake git: up to date, newer commits with subjects, a failing fetch (no fallback), not a
/// repository, a dirty stamp, a build off origin/main, an unknown build; and it only ever reads (plus the fetch). Then
/// over real repositories in a temporary folder: only `<build>..origin/main` counts, never a commit that is only local.
@MainActor
struct UpdateCheckerTests {
    nonisolated static let repo = "/tmp/ji-update-fake-repo"
    nonisolated static let build = String(repeating: "a", count: 40)
    nonisolated static let origin = String(repeating: "c", count: 40)
    nonisolated static let checkedAt = Date(timeIntervalSince1970: 1_790_000_000)  // 14:13 UTC
    nonisolated static let utc = TimeZone(identifier: "UTC")!

    private static func stamp(_ commit: String = build, dirty: Bool = false, repo: String = repo) -> BuildStamp {
        BuildStamp(info: [BuildStamp.Key.commit: commit + (dirty ? "-dirty" : ""), BuildStamp.Key.date: "2026-09-24T12:05:00Z",
                          BuildStamp.Key.repo: repo])
    }

    /// A repository whose origin/main is `origin` once the fetch works, which counts `newer` commits past the build,
    /// and whose origin/main has the build in its history unless `offMain`.
    private static func repository(origin: String = origin, fetches: Bool = true, newer: Int = 0, offMain: Bool = false,
                                    subjects: [String] = []) -> FakeGit {
        FakeGit { arguments in
            switch arguments {
            case ["rev-parse", "--git-dir"]: return .success(".git\n")
            case ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"]: return .success(origin + "\n")
            case UpdateChecker.fetch:
                return fetches ? .success() : .failure("fatal: unable to access 'https://example.invalid/': Could not resolve host")
            default: break
            }
            if arguments.first == "cat-file" { return arguments == ["cat-file", "-e", "\(build)^{commit}"] ? .success() : .failure("bad") }
            if arguments.first == "merge-base" { return offMain ? .failure("", status: 1) : .success() }
            if arguments.starts(with: ["rev-list", "--count"]) { return .success("\(newer)\n") }
            if arguments.starts(with: ["log", "--format=%s", "-n", "10"]) {
                return .success(subjects.prefix(10).joined(separator: "\n") + "\n")
            }
            return .failure("fatal: unexpected \(arguments)")
        }
    }

    private func check(_ stamp: BuildStamp, _ git: any GitRunning) async -> UpdateChecker {
        let checker = UpdateChecker(stamp: stamp, git: git, now: { Self.checkedAt })
        await checker.check()
        return checker
    }

    @Test func upToDateWithOriginMain() async {
        let git = Self.repository(origin: Self.build)
        let checker = await check(Self.stamp(), git)
        #expect(checker.state == .checked(UpdateInfo(newer: 0, subjects: [], tip: Self.build), at: Self.checkedAt))
        #expect(checker.available == nil)
        #expect(UpdateText.status(checker.state, timeZone: Self.utc) == "Up to date · checked 14:13")
        #expect(!git.calls.contains { $0.contains("log") })
    }

    @Test func newerCommitsCountOnlyOriginMainAndKeepTheirSubjects() async throws {
        let subjects = (1...12).map { "Fix number \($0)" }
        let git = Self.repository(newer: 12, subjects: subjects)
        let checker = await check(Self.stamp(), git)
        let info = try #require(checker.available)
        #expect(info.newer == 12 && !info.offMain)
        #expect(info.subjects == Array(subjects.prefix(10)))
        let count = try #require(git.calls.first { $0.contains("rev-list") })
        #expect(Array(count.dropFirst(2)) == ["rev-list", "--count", Self.origin, "^\(Self.build)"])
        let log = try #require(git.calls.first { $0.contains("log") })
        #expect(Array(log.dropFirst(2)) == ["log", "--format=%s", "-n", "10", Self.origin, "^\(Self.build)"])
        // The local main (or HEAD) is never asked; only the fetch names origin's own main.
        let reads = git.calls.map { Array($0.dropFirst(2)) }.filter { $0 != UpdateChecker.fetch }
        #expect(!reads.contains { $0.contains { $0.contains("refs/heads") || $0 == "main" || $0 == "HEAD" } })
        // The count has its own row in About; the status line says only when.
        #expect(UpdateText.status(checker.state, timeZone: Self.utc) == "Checked 14:13")
        #expect(UpdateText.offer(info) == "12 changes" && UpdateText.toolbarHelp(info) == "12 changes · click to update")
    }

    /// The fetch comes first, and when it fails nothing is counted: no fallback to the local main.
    @Test func aFailingFetchIsCantReachGitHubWithNoCount() async {
        let git = Self.repository(fetches: false, newer: 3, subjects: ["Local only"])
        let checker = await check(Self.stamp(), git)
        #expect(checker.state == .failed("Can't reach GitHub", at: Self.checkedAt))
        #expect(checker.available == nil)
        #expect(Array(git.calls.map { Array($0.dropFirst(2)) }) == [["rev-parse", "--git-dir"], UpdateChecker.fetch])
        #expect(UpdateText.status(checker.state, timeZone: Self.utc) == "Can't reach GitHub · checked 14:13")
    }

    /// A ref lock a git stopped mid-fetch left in the repository fails every fetch until it is deleted: the check names
    /// it instead of blaming GitHub; one that is gone by then (another fetch at the same moment) is no such lock.
    @Test func aLeftOverRefLockIsNamed() {
        let home = "/tmp/juice-test-home"
        let lock = home + "/Developer/repo/.git/refs/remotes/origin/main.lock"
        let stderr = "error: cannot lock ref 'refs/remotes/origin/main': Unable to create '\(lock)': File exists.\n\nAnother git process"
        #expect(UpdateChecker.fetchFailure(stderr, exists: { $0 == lock }, home: home)
            == "Git's lock ~/Developer/repo/.git/refs/remotes/origin/main.lock is left over; delete it")
        #expect(UpdateChecker.fetchFailure(stderr, exists: { _ in false }, home: home) == "Can't reach GitHub")
        #expect(UpdateChecker.fetchFailure("fatal: Could not read from remote repository.", exists: { _ in true })
            == "Can't reach GitHub")
    }

    /// A prepare's fetch holding origin/main's lock at the moment of a check (P718): the check tries once more, and
    /// only a lock still there after that is named.
    @Test func aFetchThatMeetsALockTriesOnceMore() async throws {
        let lock = "/tmp/ji-update-fake-repo/.git/refs/remotes/origin/main.lock"
        final class Count: @unchecked Sendable { var fetches = 0 }
        let count = Count()
        let git = FakeGit { arguments in
            if arguments == UpdateChecker.fetch {
                count.fetches += 1
                if count.fetches == 1 { return .failure("error: cannot lock ref 'refs/remotes/origin/main': Unable to create '\(lock)': File exists.") }
                return .success()
            }
            switch arguments {
            case ["rev-parse", "--git-dir"]: return .success(".git\n")
            case ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"]: return .success(Self.build + "\n")
            default: return arguments.first == "cat-file" || arguments.first == "merge-base" ? .success() : .success("0\n")
            }
        }
        let result = await UpdateChecker.compare(stamp: Self.stamp(), git: git, retryDelay: .milliseconds(10))
        #expect(try result.get().newer == 0)
        #expect(git.calls.filter { $0.contains("fetch") }.count == 2)
        // Not a lock: no second try.
        let offline = FakeGit { arguments in
            arguments == ["rev-parse", "--git-dir"] ? .success(".git\n") : .failure("fatal: Could not read from remote repository.")
        }
        #expect(await UpdateChecker.compare(stamp: Self.stamp(), git: offline, retryDelay: .milliseconds(10))
            == .failure(UpdateChecker.Reason(text: UpdateChecker.unreachable)))
        #expect(offline.calls.filter { $0.contains("fetch") }.count == 1)
    }

    @Test func notARepositoryIsAShortReason() async {
        let git = FakeGit { _ in .failure("fatal: cannot change to '\(Self.repo)': No such file or directory") }
        let checker = await check(Self.stamp(), git)
        #expect(checker.state == .failed("No git repository at \(Self.repo)", at: Self.checkedAt))
        #expect(git.calls.count == 1)
        #expect(checker.available == nil)
    }

    @Test func gitMissingIsAShortReason() async {
        let checker = await check(Self.stamp(), FakeGit { _ in .notLaunched })
        #expect(checker.state == .failed("git not found", at: Self.checkedAt))
        #expect(UpdateText.status(checker.state, timeZone: Self.utc) == "git not found · checked 14:13")
    }

    @Test func aBuildCommitTheRepositoryLacksIsAShortReason() async {
        let other = String(repeating: "d", count: 40)
        let checker = await check(Self.stamp(other), Self.repository())
        #expect(checker.state == .failed("Build ddddddd is not in the repository", at: Self.checkedAt))
    }

    /// A dirty build of origin/main's commit, or a build off origin/main (another branch, unpushed commits) with
    /// nothing new on origin/main, is still offered origin/main.
    @Test func aDirtyOrOffMainBuildIsStillOfferedOriginMain() async throws {
        let stamp = Self.stamp(dirty: true)
        #expect(stamp.commit == Self.build && stamp.dirty)
        let git = Self.repository(origin: Self.build)
        let dirty = try #require(await check(stamp, git).available)
        let count = try #require(git.calls.first { $0.contains("rev-list") })
        #expect(count.last == "^\(Self.build)")
        #expect(dirty.dirty && dirty.newer == 0 && dirty.isAvailable)
        #expect(UpdateText.offer(dirty) == "Not built from origin/main")
        #expect(UpdateText.menuTitle(available: dirty, phase: .idle) == "Update Juice Island")
        #expect(stamp.aboutLine(timeZone: TimeZone(identifier: "UTC")!) == "Build aaaaaaa-dirty · 2026-09-24 12:05")

        let ahead = try #require(await check(Self.stamp(), Self.repository(offMain: true)).available)
        #expect(ahead.offMain && ahead.newer == 0 && UpdateText.offer(ahead) == "Not built from origin/main")
        let diverged = try #require(await check(Self.stamp(), Self.repository(newer: 2, offMain: true, subjects: ["A", "B"])).available)
        #expect(diverged.offMain && UpdateText.offer(diverged) == "2 changes")
    }

    /// While an update runs no check starts, so its fetch never takes origin/main's lock from the script's; Check
    /// now, the hourly timer and the recheck all go through `checkNow`.
    @Test func noCheckStartsWhileAnUpdateHoldsIt() async throws {
        let git = Self.repository(origin: Self.build)
        let checker = UpdateChecker(stamp: Self.stamp(), git: git, now: { Self.checkedAt })
        checker.holds = { true }
        #expect(checker.checkNow() == nil)
        #expect(checker.state == .idle && git.calls.isEmpty)
        checker.holds = { false }
        let started = try #require(checker.checkNow())
        // One check at a time: a second Check now while it runs starts nothing.
        #expect(checker.checkNow() == nil)
        await started.value
        #expect(checker.state == .checked(UpdateInfo(newer: 0, subjects: [], tip: Self.build), at: Self.checkedAt))
        #expect(git.calls.filter { $0.contains("fetch") }.count == 1)
    }

    @Test func anUnknownBuildNeverRunsGit() async {
        let git = Self.repository()
        let stamp = BuildStamp(info: [:])
        let checker = await check(stamp, git)
        #expect(stamp.aboutLine() == "unknown build")
        #expect(checker.state == .failed("Unknown build: no commit stamp to compare", at: Self.checkedAt))
        #expect(git.calls.isEmpty)
    }

    @Test func aCheckOnlyReadsTheRepository() async {
        let git = Self.repository(newer: 2, subjects: ["One", "Two"])
        _ = await check(Self.stamp(), git)
        let verbs = Set(git.calls.map { $0[2] })
        #expect(verbs.isSubset(of: ["rev-parse", "cat-file", "fetch", "rev-list", "merge-base", "log"]))
        #expect(git.calls.allSatisfy { $0[0] == "-C" && $0[1] == Self.repo })
    }

    // MARK: Real repositories

    /// A scratch origin (a bare repository), the owner's checkout cloned from it, and a second clone that pushes.
    private struct Repositories {
        let root: URL
        let runner: ProcessGitRunner
        var origin: URL { root.appendingPathComponent("origin.git") }
        var owner: URL { root.appendingPathComponent("owner") }
        var other: URL { root.appendingPathComponent("other") }

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var runner = ProcessGitRunner()
            runner.baseEnvironment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null",
                                      "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Check Test",
                                      "GIT_AUTHOR_EMAIL": "check-test@example.invalid", "GIT_COMMITTER_NAME": "Check Test",
                                      "GIT_COMMITTER_EMAIL": "check-test@example.invalid"]
            self.runner = runner
            try await git(["init", "--quiet", "--bare", "-b", "main", origin.path])
            try await git(["clone", "--quiet", origin.path, owner.path])
            try await commit(owner, "Base")
            try await git(["-C", owner.path, "push", "--quiet", "origin", "main"])
            try await git(["clone", "--quiet", origin.path, other.path])
        }

        @discardableResult func git(_ arguments: [String]) async throws -> String {
            let output = await runner.run(arguments, timeout: 20)
            guard output.ok else { throw GitFailure(arguments: arguments, stderr: output.stderr) }
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// A commit in <clone> that changes a file of its own, so no two commits conflict.
        func commit(_ clone: URL, _ subject: String) async throws {
            let file = clone.appendingPathComponent("\(subject.replacingOccurrences(of: " ", with: "-")).txt")
            try subject.write(to: file, atomically: true, encoding: .utf8)
            try await git(["-C", clone.path, "add", "."])
            try await git(["-C", clone.path, "commit", "--quiet", "-m", subject])
        }

        func head(_ clone: URL) async throws -> String { try await git(["-C", clone.path, "rev-parse", "HEAD"]) }

        /// The owner's checkout as git keeps it: HEAD, its branches, the index and FETCH_HEAD.
        func ownerState() async throws -> String {
            let dir = owner.appendingPathComponent(".git")
            let index = try Data(contentsOf: dir.appendingPathComponent("index"))
            let fetchHead = FileManager.default.contents(atPath: dir.appendingPathComponent("FETCH_HEAD").path)
            return try await git(["-C", owner.path, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"])
                + " " + index.base64EncodedString() + " " + (fetchHead?.base64EncodedString() ?? "no FETCH_HEAD")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private struct GitFailure: Error { let arguments: [String]; let stderr: String }

    /// The owner's screenshot: a local merge commit that was never pushed, with the branch it merged, on the checkout's
    /// main. Only the two commits pushed to origin count and show; after a failed fetch nothing counts at all.
    @Test func localOnlyCommitsNeverCountAndAFailedFetchCountsNothing() async throws {
        let repos = try await Repositories()
        defer { repos.remove() }
        let build = try await repos.head(repos.owner)
        try await repos.commit(repos.other, "Pushed one")
        try await repos.commit(repos.other, "Pushed two")
        try await repos.git(["-C", repos.other.path, "push", "--quiet", "origin", "main"])
        try await repos.git(["-C", repos.owner.path, "checkout", "--quiet", "-b", "side"])
        for subject in ["Side one", "Side two", "Side three"] { try await repos.commit(repos.owner, subject) }
        try await repos.git(["-C", repos.owner.path, "checkout", "--quiet", "main"])
        try await repos.commit(repos.owner, "Local one")
        try await repos.git(["-C", repos.owner.path, "merge", "--quiet", "--no-ff", "-m", "Merge side, never pushed", "side"])
        let before = try await repos.ownerState()

        let stamp = Self.stamp(build, repo: repos.owner.path)
        let checker = await check(stamp, repos.runner)
        let info = try #require(checker.available)
        let tip = try await repos.head(repos.other)
        #expect(info == UpdateInfo(newer: 2, subjects: ["Pushed two", "Pushed one"], tip: tip))
        #expect(try await repos.ownerState() == before)

        // A build from the local merge: off origin/main, and still offered origin/main's two commits.
        let merged = await check(Self.stamp(try await repos.head(repos.owner), repo: repos.owner.path), repos.runner)
        #expect(merged.available == UpdateInfo(newer: 2, subjects: ["Pushed two", "Pushed one"], offMain: true, tip: tip))

        try await repos.git(["-C", repos.owner.path, "remote", "set-url", "origin", repos.root.appendingPathComponent("gone.git").path])
        let offline = await check(stamp, repos.runner)
        #expect(offline.state == .failed("Can't reach GitHub", at: Self.checkedAt))
        #expect(offline.available == nil)
        #expect(try await repos.ownerState() == before)
    }

    /// origin/main force-moved to a history without the build: its commits count, and the build is off origin/main.
    @Test func aForceMovedOriginMainCountsItsOwnHistory() async throws {
        let repos = try await Repositories()
        defer { repos.remove() }
        try await repos.commit(repos.other, "Old")
        try await repos.git(["-C", repos.other.path, "push", "--quiet", "origin", "main"])
        try await repos.git(["-C", repos.owner.path, "pull", "--quiet", "--ff-only", "origin", "main"])
        let build = try await repos.head(repos.owner)
        try await repos.git(["-C", repos.other.path, "reset", "--quiet", "--hard", "HEAD~1"])
        try await repos.commit(repos.other, "Rewritten")
        try await repos.git(["-C", repos.other.path, "push", "--quiet", "--force", "origin", "main"])
        let info = try #require(await check(Self.stamp(build, repo: repos.owner.path), repos.runner).available)
        #expect(info == UpdateInfo(newer: 1, subjects: ["Rewritten"], offMain: true, tip: try await repos.head(repos.other)))
    }

    /// The real runner reads git's output and its status without any repository (`git --version`, then an unknown
    /// command), and says so when there is no git. The timeout only guards a hang (P293): a busy machine can take
    /// longer than 10 s to start Apple's git through its shim, and the runner then killed it.
    @Test func theProcessRunnerReadsOutputAndStatus() async throws {
        let runner = ProcessGitRunner()
        try #require(runner.executable != nil)
        let version = await runner.run(["--version"], timeout: 600)
        #expect(version.ok && version.firstLine.hasPrefix("git version"), "\(version)")
        let unknown = await runner.run(["no-such-command-ji"], timeout: 600)
        #expect(!unknown.ok && !unknown.launchFailed && unknown.stderr.contains("no-such-command-ji"), "\(unknown)")
        #expect(await ProcessGitRunner(executable: nil).run(["--version"], timeout: 10) == .notLaunched)
    }

    /// What git wrote before it exited is read whole even when the pipe's handlers did not run in time: the runner's
    /// drain takes what the pipe holds and never waits for more (P293).
    @Test func theDrainReadsWhatAPipeHoldsAndNeverWaits() throws {
        let pipe = Pipe()
        // Less than a pipe's first 16 KB, so the write never waits for a reader.
        let text = Data(String(repeating: "git version 2.54.0\n", count: 600).utf8)
        pipe.fileHandleForWriting.write(text)
        // The writer is still open: a drain that waited for the end would never return.
        #expect(ProcessGitRunner.drain(pipe.fileHandleForReading.fileDescriptor) == text)
        #expect(ProcessGitRunner.drain(pipe.fileHandleForReading.fileDescriptor).isEmpty)
        try pipe.fileHandleForWriting.close()
        #expect(ProcessGitRunner.drain(pipe.fileHandleForReading.fileDescriptor).isEmpty)
    }

    /// A pipe handler that runs after the drain (a busy Mac, P293) reads nothing and raises nothing: the drain ends the
    /// handlers' turn, what they read before it comes first, and a pipe with nothing yet never makes a handler wait.
    @Test func aLateHandlerReadsNothingAfterTheDrain() throws {
        let out = Pipe(), err = Pipe()
        let fds = [out.fileHandleForReading.fileDescriptor, err.fileHandleForReading.fileDescriptor]
        for fd in fds { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let collector = ProcessGitRunner.PipeCollector()
        #expect(collector.take(fds[0], stdout: true) == .data)
        out.fileHandleForWriting.write(Data("first\n".utf8))
        #expect(collector.take(fds[0], stdout: true) == .data)
        out.fileHandleForWriting.write(Data("second\n".utf8))
        err.fileHandleForWriting.write(Data("warning\n".utf8))
        collector.drain(out: fds[0], err: fds[1])
        out.fileHandleForWriting.write(Data("late\n".utf8))
        #expect(collector.take(fds[0], stdout: true) == .drained)
        #expect(collector.values == ("first\nsecond\n", "warning\n"))
        // A pipe's end, before any drain.
        let ended = Pipe()
        try ended.fileHandleForWriting.close()
        #expect(ProcessGitRunner.PipeCollector().take(ended.fileHandleForReading.fileDescriptor, stdout: true) == .end)
    }

    /// P117: the hourly check's fetch runs ssh in BatchMode, as update-app.sh does, so a locked key or an unknown host
    /// fails at once instead of waiting out the 45 s timeout or asking through a prompt; an ssh command the
    /// environment or git's config sets is kept.
    @Test func aFetchRunsSSHInBatchModeUnlessAnSSHCommandIsSet() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/tmp/ji-home"]
        let batch = ProcessGitRunner.environment(base, sshCommandConfigured: false)
        #expect(batch["GIT_SSH_COMMAND"] == "ssh -o BatchMode=yes" && batch["GIT_TERMINAL_PROMPT"] == "0" && batch["HOME"] == "/tmp/ji-home")
        #expect(ProcessGitRunner.environment(base, sshCommandConfigured: true)["GIT_SSH_COMMAND"] == nil)
        #expect(ProcessGitRunner.environment(base.merging(["GIT_SSH_COMMAND": "ssh -i k"]) { $1 }, sshCommandConfigured: false)["GIT_SSH_COMMAND"]
                == "ssh -i k")
        #expect(ProcessGitRunner.environment(base.merging(["GIT_SSH": "/bin/myssh"]) { $1 }, sshCommandConfigured: false)["GIT_SSH_COMMAND"] == nil)
        #expect(ProcessGitRunner.verb(of: ["-C", "/r", "-c", "a=b", "fetch", "--quiet"]) == "fetch")
        #expect(ProcessGitRunner.options(of: ["-C", "/r", "fetch", "--quiet", "origin"]) == ["-C", "/r"])
    }

    /// End to end with a stand-in `ssh` first on PATH and an ssh remote that names no real host: the fetch's ssh gets
    /// BatchMode, and a repository whose config sets `core.sshCommand` keeps its own. Nothing reaches the network.
    @Test func theRealFetchPassesBatchModeToSSH() async throws {
        let runner = ProcessGitRunner()
        let git = try #require(runner.executable)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ji-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("bin"), repo = dir.appendingPathComponent("repo"), log = dir.appendingPathComponent("ssh.log")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let ssh = bin.appendingPathComponent("ssh")
        try "#!/bin/sh\necho \"$*\" >> \"\(log.path)\"\nexit 1\n".write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        let base = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": dir.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        var testRunner = ProcessGitRunner(executable: git)
        testRunner.baseEnvironment = base
        for arguments in [["init", "--quiet"], ["remote", "add", "origin", "ssh://git@ji-test.invalid/repo.git"]] {
            #expect(await testRunner.run(["-C", repo.path] + arguments, timeout: 10).ok)
        }
        let fetch = await testRunner.run(["-C", repo.path, "fetch", "--quiet", "origin", "main"], timeout: 10)
        #expect(!fetch.ok)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("-o BatchMode=yes"))
        #expect(!ProcessGitRunner.sshCommandConfigured(git, options: ["-C", repo.path], base: base))

        // A repository that sets its own ssh command keeps it.
        try FileManager.default.removeItem(at: log)
        #expect(await testRunner.run(["-C", repo.path, "config", "core.sshCommand", "ssh -o ConnectTimeout=3"], timeout: 10).ok)
        #expect(ProcessGitRunner.sshCommandConfigured(git, options: ["-C", repo.path], base: base))
        _ = await testRunner.run(["-C", repo.path, "fetch", "--quiet", "origin", "main"], timeout: 10)
        let own = try String(contentsOf: log, encoding: .utf8)
        #expect(own.contains("-o ConnectTimeout=3") && !own.contains("BatchMode"))
    }

    // MARK: Build stamp

    @Test func theStampReadsItsKeysAndRefusesJunk() {
        let stamp = BuildStamp(info: [BuildStamp.Key.commit: "1A2B3C4D5E6F", BuildStamp.Key.date: "2026-09-24T09:30:00.250Z",
                                      BuildStamp.Key.repo: "/tmp/repo"])
        #expect(stamp.commit == "1a2b3c4d5e6f" && !stamp.dirty && stamp.repoPath == "/tmp/repo")
        #expect(stamp.aboutLine(timeZone: TimeZone(identifier: "UTC")!) == "Build 1a2b3c4 · 2026-09-24 09:30")
        #expect(BuildStamp(info: [BuildStamp.Key.commit: "not a commit"]).commit == nil)
        #expect(BuildStamp(info: [BuildStamp.Key.commit: "-dirty"]).dirty == false)
        #expect(BuildStamp(info: [BuildStamp.Key.repo: "relative/path"]).repoPath == nil)
        #expect(BuildStamp(info: [BuildStamp.Key.commit: Self.build]).aboutLine() == "Build aaaaaaa")
        #expect(UpdateChecker.abbreviate("/Users/x/Developer/juice-island", home: "/Users/x") == "~/Developer/juice-island")
        #expect(UpdateChecker.abbreviate("/Users/xy/repo", home: "/Users/x") == "/Users/xy/repo")
    }
}
