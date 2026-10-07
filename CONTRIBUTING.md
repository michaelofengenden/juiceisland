# Contributing to Juice

Thanks for looking. This repository is published from the maintainer's own working copy, one commit per update, so a pull request is carried over by hand rather than merged here. Open an issue first for anything bigger than a small fix: the forms ask for what a bug report needs. A security problem goes privately, as [SECURITY.md](SECURITY.md) says.

## Build and test

You need Xcode 27, XcodeGen (`brew install xcodegen`), git and zsh.

- `swift test`: the app's views, models and session engine, all headless. No window opens and nothing is installed.
- `swift test --package-path JuiceCore`: the usage and money readers.
- `zsh scripts/test.sh`: everything, the hook socket tests included. It refuses to run while Juice or Open Island holds the hook socket.
- `zsh scripts/build-app.sh --public`: the app for this Mac's chip, into `output/public.noindex/` (`--public --universal` for Apple silicon and Intel, as a release is). It is signed with the team and identity in `Signing.local.xcconfig` when you have one, and ad hoc otherwise. Copy `Signing.example.xcconfig` to that name and fill in what you have; git ignores it. Without a `SPARKLE_PUBLIC_ED_KEY` line the build has updates off.
- `zsh scripts/release.sh --dry-run`: a whole release with stand-ins for every tool that reaches Apple, GitHub or the keychain. [docs/RELEASE.md](docs/RELEASE.md) is the real thing.
- `zsh scripts/render-all.sh <suite>`: headless renders of the views into `renders/`, for checking a change by eye.
- `JI_RENDER_DIR="$PWD/docs/images" swift test --filter 'Readme.*Renders'`: the README's images, drawn again from made-up sessions. After a change to the agents table, `JI_WRITE_AGENT_GRID=1 swift test --filter ReadmeAgentGridTests` rewrites the agent lists in README.md and docs/PRIVACY.md.
- `zsh scripts/check-guardrails.sh`: the rules below that a build cannot check. Run it before you send a change.

## Rules the code keeps

- `Vendor/open-vibe-island` is Open Island exactly as released (see `vendor.lock`); never edit it. A change to one of its engine files goes in `Patches/`, and `zsh scripts/vendor-derive.sh` writes the patched copy into `Sources/IslandEngine/Derived` (`--check` verifies it).
- Never read, store or send a Claude or Codex login token, and never open their login files. Usage comes only from the tools' own usage requests (Claude's `get_usage`, Codex's `account/rateLimits/read`), never from a prompt.
- Keep the polling floors: a Claude account at most every 300 s (120 s when boosted), a Codex account every 60 s (30 s at 75 % used, 15 s at 90 %), and a rate limit's Retry-After plus 15 minutes.
- The money client sends the app's own HTTP requests, to the providers the user gave a key for, the updater checks GitHub, and SSH hosts the user set up are reached over `ssh`; nothing else reaches the network.
- Hooks, SSH hosts and anything outside Juice's own folders change only on the user's click.
- No event monitors or event taps. The one global shortcut is opt-in, off, and has no key until the user records one.
- Tests never reach the network, never launch the app and never draw on screen.

## Style

Plain words in the interface and the docs. Commit messages in the imperative.

Comments cite pitfalls (`P83`), sections of the design (`§3.4`) and prototype lines (`prototype L120`) from the maintainer's design notes, which this repository does not include. The comment around each one says what it guards against.

## Licence

Juice is GPL-3.0. By sending a change you agree that it is licensed under the GPL-3.0 too.
