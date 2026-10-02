#!/bin/sh
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
echo "Not logged in. Please run /login" 1>&2
exit 1
