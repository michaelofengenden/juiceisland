#!/bin/zsh
# Every test in the root package, the socket tests included. Upstream's Core tests and SessionEngineBridgeTests start
# real BridgeServers on scratch sockets, and every BridgeServer also rebinds the legacy /tmp/open-island-<uid>.sock
# after deleting it. JUICE_ISLAND_BRIDGE_TESTS=1 adds them (Package.swift, SessionEngineBridgeTests), so this refuses
# to run while any island app owns a hook socket. A bare `swift test` leaves them out.
set -euo pipefail
root="${0:A:h:h}"
for sock in "$HOME/Library/Application Support/OpenIsland/bridge.sock" "/tmp/open-island-$(id -u).sock"; do
  if [[ -S "$sock" ]] && lsof -t -- "$sock" >/dev/null 2>&1; then
    print -u2 "test.sh: $sock belongs to pid $(lsof -t -- "$sock" | head -1); quit that island app first."
    exit 1
  fi
done
cd "$root"
JUICE_ISLAND_BRIDGE_TESTS=1 swift test "$@"
