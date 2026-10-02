#!/bin/zsh
# Stamps a built app for the in-app Update check (spec §8 decision 12) and re-signs it, ad hoc unless
# JI_SIGN_IDENTITY names an identity (build-app.sh --prod passes the owner's Apple Development identity; never
# timestamped, so signing sends nothing over the network):
#   JIBuildCommit  the repo's HEAD, plus "-dirty" when tracked files have uncommitted changes
#   JIBuildDate    the build time, ISO 8601 in UTC
#   JIRepoPath     the repo's absolute path, where the app checks origin/main and which its Update fetches into;
#                  JI_STAMP_REPO_PATH names another (update-app.sh builds in its own checkout but stamps the owner's)
# Usage: zsh scripts/stamp-app.sh <app> [repo]   (repo defaults to the one holding this script)
set -euo pipefail
(( $# == 1 || $# == 2 )) || { print -u2 "usage: stamp-app.sh <app> [repo]"; exit 2; }
app=${1:A}
repo=${${2:-${0:A:h:h}}:A}
plist="$app/Contents/Info.plist"
[[ -f "$plist" ]] || { print -u2 "stamp-app: no Info.plist in $app"; exit 1; }

commit=$(git -C "$repo" rev-parse HEAD)
[[ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]] || commit+=-dirty
stamp() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "$plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$plist"; }
stamp JIBuildCommit "$commit"
stamp JIBuildDate "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp JIRepoPath "${JI_STAMP_REPO_PATH:-$repo}"

# codesign's own message is kept when it fails (a locked keychain, a missing identity), so the update log says why.
signed=$(codesign --force --sign "${JI_SIGN_IDENTITY:--}" --timestamp=none --deep \
  --preserve-metadata=entitlements,flags,runtime "$app" 2>&1) || { print -u2 -r -- "stamp-app: codesign failed: $signed"; exit 1; }
codesign --verify --deep --strict "$app"
