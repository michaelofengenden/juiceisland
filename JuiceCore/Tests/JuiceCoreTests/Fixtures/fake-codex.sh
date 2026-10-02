#!/bin/sh
# Pretends to be `codex app-server`. $FAKE_ACCOUNT and $FAKE_LIMITS are single-line JSON fixture files. With
# $FAKE_LIMITS_ERROR set (a single-line JSON error object), `account/rateLimits/read` answers with that error instead.
# `tr -d` undoes the \/ escaping JSONSerialization applies to method names such as account\/read.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
while IFS= read -r line; do
  id=$(printf '%s' "$line" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
  method=$(printf '%s' "$line" | grep -o '"method":"[^"]*"' | head -1 | cut -d'"' -f4 | tr -d '\\')
  case "$method" in
    initialize) echo "{\"id\":$id,\"result\":{\"userAgent\":\"fake\"}}"; echo '{"method":"remoteControl/status/changed","params":{"status":"disabled"}}' ;;
    initialized) ;;
    account/read) echo "{\"id\":$id,\"result\":$(cat "$FAKE_ACCOUNT")}" ;;
    account/rateLimits/read)
      if [ -n "$FAKE_LIMITS_ERROR" ]; then echo "{\"id\":$id,\"error\":$(cat "$FAKE_LIMITS_ERROR")}"
      else echo "{\"id\":$id,\"result\":$(cat "$FAKE_LIMITS")}"; fi ;;
    crash) exit 3 ;;
    *) echo "{\"id\":$id,\"error\":{\"code\":-32601,\"message\":\"unknown method $method\"}}" ;;
  esac
done
