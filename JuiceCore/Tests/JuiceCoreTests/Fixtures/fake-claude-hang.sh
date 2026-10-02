#!/bin/sh
# Pretends to be `claude auth status --json` that never answers. It appends to a file in the profile folder so a
# test can see whether it is still alive, and gives up by itself so a child nobody stopped cannot outlive the run.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
i=0
while [ $i -lt 100 ]; do
  printf 'x' >> "$CLAUDE_CONFIG_DIR/ticks"
  sleep 0.05
  i=$((i + 1))
done
