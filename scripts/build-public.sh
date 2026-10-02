#!/bin/zsh
# Builds the public flavor, Juice (P821, P822): `zsh scripts/build-app.sh --public [--universal] [output-folder]` runs
# this. The settings come from scripts/public-settings.sh (the untracked Signing.local.xcconfig and PUBLIC_REPO);
# project.yml and the private app's build are not touched.
#   - project-public.yml (XcodeGen) into Juice.xcodeproj, a Release build into output/dd-public.noindex: "Juice.app",
#     its widget at Contents/PlugIns/JuiceWidget.appex, Sparkle.framework (its XPC services left out: a non-sandboxed
#     app never uses them), the hook helper at Contents/Helpers/OpenIslandHooks (bundle-helper.sh). No update-app.sh:
#     the public flavor updates through Sparkle only.
#   - Stamped with the commit and the date (JIBuildCommit, JIBuildDate), never a path on this Mac. In a folder with no git
#     history (GitHub's "Source code" zip) the build number is 0 and no commit is stamped (About says "unknown build").
#   - The licences in Contents/Resources (P857): LICENSE.txt (GPL-3.0), NOTICE.txt (what comes from where) and
#     Sparkle-LICENSE.txt (Sparkle's MIT licence and the ones of the code it carries), so the download carries them.
#   - Signed inside out (Sparkle's parts, the helper, the widget, the app) with the hardened runtime, each part keeping
#     its entitlements: with the local file's identity, else ad hoc. A "Developer ID Application" identity also gets a
#     secure timestamp (a release, for notarizing); any other gets none, so signing sends nothing anywhere.
#   - Checked: names, ids, the App Group on the app and the widget, the widget's sandbox, the runtime flag on every part,
#     the team, the feed and its key in Info.plist, Sparkle linked, no update-app.sh, and every Mach-O in the app built
#     for the chips asked for; then unregistered from LaunchServices. Never opened or launched here.
#   - Built for this Mac's chip by default (arm64 on Apple silicon), which is the quickest build from source. With
#     --universal, which release.sh asks for, the app, the widget and the hook helper are built for Apple silicon and
#     Intel (arm64 and x86_64), so the download runs on every Mac with macOS 26; Sparkle ships both already (P880).
# Prints the built app's path last. Overrides: JI_VERSION (CFBundleShortVersionString; the VERSION file's otherwise),
# JI_BUILD_NUMBER (CFBundleVersion, which Sparkle compares; the commit count otherwise), JI_SIGN_IDENTITY (the identity
# to sign with in place of the local file's; "-" signs ad hoc and keeps the file's team in the App Group, which is what
# release.sh asks for, since it signs every part again), JI_SIGNING_FILE, PUBLIC_REPO, JI_LSREGISTER.
# Usage: zsh scripts/build-public.sh [--universal] [output-folder]   (output/public.noindex by default)
set -euo pipefail
root=${0:A:h:h}
cd "$root"
lsregister=${JI_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}
archs=($(uname -m)) helper_args=()
[[ "${1-}" != --universal ]] || { archs=(arm64 x86_64) helper_args=(--universal); shift }
(( $# <= 1 )) && [[ "${1-}" != -* ]] || { print -u2 "usage: build-app.sh --public [--universal] [output-folder]"; exit 2 }
out=${1:-output/public.noindex}
[[ "$out" == /* ]] || out="$root/$out"
derived=output/dd-public.noindex
name=Juice

eval "$(zsh "$root/scripts/public-settings.sh")"
if [[ -n ${JI_SIGN_IDENTITY-} ]]; then
  identity=$JI_SIGN_IDENTITY release=0
  [[ $identity == - || -n $team ]] || { print -u2 "build-public: JI_SIGN_IDENTITY needs DEVELOPMENT_TEAM in the local signing file"; exit 2 }
  [[ $identity != "Developer ID Application"* ]] || release=1
fi
version=${JI_VERSION-}
[[ -n "$version" || ! -f VERSION ]] || version=$(head -1 VERSION)
in_git=0
[[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" != "$root" ]] || in_git=1
if (( ! in_git )) && [[ -z ${JI_BUILD_NUMBER-} ]]; then
  print -u2 "build-public: no git history here (a source zip?): build number 0 and no commit in About. git clone the repository for both."
fi
build_number=${JI_BUILD_NUMBER:-$( (( in_git )) && git -C "$root" rev-list --count HEAD || print 0)}
[[ -z "$version" || "$version" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { print -u2 "build-public: JI_VERSION is not 1.2 or 1.2.3: $version"; exit 2 }
[[ "$build_number" =~ '^[0-9]+$' ]] || { print -u2 "build-public: JI_BUILD_NUMBER is not a whole number: $build_number"; exit 2 }

if [[ "$identity" == - && -z "$team" ]]; then
  print -u2 "build-public: no Signing.local.xcconfig team and identity: signing ad hoc (this Mac only, no widget data)."
fi
[[ -n "$sparkle_key" ]] || print -u2 "build-public: no SPARKLE_PUBLIC_ED_KEY: this build ships with updates off."

xcodegen generate --quiet --spec project-public.yml
settings=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
          JI_BUNDLE_ID="$bundle_id" JI_APP_GROUP="$app_group" JI_PUBLIC_REPO="$public_repo"
          JI_SPARKLE_PUBLIC_KEY="$sparkle_key" CURRENT_PROJECT_VERSION="$build_number" ARCHS="${archs[*]}"
          ONLY_ACTIVE_ARCH=NO)
[[ -z "$version" ]] || settings+=(MARKETING_VERSION="$version")
xcodebuild -project Juice.xcodeproj -scheme Juice -configuration Release -derivedDataPath "$derived" "${settings[@]}" build -quiet

built=("$derived"/Build/Products/Release/*.app(N))
(( ${#built} == 1 )) || { print -u2 "build-public: expected one app in $derived/Build/Products/Release"; exit 1; }
[[ "${built[1]:t}" == "$name.app" ]] || { print -u2 "build-public: built ${built[1]:t}, not $name.app"; exit 1; }

mkdir -p "$out"
app="$out/$name.app"
rm -rf "$app"
ditto "$built[1]" "$app"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2/Contents/Info.plist" 2>/dev/null; }
sparkle="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$sparkle" ]] || { print -u2 "build-public: no Sparkle.framework in the app"; exit 1; }
rm -rf "$sparkle"/Versions/B/XPCServices "$sparkle"/XPCServices
zsh "$root/scripts/bundle-helper.sh" "${helper_args[@]}" "$app"

# The licences the download carries: the public repository's LICENSE and NOTICE (in this private tree, Open Island's
# GPL text and NOTICE as the export fills it in), and Sparkle's, from the package Xcode fetched.
licence=$root/LICENSE notice=$root/NOTICE
[[ -f "$licence" ]] || licence=$root/Vendor/open-vibe-island/LICENSE
[[ -f "$notice" ]] || notice=$root/docs/public/NOTICE
sparkle_licence=$derived/SourcePackages/artifacts/sparkle/Sparkle/LICENSE
for pair in "$licence:LICENSE.txt" "$notice:NOTICE.txt" "$sparkle_licence:Sparkle-LICENSE.txt"; do
  [[ -f "${pair%:*}" ]] || { print -u2 "build-public: no ${pair%:*}, which the app must carry as ${pair##*:}"; exit 1 }
  install -m 644 "${pair%:*}" "$app/Contents/Resources/${pair##*:}"
done

pairs=("JIBuildDate $(date -u +%Y-%m-%dT%H:%M:%SZ)")
if (( in_git )); then
  commit=$(git -C "$root" rev-parse HEAD)
  [[ -z "$(git -C "$root" status --porcelain --untracked-files=no)" ]] || commit+=-dirty
  pairs=("JIBuildCommit $commit" $pairs)
fi
for pair in $pairs; do
  /usr/libexec/PlistBuddy -c "Add :${pair%% *} string ${pair#* }" "$app/Contents/Info.plist"
done

# Inside out: each part is signed before what holds it, all with the runtime flag. The app and the widget keep the
# entitlements they were built with (project-public.yml: Apple Events and the App Group; the sandbox and the App Group).
# Sparkle's parts are signed as Sparkle's documentation says, with none: its Autoupdate ships ad hoc with an
# application-identifier entitlement that no Developer ID signature may carry without a provisioning profile.
timestamp=--timestamp=none
(( release )) && timestamp=--timestamp
sign() {
  local signed
  signed=$(codesign --force --sign "$identity" --options runtime "$timestamp" "$@" 2>&1) \
    || { print -u2 -r -- "build-public: codesign failed on ${@[-1]#$app/}: $signed"; exit 1; }
}
widget="$app/Contents/PlugIns/JuiceWidget.appex"
helper="$app/Contents/Helpers/OpenIslandHooks"
parts=("$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app" "$sparkle" "$helper" "$widget" "$app")
for part in $parts; do
  [[ -e "$part" ]] || { print -u2 "build-public: no ${part#$app/}"; exit 1; }
  if [[ "$part" == "$widget" || "$part" == "$app" ]]; then sign --preserve-metadata=entitlements "$part"; else sign "$part"; fi
done
codesign --verify --deep --strict "$app"

# The checks.
fail() { print -u2 "build-public: $*"; exit 1 }
[[ "$(plist CFBundleIdentifier "$app")" == "$bundle_id" ]] || fail "bundle id is $(plist CFBundleIdentifier "$app"), not $bundle_id"
[[ "$(plist CFBundleName "$app")" == "$name" && "$(plist JIFlavor "$app")" == public ]] || fail "Info.plist does not say Juice, public"
[[ "$(plist CFBundleIdentifier "$widget")" == "$bundle_id.widget" ]] || fail "the widget's bundle id is not $bundle_id.widget"
[[ "$(plist SUFeedURL "$app")" == "$feed" ]] || fail "the feed is $(plist SUFeedURL "$app"), not $feed"
[[ "$(plist SUPublicEDKey "$app")" == "$sparkle_key" ]] || fail "the EdDSA key in Info.plist is not the local file's"
[[ "$(plist JIPublicRepo "$app")" == "$public_repo" ]] || fail "JIPublicRepo is not $public_repo"
[[ ! -e "$app/Contents/Resources/update-app.sh" ]] || fail "the public flavor carries update-app.sh"
for file in LICENSE.txt NOTICE.txt Sparkle-LICENSE.txt; do
  [[ -s "$app/Contents/Resources/$file" ]] || fail "the app does not carry $file"
done
grep -q "GNU GENERAL PUBLIC LICENSE" "$app/Contents/Resources/LICENSE.txt" || fail "LICENSE.txt is not the GPL text"
grep -q "Sparkle" "$app/Contents/Resources/NOTICE.txt" || fail "NOTICE.txt does not credit Sparkle"
otool -L "$app/Contents/MacOS/$name" | grep -q '@rpath/Sparkle.framework/' || fail "the app does not link Sparkle"
for part in "$app" "$widget"; do
  entitlements=$(codesign -d --entitlements - --xml "$part" 2>/dev/null) || entitlements=
  [[ "$entitlements" == *"<string>$app_group</string>"* ]] || fail "${part:t} is not entitled to the App Group $app_group"
done
[[ "$(codesign -d --entitlements - --xml "$widget" 2>/dev/null)" == *"<key>com.apple.security.app-sandbox</key><true/>"* ]] \
  || fail "the widget is not sandboxed"
[[ "$(codesign -d --entitlements - --xml "$app" 2>/dev/null)" == *"<key>com.apple.security.automation.apple-events</key><true/>"* ]] \
  || fail "the app has no Apple Events entitlement"
# Every Mach-O in the app, Sparkle's too, runs on each chip asked for (P880): a part without a slice fails only on the
# Macs that need it, the hook helper without a word.
thin=()
for f in "$app"/Contents/**/*(DN.); do
  [[ "$(file -b "$f")" == *Mach-O* ]] || continue
  have=" $(lipo -archs "$f" 2>/dev/null || true) "
  for a in $archs; do [[ "$have" == *" $a "* ]] || thin+=("${f#$app/} (no $a)"); done
done
(( ${#thin} == 0 )) || fail "built for ${(j: and :)archs}, but these parts are not: ${(j:, :)thin}"
for part in $parts; do
  entitlements=$(codesign -d --entitlements - --xml "$part" 2>/dev/null) || entitlements=
  [[ "$entitlements" != *get-task-allow* && "$entitlements" != *application-identifier* ]] \
    || fail "${part#$app/} carries a debugging or provisioned entitlement, which notarization refuses"
  details=$(codesign -dv "$part" 2>&1)
  [[ "$details" =~ 'flags=0x[0-9a-f]+\([^)]*runtime' ]] || fail "${part#$app/} is not signed with the hardened runtime"
  if [[ "$identity" != - ]]; then
    signed=$(print -r -- "$details" | sed -n 's/^TeamIdentifier=//p')
    [[ "$signed" == "$team" ]] || fail "${part#$app/} signed for team ${signed:-none}, not $team"
  fi
  if (( release )); then
    [[ "$details" == *"Timestamp="* ]] || fail "${part#$app/} has no secure timestamp"
  fi
done
"$lsregister" -u "$root/$built[1]" 2>/dev/null || true
"$lsregister" -u "$app" 2>/dev/null || true
echo "$app"
