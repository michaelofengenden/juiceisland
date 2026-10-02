#!/bin/sh
# Pretends to be `codex login --device-auth`: prints the page and, in colour, the one-time code to type there, then
# waits for $FAKE_LOGIN_WAIT to exist and exits 0.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
printf '\nFollow these steps to sign in with ChatGPT using device code authorization:\n\n'
printf '1. Open this link in your browser and sign in to your account\n   \033[94mhttps://example.com/codex/device\033[0m\n\n'
printf '2. Enter this one-time code \033[90m(expires in 15 minutes)\033[0m\n   \033[94mABCD-EFGH\033[0m\n\n'
printf 'Continue only if you started this login in Codex. If a website or another person gave you this code, cancel.\n'
if [ -n "$FAKE_LOGIN_WAIT" ]; then
  while [ ! -e "$FAKE_LOGIN_WAIT" ]; do sleep 0.05; done
fi
echo "Successfully logged in."
exit 0
