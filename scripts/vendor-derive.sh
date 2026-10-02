#!/bin/zsh
# Regenerates every file derived from Vendor/open-vibe-island. Vendor/ itself is never edited.
#   Sources/IslandEngine/Derived/<name>.swift = the vendor engine file + its patch in Patches/ (see `patched` below)
#   Tests/VendorEngineTests/<name>.swift = the vendor engine test, importing IslandEngine instead of OpenIslandApp
# Each starts with two comment lines saying it was changed from Open Island and how (GPL-3.0 section 5a, P846).
# KeystrokeInjectorTests is left out on purpose: one of its tests posts a real Cmd-Shift-] to whatever app is in
# front. Its spy, which TerminalJumpServiceTests needs, lives in Tests/VendorEngineTests/Support/ (our file).
# With --check it regenerates into a scratch directory and fails when the committed copies differ.
set -euo pipefail
root="${0:A:h:h}"
vendor="$root/Vendor/open-vibe-island"
out="$root"
version=$(sed -n 's/^UPSTREAM_VERSION=//p' "$root/vendor.lock")
[[ -n "$version" ]] || { echo "vendor-derive: no UPSTREAM_VERSION in vendor.lock" >&2; exit 1; }
check=0
if [[ "${1:-}" == "--check" ]]; then
  check=1
  out="$(mktemp -d)"
fi

# Engine files compiled from a patched copy, each with its patch: <file in OpenIslandApp>:<patch in Patches/>.
patched=(
  ActiveAgentProcessDiscovery:active-agent-profiles
  SessionDiscoveryCoordinator:bounded-transcripts
)

engine_tests=(
  ActiveAgentProcessDiscoveryTests
  AgentSessionPresentationTests
  ForegroundTerminalSessionProbeTests
  GrokProcessLivenessTests
  IslandSurfaceTests
  TerminalJumpServiceTests
  TerminalSessionAttachmentProbeTests
)

mkdir -p "$out/Sources/IslandEngine/Derived" "$out/Tests/VendorEngineTests"

for pair in "${patched[@]}"; do
  name="${pair%%:*}"
  copy="$out/Sources/IslandEngine/Derived/$name.swift"
  cp "$vendor/Sources/OpenIslandApp/$name.swift" "$copy.patched"
  patch --quiet --forward --no-backup-if-mismatch "$copy.patched" "$root/Patches/${pair#*:}.patch"
  { print -r -- "// Changed from Open Island $version's Sources/OpenIslandApp/$name.swift (GPL-3.0): Patches/${pair#*:}.patch"
    print -r -- "// applied by scripts/vendor-derive.sh, which writes this file. Change the patch, never this file."
    cat "$copy.patched"; } > "$copy"
  rm -f "$copy.patched"
done

for name in "${engine_tests[@]}"; do
  { print -r -- "// Changed from Open Island $version's Tests/OpenIslandAppTests/$name.swift (GPL-3.0): it imports IslandEngine"
    print -r -- "// instead of OpenIslandApp. Written by scripts/vendor-derive.sh; never edit it."
    sed 's/^@testable import OpenIslandApp$/@testable import IslandEngine/' "$vendor/Tests/OpenIslandAppTests/$name.swift"
  } > "$out/Tests/VendorEngineTests/$name.swift"
done

if (( check )); then
  stale=0
  for pair in "${patched[@]}"; do
    name="${pair%%:*}"
    diff -q "$out/Sources/IslandEngine/Derived/$name.swift" "$root/Sources/IslandEngine/Derived/$name.swift" || stale=1
  done
  for name in "${engine_tests[@]}"; do
    diff -q "$out/Tests/VendorEngineTests/$name.swift" "$root/Tests/VendorEngineTests/$name.swift" || stale=1
  done
  rm -rf "$out"
  if (( stale )); then
    echo "vendor-derive: derived files are out of date; run zsh scripts/vendor-derive.sh" >&2
    exit 1
  fi
  echo "vendor-derive: derived files match Vendor/ and Patches/"
else
  echo "vendor-derive: regenerated Sources/IslandEngine/Derived and Tests/VendorEngineTests"
fi
