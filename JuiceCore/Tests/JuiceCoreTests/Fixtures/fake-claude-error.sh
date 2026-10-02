#!/bin/sh
# Pretends to be `claude`, but answers the get_usage control request with a control-response error
# (e.g. a lapsed OAuth token while the process is still running), instead of exiting non-zero.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
read -r line
id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\1/')
printf '{"type":"control_response","response":{"subtype":"error","request_id":"%s","error":"Not logged in · Please run /login"}}\n' "$id"
sleep 30
