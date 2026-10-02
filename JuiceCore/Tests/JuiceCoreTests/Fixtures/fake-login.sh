#!/bin/sh
# Pretends to be `claude auth login` / `codex login`: prints a URL, then waits for $FAKE_LOGIN_WAIT (if set) to exist, then exits 0.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
echo "Opening browser… If it does not open, visit: https://example.com/login/abc123"
if [ -n "$BROWSER" ]; then "$BROWSER" "https://example.com/login/abc123"; fi
if [ -n "$FAKE_LOGIN_WAIT" ]; then
  while [ ! -e "$FAKE_LOGIN_WAIT" ]; do sleep 0.05; done
fi
echo "Logged in."
exit 0
