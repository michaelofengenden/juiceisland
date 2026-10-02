#!/bin/sh
# Leaves a grandchild holding the inherited stdout/stderr and exits: EOF on the pipes never comes, the way a
# Claude CLI that started an MCP server behaves. The grandchild's pid goes to $ORPHAN_PID_FILE so the test kills it.
sleep 30 >&1 2>&2 &
printf '%s\n' "$!" > "$ORPHAN_PID_FILE"
echo first
echo second
exit 0
