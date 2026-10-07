# What Juice reads and changes

Everything stays on your Mac. Juice has no server, no account and no analytics, and it changes files only when you click. This page says exactly what it reads, what it sends, and which files it changes. [Back to the README](../README.md).

- **Free and open source.** GPL-3.0, with no paid tier and no licence key.
- **No analytics.** No account, no server, no crash reporter and no usage tracking.
- **Never reads your logins.** Usage comes from the `claude` and `codex` tools' own usage requests. Juice never opens their login files or the Keychain, and never sends a prompt of its own: it sends only what you type.
- **Never touches your status line.** Your agents' own status lines stay as you set them.
- **Changes files only when you click, with backups.** Hooks go in on Connect and come out on Remove, and a file Juice will not edit gets the exact lines to paste instead.

## What it reads

- **Usage** comes from the `claude` and `codex` tools you already have, through their own usage requests. Juice never reads, stores or sends their login tokens, and a usage read never sends a prompt. Juice sends only what you type: a reply from a session's card goes to that session, typed into its tab, or, once the tab is closed, through Claude Code's or Codex's own resume, when you press Return. It asks at most every 2 to 5 minutes per Claude account, and every 15 to 60 seconds per Codex account, the faster pace only near the account's limit. These are the tools' own interfaces and not all of them are documented, so an update of `claude` or `codex` can break a battery until Juice catches up. While Juice reads a Codex account, Codex also fetches its model list every few minutes, as it does whenever it runs.
- **Sessions** come from the hook events each connected agent sends to Juice over a socket on your Mac, and from Claude Code's and Codex's session files in `~/.claude` and `~/.codex` (and in `~/.claude-*` and `~/.codex-*` profile folders).
- **Money**, only for the providers you add a key for. Keys are plain files readable only by you (mode 600) under `~/.config/<provider>/`, not in the Keychain. Use a read-only key where the provider offers one.
- **Network.** Juice talks to the network only for money (each provider's own API, with your key), to check GitHub for an update, and, for SSH hosts you set up, over `ssh`. It checks for an update once a day and installs one only when you click, or when you quit if you turn on Settings › About › Install automatically. Releases are signed and notarized.

## What it changes, and only when you click

- **Hooks.** Connect copies Juice's hook helper to `JuiceHooks` in Juice's own folder in `~/Library/Application Support`, and adds Juice's hooks to each agent you tick, in the files listed under [Where the hooks go](#where-the-hooks-go). Settings › Agents connects or removes one agent at a time. Remove takes Juice's lines out and gives each file back as it was, and a file only Juice wrote goes; Remove from all agents does this everywhere. A file that is a link, a JSON file with comments, or a TOML file Juice can't add to without touching your lines is never changed: its row gives the lines to paste by hand (Copy snippet). The last three backups of each changed file are kept beside it.
- **Approvals.** While Juice runs, an agent marked Approve waits for your answer in the island when it asks for permission. Copilot CLI, CodeBuddy, Devin and Qwen Code show no prompt of their own while they wait, so their approvals always open the island and sound, even for a session you muted or are looking at. Always allow adds the rule Claude Code suggests to its settings.
- **Other apps' hooks.** Juice has its own hook helper and socket, so it runs beside Open Island, whose hooks and plugin stay as they are. When another notch app's hooks are in an agent's files, the first run shows a card and leaves those agents alone until you pick. Switch asks that app to quit, backs up each of those files beside it, takes out only the lines that call that app's helper (and its OpenCode plugin file), then connects Juice. Keep leaves them with that app. It may put its hooks back when it opens again, so use its own uninstall to remove it fully.
- **SSH hosts.** Off unless you set one up. Setting up a host copies a small Python helper into your home folder on that host and adds hooks to its Claude Code and Codex settings. With Live sessions on, Juice keeps one `ssh` connection open per host. It reads only the Host names in `~/.ssh/config` and never asks for a password.
- **Sounds.** Choose File… in Settings › Sound copies the file you pick into a Sounds folder in Juice's own folder in `~/Library/Application Support`. The file you picked stays where it is.
- **Open in and Reply** type into your terminal through AppleScript, so macOS asks for Automation permission the first time. Open in starts `claude` or `codex` in a new terminal window; Reply sends text only to the session's own terminal.

## Where the hooks go

<!-- agent-grid: written by ReadmeAgentGridTests from the agents table; JI_WRITE_AGENT_GRID=1 swift test --filter ReadmeAgentGridTests rewrites it -->

| Agent | From the island | Usage | Juice's hooks go in |
|---|---|---|---|
| Claude Code | Approve | Battery per account | `settings.json` in `~/.claude` and each `~/.claude-*` profile |
| Codex | Approve¹ | Battery per account | `hooks.json` and `config.toml` in `~/.codex` and each `~/.codex-*` profile |
| OpenCode | Approve |  | `~/.config/opencode/plugins/juice.js` |
| Copilot CLI | Approve |  | `~/.copilot/hooks/juice.json` |
| Cursor | Watch |  | `~/.cursor/hooks.json` |
| Qwen Code | Approve |  | `~/.qwen/settings.json` |
| Devin | Approve |  | `~/.config/devin/config.json` |
| Kilo | Approve |  | `~/.config/kilo/plugin/juice.js` |
| Gemini CLI | Watch |  | `~/.gemini/settings.json` |
| Antigravity | Watch |  | `~/.gemini/config/hooks.json` |
| Grok Build | Watch |  | `~/.grok/hooks/juice.json` |
| Qoder | Approve² |  | `~/.qoder/settings.json` |
| CodeBuddy | Approve |  | `~/.codebuddy/settings.json` |
| Factory Droid | Watch |  | `~/.factory/hooks.json` or `~/.factory/hooks/hooks.json` or `~/.factory/settings.json` |
| Kimi Code | Watch |  | `~/.kimi-code/config.toml` or `~/.kimi/config.toml` |
| Pi | Watch |  | `~/.pi/agent/extensions/juice.ts` |
| Oh My Pi | Watch |  | `~/.omp/agent/extensions/juice.ts` |
| Amp | Watch |  | `~/.config/amp/plugins/juice.ts` |

**Approve**: answer its prompts from the island. **Watch**: see its sessions and jump to them, and answer its prompts there.

¹ With Settings › Island › Answer Codex in Juice; Watch otherwise.

² Qoder CLI; the Qoder IDE is Watch.

<!-- /agent-grid -->

## Uninstalling

Click Remove from all agents in Settings › Agents first, so no agent calls a helper that is gone. Then move Juice to the Trash, or run `brew uninstall --zap --cask juiceisland`.

For a security problem, see [SECURITY.md](../SECURITY.md).
