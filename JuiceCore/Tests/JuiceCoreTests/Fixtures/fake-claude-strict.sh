#!/bin/sh
# Pretends to be a `claude` that will not take --strict-mcp-config: one too old to know it ($FAKE_REFUSAL=unknown, the
# default) or one on a Mac whose managed MCP config forbids it ($FAKE_REFUSAL=enterprise). Given the flag it exits at
# once, before reading its input; without it, it answers one get_usage control request with $FAKE_FIXTURE. Each
# launch's arguments are appended to $FAKE_ARGS_LOG.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
printf '%s\n' "$*" >> "$FAKE_ARGS_LOG"
case " $* " in
  *" --strict-mcp-config "*)
    if [ "$FAKE_REFUSAL" = enterprise ]; then
      echo "You cannot use --strict-mcp-config when an enterprise MCP config is present" >&2
    else
      echo "error: unknown option '--strict-mcp-config'" >&2
    fi
    exit 1 ;;
esac
read -r line
id=$(printf '%s' "$line" | sed -E 's/.*"request_id":"([^"]+)".*/\1/')
printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":%s}}\n' "$id" "$(cat "$FAKE_FIXTURE")"
sleep 30
