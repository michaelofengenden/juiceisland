import Foundation

public enum CLIEnvironment {
    /// The environment for launching a vendor CLI against one profile folder. Only PATH, HOME, USER, LANG, TMPDIR,
    /// TERM, the folder variable and any `extra` entries; nothing else from the app's environment leaks in.
    ///
    /// The folder variable (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`) is left unset when `folder` is the provider's
    /// default home (`~/.claude` / `~/.codex`): the CLI resolves its stored login differently once that variable
    /// is set at all, even to the path it would have used anyway, so setting it for the default profile makes the
    /// CLI report no account/no usage. Only non-default profile folders need the variable set explicitly.
    ///
    /// `USER` is required too: measured empirically (isolated `env -i` probes against the real `claude` binary,
    /// one variable at a time), a process with `HOME` set but no `USER` gets the same "no account" answer even
    /// with the folder variable unset — the CLI's credential/keychain lookup falls back to failure without it.
    /// This environment is a fresh allowlist, not inherited from the launching process, so `USER` is absent unless
    /// this function adds it explicitly, however the child happens to be launched. `USER` is the OS login name,
    /// not a secret, so carrying it through is safe under "never read/copy/log/store a token".
    ///
    /// `OPEN_ISLAND_SKIP_HOOKS` and `VIBE_ISLAND_SKIP` are always set, after `extra`, so no caller can drop them:
    /// island apps' hook helpers exit before doing anything when they see them (Open Island checks both,
    /// `HookSkipConfiguration`; Vibe Island's bridge checks `VIBE_ISLAND_SKIP`). A usage read, sign-in or identity
    /// check therefore never shows up as a session in an island or sets off an island's credential or usage path.
    /// They are not secrets and change nothing about the CLI's login.
    public static func make(provider: Provider, folder: String, extra: [String: String] = [:], basePATH: String? = nil) -> [String: String] {
        var env: [String: String] = [
            "PATH": basePATH ?? ToolLocator.loginShellPATH(),
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "TMPDIR": NSTemporaryDirectory(),
            "TERM": "dumb",
        ]
        if !isDefaultFolder(folder, for: provider) {
            env[provider.folderEnvironmentKey] = normalizedPath(folder)
        }
        for (key, value) in extra { env[key] = value }
        for key in islandSkipKeys { env[key] = "1" }
        return env
    }

    /// Whether `folder` is the provider's default home under `home` (`~/.claude` / `~/.codex`), the one `make` launches
    /// without the folder variable.
    public static func isDefaultFolder(_ folder: String, for provider: Provider, home: String = NSHomeDirectory()) -> Bool {
        normalizedPath(folder) == normalizedPath(home + "/" + provider.defaultFolderName)
    }

    /// Hook-skip switches of Open Island and Vibe Island; see `make`.
    public static let islandSkipKeys = ["OPEN_ISLAND_SKIP_HOOKS", "VIBE_ISLAND_SKIP"]

    /// Standardizes and resolves symlinks on both sides of the default-folder comparison, so `.`/`..` segments,
    /// a trailing slash, or a symlinked home directory can't defeat it — and so the variable, when it is set,
    /// carries the same normalized path the comparison used rather than whatever raw string the caller passed.
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
