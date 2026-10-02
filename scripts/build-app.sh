#!/bin/zsh
# Builds the app (Release) with its widget at Contents/PlugIns/JuiceIslandWidget.appex (checked below), adds the
# superset hook helper at Contents/Helpers/OpenIslandHooks (bundle-helper.sh) and the updater at
# Contents/Resources/update-app.sh (the copy the app's Update runs, P134), stamps it with the commit, date and repo path
# (stamp-app.sh) and unregisters it from LaunchServices, so Spotlight and "Open With" never offer it. Launch it by path
# only. This script never opens it.
# Prints the built app's path last.
#   dev (default)  "Juice Island Dev.app" (shown as Juice Island), com.ofengenden.juice.dev, ad-hoc signed, into
#                  output/app.noindex/
#   --prod         "Juice Island.app", com.ofengenden.juice, into output/prod.noindex/, signed with the owner's Apple
#                  Development identity (team TEAMID0000), so the designated requirement stays the same from build to
#                  build and macOS keeps the Automation and login-item permissions. Ad hoc, with a warning, when the
#                  keychain has no such identity. Never timestamped, so signing sends nothing over the network.
#   --public       the public flavor, "Juice.app" (P821): scripts/build-public.sh builds it from project-public.yml with
#                  Sparkle, its own ids and the untracked Signing.local.xcconfig; nothing below runs for it. For this
#                  Mac's chip, or with --universal after it for Apple silicon and Intel, as release.sh asks (P880).
# update-app.sh and install-app.sh pass a staging folder to build into.
# Usage: zsh scripts/build-app.sh [--prod | --public [--universal]] [output-folder]
# Overrides: JI_SIGN_IDENTITY (the identity's SHA-1 hash or name; "-" signs ad hoc), JI_LSREGISTER.
set -euo pipefail
[[ "${1-}" != --public ]] || { shift; exec zsh "${0:A:h}/build-public.sh" "$@" }
root=${0:A:h:h}
cd "$root"
lsregister=${JI_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
team=TEAMID0000
prod=0
[[ "${1-}" != --prod ]] || { prod=1; shift }
(( $# <= 1 )) || { print -u2 "usage: build-app.sh [--prod] [output-folder]"; exit 2 }
if (( prod )); then
  bundle_id=com.ofengenden.juice name="Juice Island" derived=output/dd-prod.noindex out=${1:-output/prod.noindex}
else
  bundle_id=com.ofengenden.juice.dev name="Juice Island Dev" derived=output/dd.noindex out=${1:-output/app.noindex}
fi
[[ "$out" == /* ]] || out="$root/$out"

# The SHA-1 hash of an Apple Development identity whose certificate belongs to the owner's team. Reads the public
# certificates only.
development_identity() {
  local hashes h
  hashes=(${(f)"$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / {print $2}')"})
  for h in $hashes; do
    security find-certificate -a -Z -p -c "Apple Development" 2>/dev/null \
      | awk -v h="$h" '/^SHA-1 hash:/ {on = ($3 == h); next} on && /BEGIN CERTIFICATE/ {p = 1} on && p {print} /END CERTIFICATE/ {p = 0}' \
      | openssl x509 -noout -subject 2>/dev/null | grep -qE "OU ?= ?$team([,/]|\$)" && { print -r -- "$h"; return 0 }
  done
  return 1
}

identity=-
if (( prod )); then
  if [[ -n "${JI_SIGN_IDENTITY-}" ]]; then identity=$JI_SIGN_IDENTITY
  else identity=$(development_identity) || identity=-; fi
  if [[ "$identity" == - ]]; then
    [[ "${JI_SIGN_IDENTITY-}" == - ]] && print -u2 "build-app: WARNING: JI_SIGN_IDENTITY=- asks for an ad-hoc signature." \
      || print -u2 "build-app: WARNING: no Apple Development identity for team $team in the keychain; signing ad hoc."
    print -u2 "build-app: WARNING: an ad-hoc build's designated requirement changes with every build, so macOS asks"
    print -u2 "build-app: WARNING: again for Automation and the login item after each update."
  fi
fi

xcodegen generate --quiet
xcodebuild -project JuiceIsland.xcodeproj -scheme JuiceIsland -configuration Release -derivedDataPath "$derived" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  JI_BUNDLE_ID="$bundle_id" JI_PRODUCT_NAME="$name" \
  build -quiet

built=("$derived"/Build/Products/Release/*.app(N))
(( ${#built} == 1 )) || { print -u2 "build-app: expected one app in $derived/Build/Products/Release"; exit 1; }
[[ "${built[1]:t}" == "$name.app" ]] || { print -u2 "build-app: built ${built[1]:t}, not $name.app"; exit 1; }
id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built[1]/Contents/Info.plist")
[[ "$id" == "$bundle_id" ]] || { print -u2 "build-app: bundle id is $id, not $bundle_id"; exit 1; }

mkdir -p "$out"
app="$out/${built[1]:t}"
rm -rf "$app"
ditto "$built[1]" "$app"
zsh "$root/scripts/bundle-helper.sh" "$app"
[[ ! -f "$root/scripts/update-app.sh" ]] || install -m 644 "$root/scripts/update-app.sh" "$app/Contents/Resources/update-app.sh"
JI_SIGN_IDENTITY=$identity zsh "$root/scripts/stamp-app.sh" "$app" "$root"
# The widget (spec §4.7): embedded as <bundle id>.widget, sandboxed, and both it and the app entitled to the App Group
# $team.<bundle id>, after the re-signing above kept every part's own entitlements.
widget="$app/Contents/PlugIns/JuiceIslandWidget.appex"
[[ -d "$widget" ]] || { print -u2 "build-app: no widget at ${widget#$app/}"; exit 1; }
wid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$widget/Contents/Info.plist")
[[ "$wid" == "$bundle_id.widget" ]] || { print -u2 "build-app: widget bundle id is $wid, not $bundle_id.widget"; exit 1; }
for part in "$app" "$widget"; do
  entitlements=$(codesign -d --entitlements - --xml "$part" 2>/dev/null) || entitlements=
  [[ "$entitlements" == *"<string>$team.$bundle_id</string>"* ]] \
    || { print -u2 "build-app: ${part:t} is not entitled to the App Group $team.$bundle_id"; exit 1; }
done
[[ "$(codesign -d --entitlements - --xml "$widget" 2>/dev/null)" == *"<key>com.apple.security.app-sandbox</key><true/>"* ]] \
  || { print -u2 "build-app: the widget is not sandboxed"; exit 1; }
if [[ "$identity" != - ]]; then
  for part in "$app" "$widget"; do
    signed=$(codesign -dv "$part" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    [[ "$signed" == "$team" ]] || { print -u2 "build-app: ${part:t} signed for team ${signed:-none}, not $team"; exit 1; }
  done
fi
"$lsregister" -u "$root/$built[1]" 2>/dev/null || true
"$lsregister" -u "$app" 2>/dev/null || true
echo "$app"
