#!/bin/zsh
# Tests release.sh inside <work-dir> only: a clone of this repository with the working copy's release scripts and
# VERSION committed on its main, a home folder of its own, a fake build (a small Juice.app with a widget, a hook
# helper and a Sparkle-shaped framework, signed ad hoc with the entitlements a real build carries, its own Mach-O
# files carrying a path in the home folder as a real build's symbols do), and release-fake.zsh standing in for
# codesign's signing, notarytool, stapler, spctl, the keychain's identity list, Sparkle's tools and gh
# (JI_RELEASE_TOOLS), with its knobs for each failure. ditto, strip, hdiutil and xmllint run for real, in <work-dir>,
# and so does lipo, through a stand-in first on PATH that can hide a slice from lipo -archs (FAKE_LIPO_DROP). The DMG's
# read-write image is mounted for its layout as a downloaded one is, at /Volumes/Juice, with -nobrowse (no Finder
# window), and unmounted before each run ends; the test mounts the finished DMGs under <work-dir> to read them. No
# network, no keychain, nothing outside <work-dir> changed.
# Usage: zsh scripts/tests/release-script-test.zsh <work-dir>   (a folder that does not exist yet)
set -euo pipefail
src=${0:A:h:h:h}
(( $# == 1 )) || { print -u2 "usage: release-script-test.zsh <work-dir>"; exit 2 }
W=${1:a}
[[ ! -e "$W" ]] || { print -u2 "release-script-test: $W exists; pass a new folder"; exit 2 }
mkdir -p "$W/bin" "$W/home"
W=${W:A}
source_repo=$(git -C "$src" rev-parse --path-format=absolute --git-common-dir) source_head=$(git -C "$src" rev-parse HEAD)

export HOME=$W/home
mkdir -p "$HOME/src"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Release Test" GIT_AUTHOR_EMAIL=release-test@example.invalid
export GIT_COMMITTER_NAME="Release Test" GIT_COMMITTER_EMAIL=release-test@example.invalid
repo=$W/repo
R=example/juice-test
KEY=anVpY2UtcmVsZWFzZS1mYWtlLXB1YmxpYy1rZXktMzI=
SIG=anVpY2UtcmVsZWFzZS1mYWtlLWVkMjU1MTktc2lnbmF0dXJlLWZvci10ZXN0cy1vbmx5LTAxMjM0NTY3ODlhYg==

git clone -q "$source_repo" "$repo"
git -C "$repo" checkout -q -B main "$source_head"
for f in scripts/release.sh scripts/release-fake.zsh scripts/public-settings.sh scripts/dmg-layout.swift \
         scripts/dmg/background.png scripts/dmg/background@2x.png scripts/build-app.sh scripts/build-public.sh VERSION .gitignore; do
  mkdir -p "$repo/${f:h}"; cp "$src/$f" "$repo/$f"
done
git -C "$repo" add scripts VERSION .gitignore
git -C "$repo" diff --cached --quiet || git -C "$repo" commit -q -m "Scripts under test"
version=$(head -1 "$repo/VERSION")

# A universal Mach-O whose debug map names an object file in the home folder, as a real build's do.
print -r -- 'int main(void) { return 0; }' > "$HOME/src/stub.c"
cc -arch arm64 -arch x86_64 -g -c "$HOME/src/stub.c" -o "$HOME/src/stub.o"
cc -arch arm64 -arch x86_64 "$HOME/src/stub.o" -o "$W/bin/stub"
grep -qF -- "$HOME/" "$W/bin/stub" || { print -u2 "release-script-test: the stub does not name the home folder"; exit 1 }
# Sparkle's binaries, which the release leaves as they are: universal, as Sparkle ships them, with no debug map.
mkdir -p "$W/src"
print -r -- 'int main(void) { return 0; }' > "$W/src/plain.c"
cc -arch arm64 -arch x86_64 "$W/src/plain.c" -o "$W/bin/plain"
! grep -qF -- "$HOME/" "$W/bin/plain" || { print -u2 "release-script-test: the plain stub names the home folder"; exit 1 }

# lipo, first on PATH. With FAKE_LIPO_DROP="<arch>:<path suffix> ...", lipo -archs leaves that arch out for a file whose
# path ends with the suffix, as for a part built without it. Every other call is the real lipo.
mkdir -p "$W/fakebin"
cat > "$W/fakebin/lipo" <<'EOF'
#!/bin/zsh
set -euo pipefail
[[ ${1-} == -archs && $# == 2 && -n ${FAKE_LIPO_DROP-} ]] || exec /usr/bin/lipo "$@"
archs=(${=$(/usr/bin/lipo -archs "$2")})
for drop in ${=FAKE_LIPO_DROP}; do [[ $2 != *${drop#*:} ]] || archs=(${archs:#${drop%%:*}}); done
print -r -- "${archs[*]}"
EOF
chmod +x "$W/fakebin/lipo"
export PATH=$W/fakebin:$PATH

# The stand-in for build-app.sh --public <folder>: prints the app's path last. Knobs: FAKE_BUILD_FAIL,
# FAKE_BUILD_HOME (a JIRepoPath in the home folder), FAKE_BUILD_THIN_HELPER (the helper for arm64 only),
# FAKE_BUILD_NO_APPLE_EVENTS, FAKE_BUILD_TEAM (the App Group's team), FAKE_BUILD_NO_WIDGET, FAKE_BUILD_FEED,
# FAKE_BUILD_NO_EDKEY, FAKE_BUILD_NO_LICENSE (no licence texts in the app).
cat > "$W/bin/fake-build" <<'EOF'
#!/bin/zsh
set -euo pipefail
w=${0:A:h:h}
print -r -- "build $* identity=${JI_SIGN_IDENTITY-} version=${JI_VERSION-} number=${JI_BUILD_NUMBER-}" >> "$w/build.calls"
[[ "${1-}" == --public && "${2-}" == --universal && $# == 3 ]] || { print -u2 "fake-build: usage: --public --universal <folder>"; exit 2 }
[[ -z "${FAKE_BUILD_FAIL-}" ]] || { print -u2 "fake-build: failing on purpose"; exit 1 }
print -r -- "note: a line of build output"
team=${FAKE_BUILD_TEAM:-ABCDE12345} id=com.example.juice
app=$3/Juice.app fw=$3/Juice.app/Contents/Frameworks/Sparkle.framework
pb() { local f=$1; shift; for c in "$@"; do /usr/libexec/PlistBuddy -c "$c" "$f" >/dev/null; done }
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" \
  "$fw/Versions/B/Resources" "$fw/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS"
cp "$w/bin/stub" "$app/Contents/MacOS/Juice"
if [[ -n "${FAKE_BUILD_THIN_HELPER-}" ]]; then lipo "$w/bin/stub" -thin arm64 -output "$app/Contents/Helpers/OpenIslandHooks"
else cp "$w/bin/stub" "$app/Contents/Helpers/OpenIslandHooks"; fi
print -r -- "resource" > "$app/Contents/Resources/stub.txt"
if [[ -z "${FAKE_BUILD_NO_LICENSE-}" ]]; then
  print -r -- "GNU GENERAL PUBLIC LICENSE" > "$app/Contents/Resources/LICENSE.txt"
  print -r -- "${FAKE_BUILD_NOTICE:-Juice, with Sparkle}" > "$app/Contents/Resources/NOTICE.txt"
  print -r -- "Sparkle's licence" > "$app/Contents/Resources/Sparkle-LICENSE.txt"
fi
cp "$w/bin/plain" "$fw/Versions/B/Sparkle"; cp "$w/bin/plain" "$fw/Versions/B/Autoupdate"
cp "$w/bin/plain" "$fw/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
ln -s B "$fw/Versions/Current"; ln -s Versions/Current/Sparkle "$fw/Sparkle"
ln -s Versions/Current/Resources "$fw/Resources"; ln -s Versions/Current/XPCServices "$fw/XPCServices"
pb "$fw/Versions/B/Resources/Info.plist" 'Add :CFBundleIdentifier string org.sparkle-project.Sparkle' \
  'Add :CFBundleExecutable string Sparkle' 'Add :CFBundlePackageType string FMWK'
pb "$fw/Versions/B/XPCServices/Downloader.xpc/Contents/Info.plist" 'Add :CFBundleIdentifier string org.sparkle-project.Downloader' \
  'Add :CFBundleExecutable string Downloader' 'Add :CFBundlePackageType string XPC!'
pb "$app/Contents/Info.plist" "Add :CFBundleIdentifier string $id" 'Add :CFBundleExecutable string Juice' \
  'Add :CFBundleName string Juice' 'Add :CFBundlePackageType string APPL' 'Add :LSMinimumSystemVersion string 26.0' \
  'Add :CFBundleShortVersionString string 0.0.0' 'Add :CFBundleVersion string 1' \
  "Add :SUFeedURL string ${FAKE_BUILD_FEED:-https://github.com/$PUBLIC_REPO/releases/latest/download/appcast.xml}"
[[ -n "${FAKE_BUILD_NO_EDKEY-}" ]] || pb "$app/Contents/Info.plist" "Add :SUPublicEDKey string $FAKE_APP_KEY"
[[ -z "${FAKE_BUILD_HOME-}" ]] || pb "$app/Contents/Info.plist" "Add :JIRepoPath string $HOME/src"
ents=$w/build-ents; rm -rf "$ents"; mkdir -p "$ents"
pb "$ents/app.plist" 'Add :com.apple.security.application-groups array' \
  "Add :com.apple.security.application-groups:0 string $team.$id" 'Add :com.apple.security.get-task-allow bool true'
[[ -n "${FAKE_BUILD_NO_APPLE_EVENTS-}" ]] || pb "$ents/app.plist" 'Add :com.apple.security.automation.apple-events bool true'
signed=("$fw/Versions/B/XPCServices/Downloader.xpc" "$fw/Versions/B/Autoupdate" "$fw" "$app/Contents/Helpers/OpenIslandHooks")
if [[ -z "${FAKE_BUILD_NO_WIDGET-}" ]]; then
  wx=$app/Contents/PlugIns/JuiceWidget.appex
  mkdir -p "$wx/Contents/MacOS"
  cp "$w/bin/stub" "$wx/Contents/MacOS/JuiceWidget"
  pb "$wx/Contents/Info.plist" "Add :CFBundleIdentifier string $id.widget" 'Add :CFBundleExecutable string JuiceWidget' \
    'Add :CFBundlePackageType string XPC!' 'Add :CFBundleShortVersionString string 0.0.0' 'Add :CFBundleVersion string 1'
  pb "$ents/widget.plist" 'Add :com.apple.security.app-sandbox bool true' 'Add :com.apple.security.application-groups array' \
    "Add :com.apple.security.application-groups:0 string $team.$id" 'Add :com.apple.security.get-task-allow bool true'
fi
for p in "${signed[@]}"; do codesign --force --sign - "$p" 2>/dev/null; done
[[ -n "${FAKE_BUILD_NO_WIDGET-}" ]] || codesign --force --sign - --entitlements "$ents/widget.plist" "$wx" 2>/dev/null
codesign --force --sign - --entitlements "$ents/app.plist" "$app" 2>/dev/null
print -r -- "$app"
EOF
chmod +x "$W/bin/fake-build"

export PUBLIC_REPO=$R FAKE_APP_KEY=$KEY
export JI_RELEASE_BUILD_CMD="zsh ${(q)W}/bin/fake-build"
export JI_RELEASE_TOOLS="zsh ${(q)repo}/scripts/release-fake.zsh"
export JI_RELEASE_FAKE_LOG=$W/calls
export JI_SIGNING_FILE=$W/signing.xcconfig
print -r -- "// test signing file, as the public build reads it too
DEVELOPMENT_TEAM = ABCDE12345   // the team
CODE_SIGN_IDENTITY = Developer ID Application: Test Person (ABCDE12345)
SPARKLE_PUBLIC_ED_KEY = $KEY" > "$JI_SIGNING_FILE"

# The Homebrew tap's clone beside the repository, where release.sh looks for it: --check and --publish need it (P990).
# Each run starts with its Casks folder gone, as after the owner committed the last cask, unless keep_tap is set.
tap=$W/homebrew-tap
git init -q -b main "$tap"
git -C "$tap" remote add origin https://github.com/example/homebrew-tap.git
print -r -- "tap" > "$tap/README.md"; git -C "$tap" add README.md; git -C "$tap" commit -q -m "Start the tap"
keep_tap=

passed=0 failed=0 case=
check() {
  local name=$1; shift
  if "$@"; then passed=$(( passed + 1 )); else failed=$(( failed + 1 )); print "FAIL $case: $name"; fi
}
knobs=(FAKE_NO_IDENTITY FAKE_SIGN_FAIL FAKE_NO_RUNTIME FAKE_NO_TIMESTAMP FAKE_NOTARY FAKE_NO_SPARKLE_KEY FAKE_SPARKLE_KEY
       FAKE_GH FAKE_GH_HEAD FAKE_GH_LATEST FAKE_GH_LATEST_SHA FAKE_BUILD_FAIL FAKE_BUILD_HOME FAKE_BUILD_THIN_HELPER
       FAKE_BUILD_NO_APPLE_EVENTS FAKE_BUILD_TEAM FAKE_BUILD_NO_WIDGET FAKE_BUILD_FEED FAKE_BUILD_NO_EDKEY
       FAKE_BUILD_NO_LICENSE FAKE_BUILD_NOTICE FAKE_LIPO_DROP)
start() {
  case=$1
  print -r -- "-- $case"
  unset $knobs
  git -C "$repo" clean -qfdx -e output
}
# Runs release.sh from the repository, with the stand-ins' log and notes and the build's log new; its output in
# $W/out, its status in $rc.
release() {
  [[ -n $keep_tap ]] || rm -rf "$tap/Casks"
  rm -f "$W"/calls(N) "$W"/calls.*(N) "$W/build.calls"; : > "$W/calls"; : > "$W/build.calls"
  rc=0; (cd "$repo" && zsh scripts/release.sh "$@") > "$W/out" 2>&1 || rc=$?
}
said() { grep -qF -- "$1" "$W/out" }
not_said() { ! grep -qF -- "$1" "$W/out" }
called() { grep -qE -- "$1" "$W/calls" }
not_called() { ! grep -qE -- "$1" "$W/calls" }
line_of() { local hits; hits=$(grep -nE -- "$1" "$W/calls" || true); hits=${hits%%$'\n'*}; print -r -- "${hits%%:*}" }
before() { local a=$(line_of "$1") b=$(line_of "$2"); [[ -n $a && -n $b ]] && (( a < b )) }
built() { [[ -s "$W/build.calls" ]] }
not_built() { [[ ! -s "$W/build.calls" ]] }
outdir=$repo/output/release.noindex/$version
dmg=$outdir/Juice-$version.dmg
work_app=$outdir/work/Juice.app
plist_of() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" }
count() { git -C "$repo" rev-list --count HEAD }
signed_items() { grep -E '^codesign .*--sign ' "$W/calls" | awk '{print $NF}' }
# A finished DMG as Finder would find it: mounted read-only under $W, its .DS_Store read by the release's own layout tool,
# and what is on the volume. Writes $W/dmg-shows.
dmg_shows() {
  local at=$W/mnt-$(( ++mounts )) tool
  tool=($repo/output/release.noindex/tools/dmg-layout-*(N.x))
  mkdir -p "$at"
  hdiutil attach -quiet -nobrowse -noautoopen -noverify -readonly -mountpoint "$at" "$1" || { : > "$W/dmg-shows"; return 1 }
  {
    "${tool[1]}" --read "$at/.DS_Store"
    print -l -- "${(@f)$(ls -A "$at")}"
    [[ ! -L $at/Applications || "$(readlink "$at/Applications")" != /Applications ]] || print -r -- "link to /Applications"
    [[ ! -s $at/.background/background.tiff ]] || print -r -- "background $(tiffutil -info "$at/.background/background.tiff" 2>/dev/null | grep -c 'Image Width')"
    print -r -- "names this run's folders: $(LC_ALL=C grep -c -aF -- "$W" "$at/.DS_Store" || true)"
  } > "$W/dmg-shows" 2>&1
  hdiutil detach -quiet "$at" 2>/dev/null || hdiutil detach -quiet -force "$at"
}
mounts=0
shows() { grep -qE -- "$1" "$W/dmg-shows" }
cask_has() { grep -qxF -- "$1" "$outdir/Casks/juiceisland.rb" }

# --- local --------------------------------------------------------------------------------------------------------
start "local: signs inside out and stops at a signed DMG"
release
check "succeeds" [ $rc -eq 0 ]
check "built the public flavor once, universal, ad hoc, with the version and build number" \
  [ "$(cat "$W/build.calls")" = "build --public --universal $outdir/work/build identity=- version=$version number=$(git -C "$repo" rev-list --count HEAD)" ]
check "a DMG" [ -s "$dmg" ]
check "says how to publish" said "--publish notarizes and releases"
check "nothing outward: no notarytool" not_called '^notarytool '
check "nothing outward: no stapler" not_called '^stapler '
check "nothing outward: no Sparkle tool" not_called '^(sign_update|generate_keys) '
check "nothing outward: no gh" not_called '^gh '
items=(${(f)"$(signed_items)"})
check "signs seven parts, the DMG last" [ "${#items}" -eq 7 -a "${items[-1]}" = "$dmg" ]
check "the app is the last part before the DMG" [ "${items[-2]}" = "$work_app" ]
check "the XPC service before its framework" before 'Downloader\.xpc$' 'Sparkle\.framework$'
check "Autoupdate before its framework" before 'Autoupdate$' 'Sparkle\.framework$'
check "the widget and the helper before the app" \
  eval 'before "JuiceWidget\.appex$" "Juice\.app$" && before "OpenIslandHooks$" "Juice\.app$"'
check "every part with the Developer ID's SHA-1, the hardened runtime and a timestamp" \
  [ "$(grep -E '^codesign .*--sign ' "$W/calls" | grep -v '\.dmg$' | grep -cE -- '^codesign --force --sign 2{40} --options runtime --timestamp ')" -eq 6 ]
check "the DMG with a timestamp, not the runtime" called "^codesign --force --sign 2{40} --timestamp $dmg\$"
check "never --deep when signing" not_called '^codesign .*--sign .*--deep'
ent_app=$(grep -E "^codesign .*--sign .*Juice\.app\$" "$W/calls" | sed -E 's/.*--entitlements ([^ ]+) .*/\1/')
ent_widget=$(grep -E "^codesign .*--sign .*JuiceWidget\.appex\$" "$W/calls" | sed -E 's/.*--entitlements ([^ ]+) .*/\1/')
check "the app keeps its own entitlements, less get-task-allow" \
  eval '[[ -f $ent_app ]] && ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$ent_app" >/dev/null 2>&1 &&
        [[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.automation.apple-events" "$ent_app")" == true ]]'
check "the widget keeps its sandbox, less get-task-allow" \
  eval '[[ -f $ent_widget ]] && ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$ent_widget" >/dev/null 2>&1 &&
        [[ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ent_widget")" == true ]]'
check "the app says VERSION and the commit count" \
  [ "$(plist_of "$work_app" CFBundleShortVersionString) $(plist_of "$work_app" CFBundleVersion)" = "$version $(count)" ]
check "so does the widget" \
  [ "$(plist_of "$work_app/Contents/PlugIns/JuiceWidget.appex" CFBundleShortVersionString) $(plist_of "$work_app/Contents/PlugIns/JuiceWidget.appex" CFBundleVersion)" = "$version $(count)" ]
check "the build folder's path left with the symbols" eval '! grep -rqF -- "$HOME/" "$work_app"'
check "Sparkle's own binaries are left as they are" \
  cmp -s "$outdir/work/build/Juice.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" "$work_app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
check "spctl may only say it is not notarized yet" called "^spctl --assess --type execute -vv $work_app\$"
check "the DMG holds the app and an Applications link" eval '[[ -L $outdir/work/dmg/Applications && -d $outdir/work/dmg/Juice.app ]]'
dmg_shows "$dmg"
check "the DMG mounts, and its read-write image is gone" eval '[[ -s $W/dmg-shows && ! -e $outdir/work/rw.dmg ]]'
check "nothing of the run is left mounted" eval '! hdiutil info | grep -qF -- "$outdir/work/rw.dmg"'
check "its window: no toolbar or sidebar, 660 by 400" shows '^\. bwsp blob .*ShowSidebar=0 .*ShowToolbar=0 .*WindowBounds=\{\{200,120\},\{660,400\}\}'
check "an icon view of 128-point icons over the background picture" shows '^\. icvp blob .*backgroundImageAlias backgroundType=2 .*iconSize=128 '
check "the app on the left, Applications on the right, on the arrow's line" eval 'shows "^Juice\.app Iloc blob 16 170,190$" && shows "^Applications Iloc blob 16 490,190$"'
check "the picture in both sizes, the app and the Applications link" eval 'shows "^background 2$" && shows "^link to /Applications$" && shows "^Juice\.app$"'
check "no system bookmark of the picture, which would name this Mac" eval '! shows " pBBk "'
check "the layout names no folder of this run" shows "^names this run's folders: 0$"

start "local: a new commit raises the build number"
before_count=$(count)
print -r -- "x" > "$repo/raise.txt"; git -C "$repo" add raise.txt; git -C "$repo" commit -q -m "Raise the count"
release
check "succeeds" [ $rc -eq 0 ]
check "the build number is the new count" [ "$(plist_of "$work_app" CFBundleVersion)" = "$(( before_count + 1 ))" ]
git -C "$repo" reset -q --hard HEAD~1

start "local: what the build must not carry"
for knob message in \
  FAKE_BUILD_HOME "name your home folder, which would publish your user name: Contents/Info.plist" \
  FAKE_BUILD_THIN_HELPER "these lack a slice: Contents/Helpers/OpenIslandHooks (no x86_64)." \
  FAKE_BUILD_NO_APPLE_EVENTS "lack com.apple.security.automation.apple-events" \
  FAKE_BUILD_NO_WIDGET "the app has no widget" \
  FAKE_BUILD_NO_LICENSE "the app does not carry Contents/Resources/LICENSE.txt" \
  FAKE_BUILD_NOTICE "NOTICE.txt still has fields the export fills in" \
  FAKE_BUILD_FEED "the app looks for updates at https://github.com/someone/else/releases/latest/download/appcast.xml"
do
  export $knob=1; [[ $knob != FAKE_BUILD_FEED ]] || export FAKE_BUILD_FEED=https://github.com/someone/else/releases/latest/download/appcast.xml
  [[ $knob != FAKE_BUILD_NOTICE ]] || export FAKE_BUILD_NOTICE="Copyright (C) @YEAR@ @AUTHOR@, with Sparkle"
  release
  unset $knob
  check "$knob: refused" [ $rc -eq 1 ]
  check "$knob: says why" said "$message"
  check "$knob: signs nothing" not_called '^codesign .*--sign '
done
export FAKE_BUILD_TEAM=ZZZZZ99999
release
check "another team's App Group: refused" eval '[ $rc -eq 1 ] && said "App Group is ZZZZZ99999.com.example.juice, not one of team ABCDE12345"'
unset FAKE_BUILD_TEAM

start "local: every Mach-O needs both slices, Sparkle's too, and each one missing is named"
release
check "a universal app passes" eval '[ $rc -eq 0 ] && not_said "lack a slice"'
export FAKE_LIPO_DROP="x86_64:Sparkle.framework/Versions/B/Autoupdate arm64:Contents/MacOS/Juice x86_64:JuiceWidget.appex/Contents/MacOS/JuiceWidget"
release
unset FAKE_LIPO_DROP
check "refused" [ $rc -eq 1 ]
check "names Sparkle's part" said "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate (no x86_64)"
check "names the app's own executable" said "Contents/MacOS/Juice (no arm64)"
check "names the widget" said "Contents/PlugIns/JuiceWidget.appex/Contents/MacOS/JuiceWidget (no x86_64)"
check "names nothing that has both" eval 'not_said "Contents/Helpers/OpenIslandHooks (no" && not_said "Versions/B/Sparkle (no"'
check "says how to build it" said "Build every part for both, as zsh scripts/build-app.sh --public --universal does."
check "signs nothing" not_called '^codesign .*--sign '
check "makes no DMG" [ ! -e "$dmg" ]
FAKE_LIPO_DROP="x86_64:Sparkle.framework/Versions/B/Autoupdate" release --publish
check "--publish: refused before notarizing" eval '[ $rc -eq 1 ] && said "Autoupdate (no x86_64)" && not_called "^notarytool submit "'

start "local: a signature without the runtime or a timestamp is refused"
FAKE_NO_RUNTIME=1 release
check "no runtime: refused before the DMG" eval '[ $rc -eq 1 ] && said "has no hardened runtime" && [ ! -e "$dmg" ]'
FAKE_NO_TIMESTAMP=1 release
check "no timestamp: refused before the DMG" eval '[ $rc -eq 1 ] && said "has no secure timestamp" && [ ! -e "$dmg" ]'
FAKE_SIGN_FAIL=1 release
check "codesign failing stops the run" eval '[ $rc -eq 1 ] && said "codesign could not sign"'
FAKE_BUILD_FAIL=1 release
check "a failed build stops the run" eval '[ $rc -eq 1 ] && said "the build failed"'

# --- publish ------------------------------------------------------------------------------------------------------
start "publish: notarizes the app, staples it, then the DMG, signs the update and releases"
prev=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q -b side
print -r -- "side" > "$repo/side.txt"; git -C "$repo" add side.txt; git -C "$repo" commit -q -m "Show the side change"
git -C "$repo" checkout -q main
print -r -- "y" > "$repo/notes.txt"; git -C "$repo" add notes.txt
git -C "$repo" commit -q -m 'Keep "quotes" & <tags> ]]> in the notes'
git -C "$repo" merge -q --no-ff -m "Merge the side branch" side
export FAKE_GH_LATEST=v0.0.1 FAKE_GH_LATEST_SHA=$prev
release --publish
head=$(git -C "$repo" rev-parse HEAD)
check "succeeds" [ $rc -eq 0 ]
check "says where" said "released: https://github.com/$R/releases/tag/v$version"
check "preflight asks for the notary profile" called '^notarytool history --keychain-profile juice-notary --output-format json$'
check "preflight asks gh who is signed in" called '^gh auth status --hostname github\.com$'
gh_calls=$(grep "^gh " "$W/calls" | grep -v "^gh auth " || true)
check "every other gh call names the repository" eval '[[ -n $gh_calls && -z "$(print -r -- "$gh_calls" | grep -vE -- "(--repo $R|repos/$R/| view $R )" || true)" ]]'
check "notarizes the zipped app first, as the brief says" \
  called "^notarytool submit $outdir/work/Juice\\.zip --keychain-profile juice-notary --wait --output-format json\$"
check "the zip is the app, made by ditto" eval '[[ "$(unzip -l "$outdir/work/Juice.zip")" == *"Juice.app/Contents/Info.plist"* ]]'
check "staples and checks the app" eval 'before "^notarytool submit .*Juice\.zip" "^stapler staple $work_app\$" && called "^stapler validate $work_app\$"'
check "spctl accepts the stapled app" before "^stapler validate $work_app\$" "^spctl --assess --type execute -vv $work_app\$"
check "the DMG is made after the app is stapled" before "^stapler staple $work_app\$" "^codesign --force --sign 2{40} --timestamp $dmg\$"
check "notarizes the signed DMG" \
  before "^codesign --force --sign 2{40} --timestamp $dmg\$" "^notarytool submit $dmg --keychain-profile juice-notary --wait --output-format json\$"
check "staples the DMG after that" before "^notarytool submit $dmg" "^stapler staple $dmg\$"
check "spctl accepts the DMG" called "^spctl --assess --type open --context context:primary-signature -vv $dmg\$"
check "Sparkle signs the stapled DMG" before "^stapler validate $dmg\$" "^sign_update $dmg\$"
check "the release comes last" before "^sign_update " "^gh release create "
check "the release: tag, assets, repository, commit, title, notes, latest" called \
  "^gh release create v$version $dmg $outdir/Juice\\.dmg $outdir/appcast\\.xml --repo $R --target $head --title Juice $version --notes-file $outdir/notes\\.md --latest\$"
check "Juice.dmg is the notarized DMG, byte for byte" cmp -s "$dmg" "$outdir/Juice.dmg"
check "the stable name is copied after stapling" eval '[[ -n "$(grep -xF -- "$dmg" "$W/calls.stapled")" ]]'
check "the cask: the version and the DMG's SHA-256" eval 'cask_has "  version \"$version\"" && cask_has "  sha256 \"$(shasum -a 256 "$dmg" | cut -d" " -f1)\""'
check "the cask downloads the versioned DMG" cask_has "  url \"https://github.com/$R/releases/download/v#{version}/Juice-#{version}.dmg\""
check "the cask: auto_updates, a livecheck on the latest release, macOS 26" \
  eval 'cask_has "  auto_updates true" && cask_has "    strategy :github_latest" && cask_has "  depends_on macos: \">= :tahoe\""'
check "the cask zaps the app's own folders, read from the built app" \
  eval 'cask_has "    \"~/Library/Application Support/com.example.juice\"," && cask_has "    \"~/Library/Group Containers/ABCDE12345.com.example.juice\"," && cask_has "    \"~/Library/Containers/com.example.juice.widget\"," && cask_has "  uninstall quit: \"com.example.juice\""'
check "the cask is valid Ruby" ruby -c "$outdir/Casks/juiceisland.rb"
check "the cask goes into the tap's clone" cmp -s "$tap/Casks/juiceisland.rb" "$outdir/Casks/juiceisland.rb"
check "reads the release back" called "^gh release view v$version --repo $R --json assets"
check "no tag in this repository" [ -z "$(git -C "$repo" tag -l 'v*')" ]
appcast=$outdir/appcast.xml
check "the appcast is valid XML" /usr/bin/xmllint --noout "$appcast"
fields=$(python3 - "$appcast" <<'EOF'
import sys, xml.etree.ElementTree as ET
s = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(sys.argv[1]).getroot().findall('channel/item')
item = items[0]
e = item.find('enclosure')
print(len(items))
print(item.find(s + 'version').text)
print(item.find(s + 'shortVersionString').text)
print(item.find(s + 'minimumSystemVersion').text)
print(e.get('url'))
print(e.get('length'))
print(e.get(s + 'edSignature'))
print(item.find('description').text)
EOF
)
f=(${(f)fields})
check "one item" [ "$f[1]" = 1 ]
check "the build number, as the app in the DMG says" eval '[ "$f[2]" = "$(count)" ] && [ "$f[2]" = "$(plist_of "$outdir/work/dmg/Juice.app" CFBundleVersion)" ]'
check "the version" [ "$f[3]" = "$version" ]
check "the minimum system" [ "$f[4]" = 26.0 ]
check "the download" [ "$f[5]" = "https://github.com/$R/releases/download/v$version/Juice-$version.dmg" ]
check "the DMG's length" [ "$f[6]" = "$(stat -f %z "$dmg")" ]
check "Sparkle's signature" [ "$f[7]" = "$SIG" ]
check "the notes name the system and both chips" \
  eval '[[ ${(F)f[8,-1]} == *"Needs macOS 26 or later, on Apple silicon or Intel. Tested on macOS "* ]]'
check "the notes keep the commits since the last release, escaped" \
  eval '[[ ${(F)f[8,-1]} == *"<li>Keep &quot;quotes&quot; &amp; &lt;tags&gt; ]]&gt; in the notes</li>"* ]]'
check "the notes leave merges out" eval '[[ ${(F)f[8,-1]} != *"Merge the side branch"* && ${(F)f[8,-1]} == *"Show the side change"* ]]'
check "the notes leave out what came before the last release" eval '[[ ${(F)f[8,-1]} != *"Scripts under test"* ]]'
check "GitHub's notes are the same, in Markdown" eval 'grep -qxF -- "- Keep \"quotes\" & <tags> ]]> in the notes" "$outdir/notes.md"'

start "publish: the first release says so, and --notes replaces the subjects"
release --publish
check "first release" eval '[ $rc -eq 0 ] && grep -qxF "The first release." "$outdir/notes.md"'
print -r -- "- Fixes the widget & more" > "$W/notes.md"
release --publish --notes "$W/notes.md"
check "notes from the file" eval '[ $rc -eq 0 ] && grep -qxF -- "- Fixes the widget & more" "$outdir/notes.md" && grep -qF "<li>Fixes the widget &amp; more</li>" "$outdir/appcast.xml"'

start "publish: a headline names the release, and leaves the notes"
print -l "# Answer Copilot from the notch" "" "- Copilot CLI's prompts in the island" > "$W/notes.md"
release --publish --notes "$W/notes.md"
check "succeeds" [ $rc -eq 0 ]
check "titled by it" called "--title Juice $version: Answer Copilot from the notch --notes-file "
check "the notes start after it" eval '[[ "$(sed -n 3p "$outdir/notes.md")" == "- Copilot CLI'"'"'s prompts in the island" ]] && ! grep -q "^# " "$outdir/notes.md"'

start "publish: a release that lost Juice.dmg is caught"
FAKE_GH=no-stable release --publish
check "refused after the upload, saying what is missing" eval '[ $rc -eq 1 ] && said "has no Juice.dmg"'

start "publish: the cask goes into the tap's clone, uncommitted, with the commands that publish it"
(unset JI_RELEASE_TOOLS JI_RELEASE_FAKE_LOG; release --dry-run; print -r -- $rc > "$W/rc")
check "a dry run leaves the tap alone" eval '[ $(<"$W/rc") -eq 0 ] && [ ! -e "$tap/Casks" ] && said "a real release would put it in $tap/Casks"'
release --publish
check "succeeds" [ $rc -eq 0 ]
check "the cask is in the tap" cmp -s "$tap/Casks/juiceisland.rb" "$outdir/Casks/juiceisland.rb"
check "nothing is committed or pushed there" [ "$(git -C "$tap" rev-list --count HEAD)" = 1 ]
check "says how to publish it" said "commit -m \"juiceisland $version\" && git -C $tap push"
keep_tap=1 release --check
check "a tap with changes in Casks stops the next release" eval '[ $rc -eq 1 ] && said "has changes in Casks that are not committed"'
git -C "$tap" remote set-url origin https://github.com/someone/other-tap.git
release --check
check "a clone of another repository is refused" eval '[ $rc -eq 1 ] && said "not of example/homebrew-tap"'
git -C "$tap" remote set-url origin https://github.com/example/homebrew-tap.git
# The README's first install line reads the tap: no release goes out before it exists (P990).
mv "$tap" "$W/tap-away"
release --check
check "no tap clone: --check refuses, with the commands that make it" \
  eval '[ $rc -eq 1 ] && said "gh repo create example/homebrew-tap --public" && said "git clone https://github.com/example/homebrew-tap.git $tap"'
release --publish
check "no tap clone: --publish stops before building" eval '[ $rc -eq 1 ] && said "No clone of example/homebrew-tap" && not_built'
(unset JI_RELEASE_TOOLS JI_RELEASE_FAKE_LOG; release --dry-run; print -r -- $rc > "$W/rc")
check "no tap clone: a dry run lists it and goes on" \
  eval '[ $(<"$W/rc") -eq 0 ] && said "1 thing would stop a real release" && said "No clone of example/homebrew-tap"'
mv "$W/tap-away" "$tap"

start "local: another disk named Juice takes /Volumes/Juice"
hdiutil create -quiet -volname Juice -size 1m -fs HFS+ "$W/other.dmg"
other=$(hdiutil attach -nobrowse -noautoopen -noverify "$W/other.dmg" | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)
release
check "refused, saying what to eject" eval '[ $rc -eq 1 ] && said "another disk named Juice is mounted"'
check "and its own image is unmounted" eval '! hdiutil info | grep -qF -- "$outdir/work/rw.dmg"'
[[ -z $other ]] || hdiutil detach -quiet "$other" || hdiutil detach -quiet -force "$other"
rm -f "$W/other.dmg"

start "publish: Apple refusing the app stops everything after it"
FAKE_NOTARY=invalid release --publish
check "refused" [ $rc -eq 1 ]
check "says so and keeps Apple's reasons" eval 'said "Apple did not notarize Juice.zip (Invalid)" && [ -s "$outdir/work/notary-log-Juice.zip.json" ]'
check "nothing stapled, signed for Sparkle or released" eval 'not_called "^stapler " && not_called "^sign_update " && not_called "^gh release create "'

start "publish: a line of progress before notarytool's answer"
FAKE_NOTARY=chatty release --publish
check "still reads Accepted" eval '[ $rc -eq 0 ] && called "^gh release create "'

start "publish: the keychain's Sparkle key must be the app's"
OTHER_KEY=anVpY2UtcmVsZWFzZS1mYWtlLW90aGVyLWtleS0wMzI=
FAKE_SPARKLE_KEY=$OTHER_KEY release --publish
check "the signing file's key is not the keychain's: refused before building" \
  eval '[ $rc -eq 1 ] && said "is not the public key of the Sparkle key in your keychain" && not_built && not_called "^notarytool submit "'
(export FAKE_APP_KEY=$OTHER_KEY; release --publish; print -r -- $rc > "$W/rc")
rc=$(<"$W/rc")
check "an app that carries another key: refused before signing or notarizing" \
  eval '[ $rc -eq 1 ] && said "is not the one the app carries" && not_called "^codesign .*--sign " && not_called "^notarytool submit "'
FAKE_BUILD_NO_EDKEY=1 release --publish
check "an app with no key is refused" eval '[ $rc -eq 1 ] && said "carries no Sparkle public key" && not_called "^notarytool submit "'

start "publish: notes that would say only what the export says are refused without --notes"
prev=$(git -C "$repo" rev-parse HEAD)
print -r -- "z" > "$repo/export.txt"; git -C "$repo" add export.txt; git -C "$repo" commit -q -m "Update the Juice source for 9.9.9"
export FAKE_GH_LATEST=v0.0.1 FAKE_GH_LATEST_SHA=$prev
release --publish
check "refused before building, saying how" \
  eval '[ $rc -eq 1 ] && said "would say nothing" && said "--notes <file>" && not_built'
print -r -- "- Fixes the widget" > "$W/notes.md"
release --publish --notes "$W/notes.md"
check "with --notes it goes on" eval '[ $rc -eq 0 ] && grep -qxF -- "- Fixes the widget" "$outdir/notes.md"'
git -C "$repo" reset -q --hard HEAD~1

start "publish: refuses the wrong repository, commit, tag or version, before building"
for knobs_set message in \
  "FAKE_GH=private" "$R is private" \
  "FAKE_GH=no-repo" "GitHub has no repository $R" \
  "FAKE_GH_HEAD=0000000000000000000000000000000000000000" "is not the head of $R's main (0000000)" \
  "FAKE_GH=tag-exists" "v$version is already on $R" \
  "FAKE_GH_LATEST=v9.0.0 FAKE_GH_LATEST_SHA=$(git -C "$repo" rev-parse HEAD~1)" "VERSION ($version) is not above the last release, v9.0.0" \
  "FAKE_GH_LATEST=v0.0.1 FAKE_GH_LATEST_SHA=$(git -C "$repo" rev-parse HEAD)" "does not come after the last release's" \
  "FAKE_GH_LATEST=v0.0.1 FAKE_GH_LATEST_SHA=1111111111111111111111111111111111111111" "does not come after the last release's"
do
  (export ${=knobs_set}; release --publish; print -r -- $rc > "$W/rc")
  rc=$(<"$W/rc")
  check "$knobs_set: refused" [ $rc -eq 1 ]
  check "$knobs_set: says why" said "$message"
  check "$knobs_set: builds nothing, releases nothing" eval 'not_built && not_called "^gh release create "'
done
FAKE_GH=create-fails release --publish
check "a failed upload says where the DMG is" eval '[ $rc -eq 1 ] && said "gh could not create the release" && said "$outdir"'

# --- preflight ----------------------------------------------------------------------------------------------------
start "preflight: lists everything missing at once, with the commands that make each"
print -r -- "dirty" > "$repo/untracked.txt"
FAKE_NO_IDENTITY=1 FAKE_NOTARY=missing FAKE_NO_SPARKLE_KEY=1 FAKE_GH=logged-out release --check
check "refused" [ $rc -eq 1 ]
check "five things" eval 'said "preflight: 5 things to fix first" && grep -qx "5\. .*" "$W/out"'
check "the identity, and how to make it" eval 'said "No Developer ID Application identity for team ABCDE12345" && said "Manage Certificates > + > Developer ID Application"'
check "the notary profile, and the exact command" said "xcrun notarytool store-credentials juice-notary --apple-id <your Apple Account email> --team-id ABCDE12345"
check "the Sparkle key, and generate_keys" eval 'said "No Sparkle signing key is in your keychain" && said "generate_keys\" -x <file>"'
check "gh, and how to sign in" said "gh auth login --hostname github.com --web"
check "a clean export" said "This folder has changes that are not committed"
check "builds and signs nothing" eval 'not_built && not_called "^codesign "'
rm -f "$repo/untracked.txt"
JI_SIGNING_FILE=$W/none.xcconfig release --check
check "no signing file: how to make it" eval '[ $rc -eq 1 ] && said "DEVELOPMENT_TEAM = <team id>" && said "CODE_SIGN_IDENTITY = Developer ID Application: <your name> (<team id>)" && said "security find-identity -v -p codesigning"'
print -r -- "DEVELOPMENT_TEAM = ABCDE12345" > "$W/team-only.xcconfig"
JI_SIGNING_FILE=$W/team-only.xcconfig release --check
check "a signing file the public build refuses stops the preflight, with its reason" \
  eval '[ $rc -eq 1 ] && said "The public build refuses" && said "CODE_SIGN_IDENTITY is not" && not_built'
print -r -- $'DEVELOPMENT_TEAM = ABCDE12345\nCODE_SIGN_IDENTITY = Developer ID Application: Someone Else (ABCDE12345)' > "$W/other-id.xcconfig"
JI_SIGNING_FILE=$W/other-id.xcconfig release --check
check "CODE_SIGN_IDENTITY names the release's identity" eval '[ $rc -eq 1 ] && said "names \"Developer ID Application: Someone Else (ABCDE12345)\""'
print -r -- $'DEVELOPMENT_TEAM = ABCDE12345\nCODE_SIGN_IDENTITY = Developer ID Application: Test Person (ABCDE12345)\nPUBLIC_REPO = example/from-the-file' > "$W/repo.xcconfig"
(unset PUBLIC_REPO; JI_SIGNING_FILE=$W/repo.xcconfig FAKE_GH=no-repo release --check; print -r -- $rc > "$W/rc")
check "PUBLIC_REPO from the signing file, through the build's resolver" eval '[ $(<"$W/rc") -eq 1 ] && said "no repository example/from-the-file"'
FAKE_NOTARY=missing release --publish
check "--publish stops at the preflight" eval '[ $rc -eq 1 ] && not_built'
print -r -- $'DEVELOPMENT_TEAM = ABCDE12345\nCODE_SIGN_IDENTITY = Developer ID Application: Test Person (ABCDE12345)' > "$W/no-key.xcconfig"
JI_SIGNING_FILE=$W/no-key.xcconfig release --check
check "no SPARKLE_PUBLIC_ED_KEY: the line to add" eval '[ $rc -eq 1 ] && said "has no SPARKLE_PUBLIC_ED_KEY line" && said "SPARKLE_PUBLIC_ED_KEY = $KEY"'
print -r -- $'DEVELOPMENT_TEAM = ABCDE12345\nCODE_SIGN_IDENTITY = Developer ID Application: Test Person (ABCDE12345)\nSPARKLE_PUBLIC_ED_KEY = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' > "$W/other-key.xcconfig"
JI_SIGNING_FILE=$W/other-key.xcconfig release --check
check "a key that is not the keychain's: refused" eval '[ $rc -eq 1 ] && said "is not the public key of the Sparkle key in your keychain"'
print -r -- "Get it from https://github.com/example/other/releases/latest or git clone https://github.com/example/other.git" > "$repo/README.md"
release --check
check "a README that links to another repository" eval '[ $rc -eq 1 ] && said "README.md links to example/other, but this release goes to $R"'
git -C "$repo" checkout -q -- README.md
release --check
check "--check passes when all is there, building nothing" eval '[ $rc -eq 0 ] && said "ready to publish v$version" && not_built'
FAKE_NO_IDENTITY=1 release
check "a local run needs the identity too" eval '[ $rc -eq 1 ] && not_built'
FAKE_NOTARY=missing FAKE_GH=logged-out release
check "a local run needs no notary profile or gh" eval '[ $rc -eq 0 ] && not_called "^(notarytool|gh) "'

start "arguments and VERSION"
release --publish --dry-run
check "--publish with --dry-run is refused" [ $rc -eq 2 ]
release --bogus
check "an unknown argument is refused" [ $rc -eq 2 ]
print -r -- "../1.2" > "$repo/VERSION"; git -C "$repo" commit -q -am "Bad version"
release --check
check "a VERSION that is not x.y.z" eval '[ $rc -eq 1 ] && said "VERSION should hold one version, like 1.2.0"'
git -C "$repo" reset -q --hard HEAD~1

# --- dry run ------------------------------------------------------------------------------------------------------
start "dry run: the whole publish with stand-ins, nothing outward"
dry=$repo/output/release.noindex/dry-run
(unset JI_RELEASE_TOOLS JI_RELEASE_FAKE_LOG; release --dry-run; print -r -- $rc > "$W/rc")
rc=$(<"$W/rc")
check "succeeds" [ $rc -eq 0 ]
check "says nothing was sent" said "dry run finished: nothing was signed, sent or uploaded"
check "nothing would stop a real release" not_said "would stop a real release"
check "its own stand-ins took every call" eval '[ -s "$dry/dry-run-calls" ] && [ ! -s "$W/calls" ]'
check "it went as far as the release" grep -qE "^gh release create v$version " "$dry/dry-run-calls"
check "a DMG and an appcast" eval '[ -s "$dry/Juice-$version.dmg" ] && /usr/bin/xmllint --noout "$dry/appcast.xml"'
check "Juice.dmg and the cask too" eval 'cmp -s "$dry/Juice-$version.dmg" "$dry/Juice.dmg" && ruby -c "$dry/Casks/juiceisland.rb" >/dev/null'
check "nothing was signed for real" eval '[[ "$(codesign -dv "$dry/work/Juice.app" 2>&1)" != *Authority=* ]]'
(unset JI_RELEASE_TOOLS JI_RELEASE_FAKE_LOG; export FAKE_BUILD_NO_APPLE_EVENTS=1 JI_SIGNING_FILE=$W/none.xcconfig
 release --dry-run; print -r -- $rc > "$W/rc")
rc=$(<"$W/rc")
check "what would stop a real release is listed, and the run goes on" \
  eval '[ $rc -eq 0 ] && said "2 things would stop a real release" && said "automation.apple-events" && said "no local signing file"'
(unset JI_RELEASE_TOOLS JI_RELEASE_FAKE_LOG; export FAKE_LIPO_DROP="x86_64:Contents/Helpers/OpenIslandHooks"
 release --dry-run; print -r -- $rc > "$W/rc")
rc=$(<"$W/rc")
check "a missing slice is listed in a dry run, which goes on" \
  eval '[ $rc -eq 0 ] && said "1 thing would stop a real release" && said "Contents/Helpers/OpenIslandHooks (no x86_64)"'

# --- build-app.sh and a renamed checkout (P1554) -----------------------------------------------------------------
# A DerivedData folder records the absolute paths it was made for. build-app.sh (which release.sh runs) drops its own one
# when any of them is outside this checkout, saying so in one line, and keeps a current one. xcodegen and xcodebuild are
# stand-ins first on PATH: xcodebuild notes whether the folder it was given still holds its marker, and fails, so no
# build runs. The folders are fakes: an info.plist and a workspace-state.json, as Xcode writes them.
start "build-app: a DerivedData folder made for another folder is removed before the build, a current one kept"
mkdir -p "$W/xcbin"
print -r -- '#!/bin/zsh
exit 0' > "$W/xcbin/xcodegen"
print -r -- '#!/bin/zsh
d=
while (( $# )); do [[ $1 == -derivedDataPath ]] && { d=$2; break }; shift; done
if [[ -e $d/marker ]]; then print -r -- "$d kept" >> "$XCB_LOG"; else print -r -- "$d gone" >> "$XCB_LOG"; fi
exit 3' > "$W/xcbin/xcodebuild"
chmod +x "$W/xcbin/xcodegen" "$W/xcbin/xcodebuild"
# <folder under output/> <its WorkspacePath> <a package artifact's path> [escaped: the path's slashes written \/]
fake_derived() {
  local d=$repo/output/$1 art=$3
  rm -rf "$d"; mkdir -p "$d/SourcePackages"; : > "$d/marker"
  /usr/libexec/PlistBuddy -c "Add :WorkspacePath string $2" "$d/info.plist" >/dev/null
  [[ -z ${4-} ]] || art=${art//\//\\/}
  print -r -- "{
  \"object\" : {
    \"artifacts\" : [
      {
        \"kind\" : { \"xcframework\" : { } },
        \"packageRef\" : { \"identity\" : \"sparkle\", \"kind\" : \"remoteSourceControl\", \"location\" : \"https://github.com/sparkle-project/Sparkle\", \"name\" : \"Sparkle\" },
        \"path\" : \"$art\",
        \"targetName\" : \"Sparkle\"
      }
    ],
    \"dependencies\" : [ ],
    \"prebuilts\" : [ ]
  },
  \"version\" : 7
}" > "$d/SourcePackages/workspace-state.json"
}
build_app() {
  rm -f "$W/xcb.log"; : > "$W/xcb.log"
  rc=0; (cd "$repo" && PATH=$W/xcbin:$PATH XCB_LOG=$W/xcb.log zsh scripts/build-app.sh "$@") > "$W/out" 2>&1 || rc=$?
}
old=/Users/someone/Developer/old-checkout
art=SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework
fake_derived dd-public.noindex "$old/Juice.xcodeproj" "$old/output/dd-public.noindex/$art"
build_app --public
check "a folder made for the old folder is removed before xcodebuild runs" \
  eval '[ ! -e "$repo/output/dd-public.noindex/marker" ] && grep -qxF "output/dd-public.noindex gone" "$W/xcb.log"'
check "says so in one line, naming the old path" \
  eval '[ "$(grep -c "^build-app: removed output/dd-public.noindex, made for another folder ($old/Juice.xcodeproj); the build makes it again\$" "$W/out")" -eq 1 ]'
check "the build went on (to the stand-in's failure)" [ $rc -eq 3 ]
fake_derived dd-public.noindex "$repo/Juice.xcodeproj" "$old/output/dd-public.noindex/$art" escaped
build_app --public
check "a current workspace whose package still points at the old folder (slashes escaped) is removed too" \
  eval 'grep -qxF "output/dd-public.noindex gone" "$W/xcb.log" && said "build-app: removed output/dd-public.noindex, made for another folder ($old/output/dd-public.noindex/$art)"'
fake_derived dd-public.noindex "$repo/Juice.xcodeproj" "$repo/output/dd-public.noindex/$art"
build_app --public
check "a folder made here is kept, and nothing is said" \
  eval 'grep -qxF "output/dd-public.noindex kept" "$W/xcb.log" && not_said "build-app: removed"'
fake_derived dd.noindex "$old/JuiceIsland.xcodeproj" "$old/output/dd.noindex/$art"
fake_derived dd-public.noindex "$old/Juice.xcodeproj" "$old/output/dd-public.noindex/$art"
build_app
check "a dev build drops its own stale folder, and only its own" \
  eval 'grep -qxF "output/dd.noindex gone" "$W/xcb.log" && [ -e "$repo/output/dd-public.noindex/marker" ] && said "build-app: removed output/dd.noindex"'
rm -rf "$repo/output/dd.noindex" "$repo/output/dd-public.noindex"
build_app --public
check "no folder at all: nothing removed, nothing said" eval 'grep -qxF "output/dd-public.noindex gone" "$W/xcb.log" && not_said "build-app: removed"'
rm -rf "$repo/output/dd.noindex" "$repo/output/dd-public.noindex" "$repo/Juice.xcodeproj" "$repo/JuiceIsland.xcodeproj"

print -r -- "release-script-test: $passed passed, $failed failed"
(( failed == 0 ))
