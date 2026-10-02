#!/bin/zsh
# Builds the superset hook helper (release) and puts it in a built app at Contents/Helpers/OpenIslandHooks, the path
# the Setup pane's Install and the cutover's helper sync copy it from (spec §3.2, §3.5). Signs it ad-hoc; build-app.sh
# then stamps and re-signs the whole app. It never copies the helper anywhere else and never runs it.
# It is built for this Mac's chip, as the private app and a build from source are. With --universal it is one binary
# for Apple silicon and Intel (arm64 and x86_64), as the public release needs (P880), and refused if a slice is missing.
# Usage: zsh scripts/bundle-helper.sh [--universal] <app>
set -euo pipefail
archs=()
[[ "${1-}" != --universal ]] || { archs=(arm64 x86_64); shift }
(( $# == 1 )) || { print -u2 "usage: bundle-helper.sh [--universal] <app>"; exit 2; }
root=${0:A:h:h}
app=${1:A}
[[ -d "$app/Contents" ]] || { print -u2 "bundle-helper: no app bundle at $app"; exit 1; }

# The universal build keeps a build folder of its own: sharing .build with the native one, each would rebuild the
# whole helper after the other (about 40 s each time).
arch_args=()
(( ! ${#archs} )) || arch_args=(--scratch-path "$root/.build/universal")
for a in $archs; do arch_args+=(--arch "$a"); done
swift build --package-path "$root" -c release "${arch_args[@]}" --product OpenIslandHooks >/dev/null
bin="$(swift build --package-path "$root" -c release "${arch_args[@]}" --show-bin-path)/OpenIslandHooks"
[[ -x "$bin" ]] || { print -u2 "bundle-helper: $bin was not built"; exit 1; }
have=" $(lipo -archs "$bin" 2>/dev/null || true) "
for a in $archs; do
  [[ "$have" == *" $a "* ]] || { print -u2 "bundle-helper: the helper was built without $a (it has:${have% })"; exit 1; }
done
helper="$app/Contents/Helpers/OpenIslandHooks"
mkdir -p "${helper:h}"
ditto "$bin" "$helper"
chmod 755 "$helper"
codesign --force --sign - "$helper" 2>/dev/null
