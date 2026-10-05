# Security

Juice runs a hook helper for your coding agents, holds approvals for them, and reads money keys you give it, so a flaw in it matters. Please report one privately.

## Reporting

[Report a vulnerability](https://github.com/michaelofengenden/juiceisland/security/advisories/new) on GitHub. Only the maintainer sees it. Please do not open an issue or a discussion for it.

Say what an attacker could do, on which version (Settings › About), and how to see it happen. A short script or the steps are enough. Leave out your keys, emails and anything else from your own Mac.

You should hear back within a week. Once a fix is out, the release notes credit you by your GitHub handle, unless you would rather they did not.

## What counts

- The hook helper or the socket it talks to: another user or process on the Mac answering an approval, reading what agents send, or running code through it.
- Hooks or agent settings changed without a click, or changed beyond what Connect, Remove or Always allow say.
- A money key, or anything from an agent's login, read, logged or sent anywhere but the provider it belongs to.
- The updater installing something that is not a signed Juice release.

## Versions

Only the latest release gets fixes. Juice updates itself when you click Update, or with `brew upgrade --cask juiceisland`.
