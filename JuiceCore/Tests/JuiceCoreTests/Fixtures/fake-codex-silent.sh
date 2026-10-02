#!/bin/sh
# Pretends to be a `codex app-server` that completes the handshake and then swallows every other
# request: `initialize` is answered, nothing else ever is, so the reader must time out.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
while IFS= read -r line; do
  id=$(printf '%s' "$line" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  method=$(printf '%s' "$line" | grep -o '"method":"[^"]*"' | head -1 | cut -d'"' -f4 | tr -d '\\')
  case "$method" in
    initialize) echo "{\"id\":$id,\"result\":{\"userAgent\":\"fake\"}}" ;;
    *) ;;
  esac
done
