#!/bin/sh
# Pretends to be `claude --output-format stream-json ...`: answers one get_usage control request with $FAKE_FIXTURE.
# With $FAKE_ARGS_LOG set, its arguments are appended to that file, one launch per line.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
[ -n "$FAKE_ARGS_LOG" ] && printf '%s\n' "$*" >> "$FAKE_ARGS_LOG"
read -r line
id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\1/')
echo '{"type":"system","subtype":"hook_started","hook_name":"SessionStart:startup"}'
printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\n' "$id" "$(cat "$FAKE_FIXTURE")"
sleep 30
