#!/bin/sh
# Pretends to be a `codex app-server` that asks the client things of its own before it answers a usage read: first a
# request with a string id, then one whose id is the very id of the read it is about to answer. Each answer the client
# sends is appended to $FAKE_LOG. A client that takes either request for its reply, or never answers one, never gets
# the real reply. $FAKE_ACCOUNT and $FAKE_LIMITS are single-line JSON fixture files.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
while IFS= read -r line; do
  id=$(printf '%s' "$line" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  method=$(printf '%s' "$line" | grep -o '"method":"[^"]*"' | head -1 | cut -d'"' -f4 | tr -d '\\')
  case "$method" in
    initialize) echo "{\"id\":$id,\"result\":{\"userAgent\":\"fake\"}}" ;;
    initialized) ;;
    account/read) echo "{\"id\":$id,\"result\":$(cat "$FAKE_ACCOUNT")}" ;;
    account/rateLimits/read)
      echo '{"id":"srv-1","method":"account/chatgptAuthTokens/refresh","params":{"reason":"unauthorized"}}'
      IFS= read -r answer; printf '%s\n' "$answer" >> "$FAKE_LOG"
      echo "{\"id\":$id,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"true\"}}"
      IFS= read -r answer; printf '%s\n' "$answer" >> "$FAKE_LOG"
      echo "{\"id\":$id,\"result\":$(cat "$FAKE_LIMITS")}" ;;
    *) echo "{\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"unknown method $method\"}}" ;;
  esac
done
