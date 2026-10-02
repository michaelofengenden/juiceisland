#!/bin/sh
# Pretends to be `codex app-server` the way a real one keeps its login: $FAKE_ACCOUNT is read once, at launch, so a
# later `codex login` (the test rewriting that file) reaches only a server started after it. $FAKE_LIMITS is read on
# every request, like live usage. Both are single-line JSON fixture files. Never looks at auth.json.
# With $FAKE_LOG set, every method is appended to that file, one per line. An `account/read` that asks for a token
# refresh gets an error, as Juice must never ask for one. While the file $FAKE_SLOW exists, `account/read` answers a
# second late, and while $FAKE_SLOW_LIMITS exists, `account/rateLimits/read` does. With $FAKE_STICKY_LIMITS set,
# $FAKE_LIMITS is read once at launch too: the limits and reset credits of the login the server started with.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
account=$(cat "$FAKE_ACCOUNT")
[ -n "$FAKE_STICKY_LIMITS" ] && limits=$(cat "$FAKE_LIMITS")
while IFS= read -r line; do
  id=$(printf '%s' "$line" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  method=$(printf '%s' "$line" | grep -o '"method":"[^"]*"' | head -1 | cut -d'"' -f4 | tr -d '\\')
  [ -n "$FAKE_LOG" ] && printf '%s\n' "$method" >> "$FAKE_LOG"
  case "$method" in
    initialize) echo "{\"id\":$id,\"result\":{\"userAgent\":\"fake\"}}" ;;
    initialized) ;;
    account/read)
      [ -n "$FAKE_SLOW" ] && [ -e "$FAKE_SLOW" ] && sleep 1
      case "$line" in
        *'"refreshToken":true'*) echo "{\"id\":$id,\"error\":{\"code\":-32600,\"message\":\"refreshToken must be false\"}}" ;;
        *) echo "{\"id\":$id,\"result\":$account}" ;;
      esac ;;
    account/rateLimits/read)
      [ -n "$FAKE_SLOW_LIMITS" ] && [ -e "$FAKE_SLOW_LIMITS" ] && sleep 1
      [ -n "$FAKE_STICKY_LIMITS" ] || limits=$(cat "$FAKE_LIMITS")
      echo "{\"id\":$id,\"result\":$limits}" ;;
    *) echo "{\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"unknown method $method\"}}" ;;
  esac
done
