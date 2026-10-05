#!/bin/zsh
# Makes a release of the public app, Juice, in one command (pitfalls P830 to P839).
#
#   zsh scripts/release.sh             builds, signs and checks a DMG on this Mac, then stops. Nothing leaves the Mac
#                                      but the signing timestamp's request to Apple.
#   zsh scripts/release.sh --publish   the same, then notarizes and staples the app, makes the DMG from it,
#                                      notarizes and staples the DMG, signs it for Sparkle, writes the appcast and
#                                      creates the GitHub Release v<VERSION> on PUBLIC_REPO with the DMG, the same DMG
#                                      as Juice.dmg, and the appcast; then writes the Homebrew cask into the tap.
#   zsh scripts/release.sh --dry-run   the whole --publish run with stand-ins (scripts/release-fake.zsh) for
#                                      codesign, notarytool, stapler, spctl, the keychain's identity list, Sparkle's
#                                      sign_update and generate_keys, and gh. The build and the DMG are real; nothing
#                                      is signed, sent or uploaded. What would stop a real release is listed, not
#                                      fatal, and the calls it would make are in output/release.noindex/dry-run/.
#   zsh scripts/release.sh --check     the preflight for --publish alone, then stops.
#   --notes <file>                     the release notes, in Markdown ("- " lines become a list), in place of the
#                                      commit subjects since the last release. --publish asks for it when those
#                                      subjects are only the export's ("Update the Juice source for 0.2.0"). A first
#                                      line "# <headline>" names what is new: the release is titled
#                                      "Juice <version>: <headline>", and the line leaves the notes.
#
# What it reads:
#   VERSION                   the version, like 1.2.0. The build number is the commit count of HEAD, so it rises
#                             with every commit. The tag is v<VERSION>, made on PUBLIC_REPO by gh, never in this
#                             repository (the private repository keeps its juice-* tags).
#   Signing.local.xcconfig    the local signing file the public build reads too, never committed (JI_SIGNING_FILE
#                             names another; Signing.example.xcconfig lists every line). scripts/public-settings.sh
#                             resolves the shared lines, so the build and this script never disagree:
#                               DEVELOPMENT_TEAM        the team id (required)
#                               CODE_SIGN_IDENTITY      the build's identity; when it is a Developer ID Application
#                                                       one, the release signs with it too
#                               SPARKLE_PUBLIC_ED_KEY   Sparkle's public key, which the build puts in the app
#                               PUBLIC_REPO             the public repository, owner/name
#                             and the release's own:
#                               JUICE_RELEASE_IDENTITY  the Developer ID Application identity, its name or SHA-1, when
#                                                       CODE_SIGN_IDENTITY is another (default: the keychain's one
#                                                       such identity for the team)
#                               JUICE_NOTARY_PROFILE    notarytool's keychain profile (default juice-notary)
#                               JUICE_SPARKLE_ACCOUNT   the keychain account of the Sparkle key (default Sparkle's)
#                               JUICE_TAP_DIR           the clone of the Homebrew tap, <owner>/homebrew-tap (default
#                                                       ../homebrew-tap beside this folder)
#   PUBLIC_REPO               the environment first, then the signing file, else public-settings.sh's default.
#   scripts/dmg/              the DMG's background (scripts/make-dmg-art.swift draws it); scripts/dmg-layout.swift lays
#                             the DMG out, built once with swiftc into output/release.noindex/tools/.
#
# The run, in order:
#   1. Preflight: everything missing is listed at once, each with how to make it. Every gh call names the repository.
#      --publish also needs notary credentials, a Sparkle key whose public half is the signing file's
#      SPARKLE_PUBLIC_ED_KEY, README.md's links naming PUBLIC_REPO, gh signed in, and this folder to be a clean public
#      export: no uncommitted change, HEAD the head of PUBLIC_REPO's main (so the source of every release is public at
#      its tag; the private repository's commits are never there), PUBLIC_REPO public, v<VERSION> new, VERSION above
#      the last release's and HEAD after that release's commit.
#   2. Build: scripts/build-app.sh --public --universal into output/release.noindex/<version>/ (for Apple silicon and
#      Intel; ad hoc, with the team's App Group: JI_SIGN_IDENTITY=-; this script signs it).
#      With --publish the app must carry Sparkle's feed for PUBLIC_REPO and the public key of the keychain's key.
#   3. Each part's entitlements are read, less get-task-allow (an ad-hoc build adds it; notarization refuses it).
#      VERSION and the build number go into the app's and its widget's Info.plist.
#   4. Each Mach-O of ours (not Sparkle's) loses its debug and local symbols: they hold the build folder's path, which
#      names this Mac's user, and half the size. The app must carry its licences (LICENSE.txt, NOTICE.txt filled in,
#      Sparkle-LICENSE.txt). Then nothing in the app may name the home folder, every Mach-O in it (Sparkle's too) has
#      an arm64 and an x86_64 slice (lipo -archs), so it runs on Apple silicon and Intel (P880), the app keeps the Apple
#      Events entitlement the hardened runtime needs for jumps, and the app and widget share an App Group of the
#      signing team.
#   5. Signing, inside out: nested code deepest first, the app last, each with the hardened runtime, a secure
#      timestamp and its own entitlements; never --deep. Then codesign --verify --deep --strict, and every part's
#      Developer ID, team, runtime and timestamp. Before notarization spctl may refuse the app only for that.
#   6. --publish: the app is zipped with ditto (zip breaks a framework's links), notarized (xcrun notarytool submit
#      <zip> --keychain-profile <profile> --wait), stapled, and spctl must accept it. The DMG is made from the stapled
#      app, signed, notarized, stapled and accepted. Without --publish the DMG holds the signed app and the run stops
#      there. The DMG (P976, P977) holds the app, an Applications link and the background picture on an HFS+ volume:
#      made read-write, mounted with -nobrowse (no Finder window, no AppleScript), laid out by scripts/dmg-layout.swift
#      (its .DS_Store: the window, the picture, the two icons' places), unmounted and compressed (ULFO).
#   7. Sparkle's sign_update signs the stapled DMG (stapling changes it, so never before) with the key in the owner's
#      keychain, which this never reads. The appcast's one item has the version and build number read back from the
#      app in the DMG, the minimum system, the notes and the signature; xmllint checks it.
#   8. gh release create v<VERSION> on PUBLIC_REPO at HEAD with the DMG, Juice.dmg (the same bytes under a name that
#      never changes, so releases/latest/download/Juice.dmg always works, P981) and appcast.xml (Sparkle's feed is
#      releases/latest/download/appcast.xml), marked latest, then read back.
#   9. The Homebrew cask, Casks/juiceisland.rb (P978): the version, the DMG's SHA-256, auto_updates (Sparkle updates
#      the app), a livecheck on the latest release and a zap of the app's own folders, read from the built app. It is
#      written to output/release.noindex/<version>/Casks/ and into the tap's clone (which --publish needs), uncommitted:
#      the run prints the commit and push for the owner. The export never carries it; the tap is its own repository.
# Overrides, for tests: JI_RELEASE_BUILD_CMD (the build: given --public --universal and a folder, it prints the app's
# path last), JI_RELEASE_TOOLS (a command every outward or keychain tool runs through, as "<command> <tool> <args>").
set -euo pipefail
setopt extendedglob
root=${0:A:h:h}
cd "$root"
usage="usage: release.sh [--publish | --dry-run | --check] [--notes <file>]"
mode=local notes_file=
while (( $# )); do
  case $1 in
    (--publish|--dry-run|--check)
      [[ $mode == local ]] || { print -u2 "release: choose one of --publish, --dry-run and --check"; print -u2 "$usage"; exit 2 }
      mode=${${1#--}%-run} ;;
    (--notes) (( $# >= 2 )) || { print -u2 "$usage"; exit 2 }; notes_file=${2:A}; shift ;;
    (*) print -u2 "$usage"; exit 2 ;;
  esac
  shift
done
[[ -z $notes_file || -f $notes_file ]] || { print -u2 "release: no notes file at $notes_file"; exit 2 }

# --- Settings -----------------------------------------------------------------------------------------------------
typeset -A cfg
signing_file=${JI_SIGNING_FILE:-$root/Signing.local.xcconfig}
export JI_SIGNING_FILE=$signing_file
if [[ -f $signing_file ]]; then
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$' ]] || continue
    value=${match[2]%%[[:space:]]#//*}
    cfg[$match[1]]=${value%%[[:space:]]##}
  done < "$signing_file"
fi
# The lines the build reads come from the one resolver it uses (public-settings.sh); a file it refuses is a preflight
# problem, and the repository's name then still comes from it alone.
settings_said=
if settings=$(zsh "$root/scripts/public-settings.sh" 2>&1); then
  eval "$settings"
else
  settings_said=${settings//$'\n'/ }
  team=${cfg[DEVELOPMENT_TEAM]-} identity=
  eval "$(zsh "$root/scripts/public-settings.sh" --repo 2>/dev/null || print -r -- public_repo=)"
fi
profile=${cfg[JUICE_NOTARY_PROFILE]:-juice-notary}
tap_dir=${JI_TAP_DIR:-${cfg[JUICE_TAP_DIR]:-${root:h}/homebrew-tap}}
[[ $tap_dir == /* ]] || tap_dir=$root/$tap_dir
tap_dir=${tap_dir:a}
# A first line "# <headline>" in the notes names the release.
headline=
if [[ -n $notes_file ]]; then
  first_line=$(head -1 "$notes_file")
  [[ $first_line != '# '* ]] || headline=${${first_line#'# '}%%[[:space:]]#}
fi
sparkle_account=()
[[ -z ${cfg[JUICE_SPARKLE_ACCOUNT]-} ]] || sparkle_account=(--account "${cfg[JUICE_SPARKLE_ACCOUNT]}")
version=$(head -1 VERSION 2>/dev/null || true)
version_ok=0; [[ ! $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || version_ok=1
build=$(git rev-list --count HEAD)
head=$(git rev-parse HEAD)
host_os=$(sw_vers -productVersion | cut -d. -f1)

if [[ $mode == dry ]]; then out=$root/output/release.noindex/dry-run
elif (( version_ok )); then out=$root/output/release.noindex/$version
else out=$root/output/release.noindex/unversioned; fi
work=$out/work
log=$out/release.log
[[ $mode == check ]] || { rm -rf "$out"; mkdir -p "$work" }
say() { print -r -- "release: $*"; [[ ! -d $out ]] || print -r -- "release: $*" >> "$log" }
die() { print -u2 -r -- "release: $*"; [[ ! -d $out ]] || print -r -- "release: FAILED: $*" >> "$log"; exit 1 }

# What would stop a release: fatal, except in a dry run, which lists it and goes on.
stops=()
problem() {
  if [[ $mode == dry ]]; then stops+=("$1"); say "a real release would stop here: $1"; else die "$1"; fi
}

# Every tool that reaches beyond this Mac or into the keychain runs through run, so a dry run and the tests can
# stand in for each one.
if [[ $mode == dry ]]; then
  tools=(zsh "$root/scripts/release-fake.zsh")
  export JI_RELEASE_FAKE_LOG=$out/dry-run-calls
elif [[ -n ${JI_RELEASE_TOOLS-} ]]; then
  tools=(${(Q)${(z)JI_RELEASE_TOOLS}})
else
  tools=()
fi
sparkle_bin=
find_sparkle() {
  local -a found
  found=("$root"/output/*/SourcePackages/artifacts/sparkle/Sparkle/bin(N/) /opt/homebrew/Caskroom/sparkle/*/bin(N/)
         /usr/local/Caskroom/sparkle/*/bin(N/))
  if (( $+commands[sign_update] )); then found=(${commands[sign_update]:h} $found); fi
  found=(${^found}(Ne:'[[ -x $REPLY/sign_update && -x $REPLY/generate_keys ]]':))
  sparkle_bin=${found[1]-}
}
run() {
  local name=$1; shift
  if (( ${#tools} )); then "${tools[@]}" "$name" "$@"; return; fi
  case $name in
    (notarytool|stapler) xcrun "$name" "$@" ;;
    (generate_keys|sign_update) "$sparkle_bin/$name" "$@" ;;
    (*) "$name" "$@" ;;
  esac
}
if (( ${#tools} )); then sparkle_bin=stand-in; else find_sparkle; fi
keychain_key() { run generate_keys "${sparkle_account[@]}" -p 2>/dev/null | grep -oE '[A-Za-z0-9+/]{43}=' | tail -1 }

# --- Preflight ----------------------------------------------------------------------------------------------------
missing=()
need() { missing+=("$1") }
rel_signing=${signing_file#"$root"/}

(( version_ok )) || need "VERSION should hold one version, like 1.2.0, on its first line. Write it there and commit it."
[[ -n $public_repo ]] || need "PUBLIC_REPO is not owner/name. Set it in $rel_signing or the environment, as owner/name."
if [[ ! -f $signing_file ]]; then
  need "There is no local signing file at $rel_signing. Make it (it is never committed; Signing.example.xcconfig
   lists every line) with your team id and your Developer ID identity:
     DEVELOPMENT_TEAM = <team id>
     CODE_SIGN_IDENTITY = Developer ID Application: <your name> (<team id>)
   Both are in the line that names your Developer ID identity, the team id in brackets:
     security find-identity -v -p codesigning"
elif [[ -n $settings_said ]]; then
  need "The public build refuses $rel_signing: ${settings_said#public-settings: }"
elif [[ ! $team =~ '^[A-Z0-9]{10}$' ]]; then
  need "DEVELOPMENT_TEAM in $rel_signing should be your 10-character team id (letters and digits)."
fi
if [[ $mode == dry && ! $team =~ '^[A-Z0-9]{10}$' ]]; then team=ABCDE12345; say "dry run: no team, so it signs as team $team"; fi
export JI_RELEASE_FAKE_TEAM=$team

sha=
if [[ $team =~ '^[A-Z0-9]{10}$' ]]; then
  identities=$(run security find-identity -v -p codesigning 2>/dev/null) || identities=
  devid=(${(u)${(f)"$(print -r -- "$identities" | awk -v t="($team)\"" \
    '$3 == "\"Developer" && $4 == "ID" && $5 == "Application:" && substr($0, length($0) - length(t) + 1) == t {print $2}')"}})
  # JUICE_RELEASE_IDENTITY, else the build's CODE_SIGN_IDENTITY when it is a Developer ID one, else the team's only one.
  named=${cfg[JUICE_RELEASE_IDENTITY]-}
  [[ -n $named || ${identity-} != "Developer ID Application"* ]] || named=$identity
  if (( ${#devid} == 0 )); then
    need "No Developer ID Application identity for team $team is in your keychain. Make one in Xcode: Settings >
   Accounts > your team > Manage Certificates > + > Developer ID Application. Check it with:
     security find-identity -v -p codesigning"
  elif [[ -n $named ]]; then
    sha=$(print -r -- "$identities" | awk -v n="$named" \
      '/"Developer ID Application: / && ($2 == n || index($0, "\"" n "\"")) {print $2; exit}')
    [[ -n $sha ]] || need "$rel_signing names \"$named\", which is not a Developer ID Application identity in your
   keychain. List them with: security find-identity -v -p codesigning"
  elif (( ${#devid} == 1 )); then
    sha=$devid[1]
  else
    need "Your keychain has ${#devid} Developer ID Application identities for team $team. Name one in $rel_signing:
     CODE_SIGN_IDENTITY = Developer ID Application: <your name> (<team id>)
   or, by its SHA-1 from security find-identity -v -p codesigning:
     JUICE_RELEASE_IDENTITY = <SHA-1>"
  fi
fi

prev_tag= prev_sha= key_in_keychain=
if [[ $mode != local ]]; then
  run notarytool history --keychain-profile "$profile" --output-format json >/dev/null 2>&1 \
    || need "No notary credentials are saved as \"$profile\". Make an app-specific password at account.apple.com
   (Sign-In and Security > App-Specific Passwords), then run:
     xcrun notarytool store-credentials $profile --apple-id <your Apple Account email> --team-id ${team:-<team id>}
   It asks for the password and keeps it in your keychain. (JUICE_NOTARY_PROFILE names another profile.)"

  if [[ -z $sparkle_bin ]]; then
    [[ $mode != check ]] || need "Sparkle's tools (generate_keys, sign_update) are not here yet. They come with the public
   build's packages: build once with zsh scripts/build-app.sh --public, or install them: brew install --cask sparkle"
  elif ! key_in_keychain=$(keychain_key) || [[ -z $key_in_keychain ]]; then
    need "No Sparkle signing key is in your keychain. Make it once:
     \"$sparkle_bin/generate_keys\"
   It keeps the private key in your login keychain and prints the public key. Put that public key in $rel_signing
   as SPARKLE_PUBLIC_ED_KEY = <key>, so the public build carries it. Then back the private key up somewhere safe, never
   in a repository (without it no installed copy can be updated again):
     \"$sparkle_bin/generate_keys\" -x <file>"
  fi
  # The key the build puts in the app is the signing file's: it must be the keychain key's public half (P862).
  if [[ -f $signing_file && -z $settings_said && -n $key_in_keychain ]]; then
    if [[ -z ${sparkle_key-} ]]; then
      need "$rel_signing has no SPARKLE_PUBLIC_ED_KEY line, so the app would carry no key and could never update. Add
   the public key of the Sparkle key in your keychain:
     SPARKLE_PUBLIC_ED_KEY = $key_in_keychain"
    elif [[ $sparkle_key != $key_in_keychain ]]; then
      need "SPARKLE_PUBLIC_ED_KEY in $rel_signing ($sparkle_key) is not the public key of the Sparkle key in your keychain
   ($key_in_keychain), so every update would be refused. Put the keychain's in its place (\"$sparkle_bin/generate_keys\" -p
   prints it), or name the matching key's account (JUICE_SPARKLE_ACCOUNT)."
    fi
  fi

  # The README's download and clone links come from the export's PUBLIC_REPO: the same repository as this release's.
  if [[ -f README.md && -n $public_repo ]]; then
    linked=(${(u)${(f)"$(grep -oE 'github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/releases|\.git)' README.md \
      | sed -E 's#^github\.com/##; s#(/releases|\.git)$##' || true)"}})
    others=(${linked:#(#i)$public_repo})
    (( ${#others} == 0 )) || need "README.md links to ${(j:, :)others}, but this release goes to $public_repo. Name the repository
   the same for both: export again with it (PUBLIC_REPO=$public_repo zsh scripts/export-public.sh, in the private
   repository), or set PUBLIC_REPO to ${others[1]} here. Only default_repo in scripts/public-settings.sh, or the same
   PUBLIC_REPO for the export and the release, names it for both."
  fi

  if (( ! ${#tools} && ! $+commands[gh] )); then
    need "The GitHub CLI is not installed. Install it: brew install gh"
  elif ! run gh auth status --hostname github.com >/dev/null 2>&1; then
    need "The GitHub CLI is not signed in. Sign in: gh auth login --hostname github.com --web"
  elif ! repo_info=$(run gh repo view "$public_repo" --json isPrivate,defaultBranchRef \
                       --jq '"\(.isPrivate)\t\(.defaultBranchRef.name)"' 2>/dev/null); then
    need "GitHub has no repository $public_repo that you can see. Make it public and push the export to it
   (gh repo create $public_repo --public), or set PUBLIC_REPO to the public repository you use."
  elif [[ ${repo_info%%$'\t'*} != false ]]; then
    need "$public_repo is private. Releases go only to the public repository (Sparkle cannot download from a private
   one): set PUBLIC_REPO to it."
  else
    branch=${repo_info#*$'\t'}
    remote_head=$(run gh api "repos/$public_repo/commits/$branch" --jq .sha 2>/dev/null) || remote_head=
    [[ $remote_head == $head ]] || need "This commit (${head[1,7]}) is not the head of $public_repo's $branch (${remote_head[1,7]:-unknown}).
   Release from the public export at the commit you pushed there (zsh scripts/export-public.sh makes the export)."
    if (( version_ok )); then
      if tag_answer=$(run gh api "repos/$public_repo/git/ref/tags/v$version" --jq .ref 2>&1); then
        need "v$version is already on $public_repo. Raise VERSION and commit it."
      elif [[ $tag_answer != *"HTTP 404"* ]]; then
        need "GitHub did not say whether v$version is on $public_repo: ${tag_answer//$'\n'/ }"
      fi
    fi
    if latest=$(run gh release view --repo "$public_repo" --json tagName --jq .tagName 2>&1); then
      prev_tag=$latest
      if [[ ! $prev_tag =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
        need "The last release's tag, $prev_tag, is not v<major>.<minor>.<patch>."
      else
        newest=$(print -l "${prev_tag#v}" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
        [[ $newest == $version && $version != ${prev_tag#v} ]] \
          || need "VERSION ($version) is not above the last release, $prev_tag. Raise VERSION and commit it."
        prev_sha=$(run gh api "repos/$public_repo/commits/$prev_tag" --jq .sha 2>/dev/null) || prev_sha=
        if [[ -z $prev_sha ]]; then
          need "GitHub did not give the commit of the last release, $prev_tag."
        elif [[ $prev_sha == $head ]] || ! git merge-base --is-ancestor "$prev_sha" HEAD 2>/dev/null; then
          need "This commit does not come after the last release's ($prev_tag${prev_sha:+, ${prev_sha[1,7]}}), so its build
   number would not be higher. Release from $public_repo's main."
        elif [[ -z $notes_file ]]; then
          # The public history is the export's commits: their subjects say only which version (P861).
          subjects=$(git log --no-merges --format=%s "$prev_sha..HEAD" 2>/dev/null || true)
          if [[ -n $subjects && -z "$(print -r -- "$subjects" | grep -vE '^(Add|Update) the Juice source( for [^ ]+)?$' || true)" ]]; then
            need "The commits since $prev_tag say only \"${subjects%%$'\n'*}\", so the release notes would say nothing.
   Write what changed in a file (\"- \" lines become a list) and pass it:
     zsh scripts/release.sh --publish --notes <file>"
          fi
        fi
      fi
    elif [[ $latest != *"release not found"* ]]; then
      need "GitHub did not say which release is the last: ${latest//$'\n'/ }"
    fi
  fi
  [[ -z "$(git status --porcelain)" ]] || need "This folder has changes that are not committed. A release is built only from a
   commit that $public_repo has: commit them in the private repository and export again."
  # The tap (P978, P990): the README's first install line reads it, so no release goes out before its clone is here. The
  # cask goes into it, so it must be the tap's and clean.
  if [[ ! -d $tap_dir ]]; then
    need "No clone of ${public_repo%%/*}/homebrew-tap at $tap_dir. The README's brew install --cask ${public_repo%%/*}/tap/juiceisland
   reads that repository, so make it and clone it there before the first release:
     gh repo create ${public_repo%%/*}/homebrew-tap --public --add-readme
     git clone https://github.com/${public_repo%%/*}/homebrew-tap.git ${(q)tap_dir}
   (JUICE_TAP_DIR in the signing file names another folder.)"
  else
    tap_origin=$(git -C "$tap_dir" remote get-url origin 2>/dev/null || true)
    tap_origin=${${${tap_origin%/}%.git}#*github.com[:/]}
    if ! git -C "$tap_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
      need "$tap_dir is not a git clone of the Homebrew tap. Move it away, or clone the tap there:
     git clone https://github.com/${public_repo%%/*}/homebrew-tap.git ${(q)tap_dir}"
    elif [[ ${tap_origin:l} != ${${public_repo%%/*}:l}/homebrew-tap ]]; then
      need "$tap_dir is a clone of ${tap_origin:-no GitHub repository}, not of ${public_repo%%/*}/homebrew-tap, the tap
   brew install --cask ${public_repo%%/*}/tap/juiceisland reads. Set JUICE_TAP_DIR to the tap's clone."
    elif [[ -n "$(git -C "$tap_dir" status --porcelain -- Casks 2>/dev/null)" ]]; then
      need "The tap's clone ($tap_dir) has changes in Casks that are not committed. Commit or drop them first."
    fi
  fi
fi

if (( ${#missing} )); then
  if (( ${#missing} == 1 )); then say "preflight: 1 thing to fix first"; else say "preflight: ${#missing} things to fix first"; fi
  i=0
  for m in "${missing[@]}"; do print -r -- ""; print -r -- "$(( ++i )). $m"; done
  print -r -- ""
  [[ $mode == dry ]] || exit 1
  stops+=("${missing[@]}")
  say "dry run: going on with stand-ins"
fi
if [[ $mode == local ]]; then
  say "this run stops at a local signed DMG. --publish also needs notary credentials, a Sparkle key, gh signed in"
  say "and this folder as a clean public export: zsh scripts/release.sh --check checks them."
fi
if [[ $mode == check ]]; then say "preflight: ready to publish v$version (build $build) to $public_repo"; exit 0; fi
if [[ $mode == dry ]]; then sha=${sha:-2222222222222222222222222222222222222222}; (( version_ok )) || version=0.0.0; fi

# --- Build --------------------------------------------------------------------------------------------------------
say "$version (build $build) from ${head[1,7]} for $public_repo${${(M)mode:#dry}:+, a dry run}"
if [[ -n ${JI_RELEASE_BUILD_CMD-} ]]; then builder=(${(Q)${(z)JI_RELEASE_BUILD_CMD}}); else builder=(zsh "$root/scripts/build-app.sh"); fi
say "building"
JI_SIGN_IDENTITY=- JI_VERSION=$version JI_BUILD_NUMBER=$build "${builder[@]}" --public --universal "$work/build" \
  | tee "$work/build.out" \
  || die "the build failed"
built=$(tail -1 "$work/build.out")
[[ $built == *.app && -d $built ]] || die "the build printed no app last (it printed: ${built:-nothing})"
app=$work/${built:t}
ditto "$built" "$app"
plist=$app/Contents/Info.plist
info() { /usr/libexec/PlistBuddy -c "Print :$1" "${2:-$plist}" 2>/dev/null || true }
in_app() { if [[ $1 == "$app" ]]; then print -r -- "${app:t}"; else print -r -- "${1#"$app"/}"; fi }
name=$(info CFBundleName); name=${name:-${app:t:r}}
min_os=$(info LSMinimumSystemVersion)
feed=$(info SUFeedURL)
app_key=$(info SUPublicEDKey)
expected_feed=https://github.com/$public_repo/releases/latest/download/appcast.xml
[[ -n $min_os ]] || problem "the app's Info.plist has no LSMinimumSystemVersion"
[[ -z $feed || $feed == $expected_feed ]] || problem "the app looks for updates at $feed, but this release goes to $expected_feed"
if [[ $mode != local ]]; then
  [[ $app_key =~ '^[A-Za-z0-9+/]{43}=$' ]] \
    || problem "the app carries no Sparkle public key (SUPublicEDKey), so it could never update. Put the key generate_keys -p prints in $rel_signing as SPARKLE_PUBLIC_ED_KEY and run this again."
  [[ -n $sparkle_bin ]] || find_sparkle
  if [[ -z $sparkle_bin ]]; then
    problem "Sparkle's tools (sign_update, generate_keys) are not found after the build: brew install --cask sparkle"
  elif [[ -n $app_key ]]; then
    [[ -n $key_in_keychain ]] || key_in_keychain=$(keychain_key) || key_in_keychain=
    [[ $key_in_keychain == $app_key ]] \
      || problem "the Sparkle key in your keychain (${key_in_keychain:-none}) is not the one the app carries ($app_key): every update signed with it would be refused. Build with the keychain's public key, or name the matching key's account (JUICE_SPARKLE_ACCOUNT)."
  fi
elif [[ -z $app_key ]]; then
  say "note: the app carries no Sparkle public key, so this build cannot update itself"
fi

# --- Code: what to sign, entitlements, versions, symbols, the home folder, architectures ---------------------------
# Nested code, deepest first: bundles with code, and Mach-O files that are not their bundle's own executable.
macho() { [[ "$(file -b "$1")" == *Mach-O* ]] }
own_executable() {
  local f=$1 dir=${1:h} exe
  if [[ ${dir:t} == MacOS && ${dir:h:t} == Contents ]]; then
    exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "${dir:h}/Info.plist" 2>/dev/null) || exe=
    [[ ${f:t} != $exe ]] || return 0
  fi
  [[ ${dir:h:t} == Versions && ${dir:h:h:t} == ${f:t}.framework ]]
}
candidates=("$app"/Contents/**/*.(app|appex|xpc|framework)(N/) "$app"/Contents/**/*.bundle(N/e:'[[ -d $REPLY/Contents/MacOS ]]':))
for f in "$app"/Contents/**/*(N.*) "$app"/Contents/**/*.dylib(N.); do
  if macho "$f" && ! own_executable "$f"; then candidates+=("$f"); fi
done
items=(${(f)"$(for c in "${(u)candidates[@]}"; do print -r -- "${#${(s:/:)c}} $c"; done | sort -rn -k1,1 | cut -d' ' -f2-)"})
items=(${items:#} "$app")
typeset -A ents
mkdir -p "$work/entitlements"
n=0
for item in "${items[@]}"; do
  f=$work/entitlements/$(( ++n )).plist
  if codesign -d --entitlements - --xml "$item" > "$f" 2>/dev/null && [[ -s $f ]]; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$f" >/dev/null 2>&1 || true
    ents[$item]=$f
  fi
done

appexes=("$app"/Contents/PlugIns/*.appex(N/))
(( ${#appexes} )) || problem "the app has no widget in Contents/PlugIns (a build with no team leaves it out)"
for part in "$app" "${appexes[@]}"; do
  for key value in CFBundleShortVersionString "$version" CFBundleVersion "$build"; do
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$part/Contents/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$part/Contents/Info.plist"
  done
done

ours=()
for f in "$app"/Contents/**/*(N.); do
  if [[ $f != "$app"/Contents/Frameworks/* ]] && macho "$f"; then ours+=("$f"); fi
done
for f in "${ours[@]}"; do strip -S -x "$f" 2>>"$log" || die "strip failed on $(in_app "$f")"; done
for f in LICENSE.txt NOTICE.txt Sparkle-LICENSE.txt; do
  [[ -s $app/Contents/Resources/$f ]] \
    || problem "the app does not carry Contents/Resources/$f: the download must carry its licences (GPL-3.0's text, NOTICE and Sparkle's)"
done
if [[ -s $app/Contents/Resources/NOTICE.txt ]] && grep -qE '@[A-Z_]+@' "$app/Contents/Resources/NOTICE.txt"; then
  problem "the app's NOTICE.txt still has fields the export fills in (@YEAR@ and the like): release from the public export"
fi
home_hits=(${(f)"$(grep -rlF -- "$HOME/" "$app" 2>/dev/null || true)"})
(( ${#home_hits} == 0 )) || problem "these files in the app name your home folder, which would publish your user name: ${(j:, :)${home_hits#"$app"/}}. Keep the path out of the build (a JIRepoPath stamp is one), or build from a folder outside your home."
# Every Mach-O in the app, Sparkle's too, needs both slices (P880): macOS 26 runs on Apple silicon and Intel Macs, and a
# part without its slice fails only on the Macs that need it (the hook helper without a word).
thin=()
for f in "$app"/Contents/**/*(DN.); do
  macho "$f" || continue
  have=" $(lipo -archs "$f" 2>/dev/null || true) "
  for a in arm64 x86_64; do [[ $have == *" $a "* ]] || thin+=("$(in_app "$f") (no $a)"); done
done
(( ${#thin} == 0 )) \
  || problem "every part of the app must run on Apple silicon (arm64) and Intel (x86_64), but these lack a slice: ${(j:, :)thin}. Build every part for both, as zsh scripts/build-app.sh --public --universal does."
main_exe=$app/Contents/MacOS/$(info CFBundleExecutable)
main_archs=" $(lipo -archs "$main_exe" 2>/dev/null || true) "
ent() { /usr/libexec/PlistBuddy -c "Print :$1" "${ents[$2]-/dev/null}" 2>/dev/null || true }
[[ "$(ent com.apple.security.automation.apple-events "$app")" == true ]] \
  || problem "the app's entitlements lack com.apple.security.automation.apple-events: under the hardened runtime macOS refuses its AppleScript, so jumps and Open in would stop working"
for part in "$app" "${appexes[@]}"; do
  group=$(ent com.apple.security.application-groups:0 "$part")
  [[ $group == $team.* ]] || problem "$(in_app "$part")'s App Group is ${group:-none}, not one of team $team: the widget would show nothing"
done
for w in "${appexes[@]}"; do
  [[ "$(ent com.apple.security.app-sandbox "$w")" == true ]] || problem "$(in_app "$w") is not sandboxed, and macOS loads only a sandboxed widget"
done

# --- Signing, inside out -------------------------------------------------------------------------------------------
say "signing ${#items} parts with $sha, the app last"
for item in "${items[@]}"; do
  args=(--force --sign "$sha" --options runtime --timestamp)
  [[ -z ${ents[$item]-} ]] || args+=(--entitlements "${ents[$item]}")
  answer=$(run codesign "${args[@]}" "$item" 2>&1) || die "codesign could not sign $(in_app "$item"): $answer"
done
answer=$(run codesign --verify --deep --strict --verbose=2 "$app" 2>&1) || problem "codesign does not accept the signed app: $answer"
for item in "${items[@]}"; do
  shown=$(run codesign -dvv "$item" 2>&1) || shown=
  what=$(in_app "$item")
  [[ $shown == *$'\n'"Authority=Developer ID Application: "* ]] || problem "$what is not signed with a Developer ID Application identity"
  [[ $shown == *$'\n'"TeamIdentifier=$team"(|$'\n'*) ]] || problem "$what is not signed for team $team"
  [[ $shown == *$'\n'Timestamp=* ]] || problem "$what has no secure timestamp, and notarization would refuse it"
  [[ $shown == *flags=0x[0-9a-f]#\(*runtime* ]] || problem "$what has no hardened runtime, and notarization would refuse it"
done
assess() {  # <path> <spctl args...>: prints "accepted", or spctl's source line (why not)
  local said p=$1; shift
  if said=$(run spctl --assess "$@" -vv "$p" 2>&1); then print -r -- accepted; return; fi
  print -r -- "$said" | awk '/^source=/ {sub(/^source=/, ""); print; exit}'
}
if [[ $mode == local ]]; then
  verdict=$(assess "$app" --type execute)
  [[ $verdict == accepted || $verdict == "Unnotarized Developer ID" ]] \
    || problem "spctl refuses the app for a reason other than its missing notarization: ${verdict:-no reason given}"
fi

# --- Notarizing ----------------------------------------------------------------------------------------------------
notarize() {  # <file>
  local file=$1 answer_file=$work/notary-${1:t}.json st id
  say "notarizing ${file:t} (Apple usually answers within minutes)"
  run notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json > "$answer_file" 2>>"$log" || true
  # The answer is one JSON object; should anything else come with it, its last line that is one.
  if ! plutil -extract status raw -o - "$answer_file" >/dev/null 2>&1; then
    { grep '^{' "$answer_file" || true } | tail -1 > "$answer_file.last"; mv "$answer_file.last" "$answer_file"
  fi
  st=$(plutil -extract status raw -o - "$answer_file" 2>/dev/null) || st=
  id=$(plutil -extract id raw -o - "$answer_file" 2>/dev/null) || id=
  [[ $st != Accepted ]] || return 0
  [[ -z $id ]] || run notarytool log "$id" --keychain-profile "$profile" "$work/notary-log-${file:t}.json" >/dev/null 2>&1 || true
  die "Apple did not notarize ${file:t} (${st:-no answer}). Its reasons: ${${id:+$work/notary-log-${file:t}.json}:-$log}"
}
staple() {  # <file>
  local said
  said=$(run stapler staple "$1" 2>&1) || die "stapler could not staple ${1:t}: $said"
  said=$(run stapler validate "$1" 2>&1) || die "stapler finds no ticket on ${1:t}: $said"
}
if [[ $mode != local ]]; then
  zip_path=${app:r}.zip
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"
  notarize "$zip_path"
  staple "$app"
  verdict=$(assess "$app" --type execute)
  [[ $verdict == accepted ]] || problem "spctl does not accept the notarized app: ${verdict:-no reason given}"
fi

# --- The DMG -------------------------------------------------------------------------------------------------------
# Styled (P976, P977): the app, an Applications link and the background on an HFS+ volume, laid out headless by
# scripts/dmg-layout.swift while the read-write image is mounted with -nobrowse, then compressed.
dmg=$out/${name// /-}-$version.dmg
stable=$out/${name// /-}.dmg
stage=$work/dmg
mkdir -p "$stage/.background"
ditto "$app" "$stage/${app:t}"
ln -s /Applications "$stage/Applications"
art=$root/scripts/dmg
[[ -s $art/background.png && -s $art/background@2x.png ]] \
  || die "scripts/dmg has no background.png and background@2x.png: swift scripts/make-dmg-art.swift draws them"
tiffutil -cathidpicheck "$art/background.png" "$art/background@2x.png" -out "$stage/.background/background.tiff" \
  >>"$log" 2>&1 || die "tiffutil could not join the DMG background's two sizes"
# The layout tool, built once per version of its source and of swiftc, beside the releases' folders.
tools_dir=$root/output/release.noindex/tools
layout_key=$( { cat "$root/scripts/dmg-layout.swift"; swiftc --version 2>&1 } | shasum -a 256 | cut -c1-16)
layout_tool=$tools_dir/dmg-layout-$layout_key
if [[ ! -x $layout_tool ]]; then
  mkdir -p "$tools_dir"
  swiftc -O -o "$layout_tool.new" "$root/scripts/dmg-layout.swift" >>"$log" 2>&1 \
    || die "swiftc could not build scripts/dmg-layout.swift (its errors are in $log)"
  mv "$layout_tool.new" "$layout_tool"
fi
say "making ${dmg:t}"
rw=$work/rw.dmg
hdiutil create -quiet -volname "$name" -srcfolder "$stage" -fs HFS+ -format UDRW -size $(( $(du -sm "$stage" | cut -f1) + 16 ))m \
  -ov "$rw" || die "hdiutil could not make the DMG"
mounted=
unmount() {  # retried: Spotlight can hold a fresh volume for a moment
  local i
  [[ -n $mounted ]] || return 0
  for i in 1 2 3 4 5; do
    if hdiutil detach -quiet "$mounted" 2>>"$log"; then mounted=; return 0; fi
    sleep 1
  done
  hdiutil detach -quiet -force "$mounted" 2>>"$log" && { mounted=; return 0 }
  return 1
}
trap 'unmount || true' EXIT
hdiutil attach -nobrowse -noautoopen -noverify -readwrite -plist "$rw" > "$work/attach.plist" 2>>"$log" \
  || die "hdiutil could not mount the DMG to lay it out"
for i in {0..9}; do
  point=$(/usr/libexec/PlistBuddy -c "Print :system-entities:$i:mount-point" "$work/attach.plist" 2>/dev/null) || continue
  mounted=$point; break
done
[[ -n $mounted ]] || die "hdiutil mounted the DMG, but did not say where"
# A downloaded image mounts at /Volumes/<name>, and the background's alias says so (P983): another disk by that name
# would take its place.
[[ $mounted == "/Volumes/$name" ]] || die "another disk named $name is mounted, so the DMG went to $mounted. Eject it
   (hdiutil detach \"/Volumes/$name\") and run this again."
"$layout_tool" "$mounted" "${app:t}" .background/background.tiff >>"$log" 2>&1 \
  || die "the DMG's layout failed: $(tail -1 "$log")"
rm -rf "$mounted/.fseventsd" "$mounted/.Trashes"
unmount || die "hdiutil could not unmount $mounted"
hdiutil convert -quiet "$rw" -format ULFO -ov -o "$dmg" || die "hdiutil could not compress the DMG"
rm -f "$rw"
answer=$(run codesign --force --sign "$sha" --timestamp "$dmg" 2>&1) || die "codesign could not sign the DMG: $answer"
answer=$(run codesign --verify --strict --verbose=2 "$dmg" 2>&1) || problem "codesign does not accept the signed DMG: $answer"
if [[ $mode == local ]]; then
  say "done: $dmg"
  say "it is signed but not notarized, so other Macs refuse it; zsh scripts/release.sh --publish notarizes and releases"
  exit 0
fi
notarize "$dmg"
staple "$dmg"
verdict=$(assess "$dmg" --type open --context context:primary-signature)
[[ $verdict == accepted ]] || problem "spctl does not accept the notarized DMG: ${verdict:-no reason given}"
# The same bytes under a name that never changes (P981): releases/latest/download/Juice.dmg, the README's link.
ditto "$dmg" "$stable"

# --- Sparkle's signature and the appcast ---------------------------------------------------------------------------
signed=$(run sign_update "${sparkle_account[@]}" "$dmg" 2>&1) || die "sign_update could not sign the DMG: $signed"
ed_sig=${${(M)signed##*sparkle:edSignature=\"[^\"]##\"}##*sparkle:edSignature=\"}; ed_sig=${ed_sig%\"}
length=${${(M)signed##*length=\"[0-9]##\"}##*length=\"}; length=${length%\"}
size=$(stat -f %z "$dmg")
[[ $ed_sig =~ '^[A-Za-z0-9+/]{86}==$' ]] || die "sign_update gave no signature: $signed"
[[ $length == $size ]] || die "sign_update signed $length bytes, but the DMG has $size"
shipped=$work/dmg/${app:t}/Contents/Info.plist
app_build=$(info CFBundleVersion "$shipped")
app_version=$(info CFBundleShortVersionString "$shipped")
[[ $app_build == $build && $app_version == $version ]] \
  || die "the app in the DMG says $app_version ($app_build), not $version ($build): Sparkle would offer it again and again"

xml() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; print -r -- "$s" }
notes_md=$out/notes.md
{
  on_mac=
  if [[ $main_archs == *" arm64 "* && $main_archs == *" x86_64 "* ]]; then on_mac=", on Apple silicon or Intel"
  elif [[ $main_archs == *" arm64 "* ]]; then on_mac=" on a Mac with Apple silicon"; fi
  print -r -- "Needs macOS ${min_os%.0} or later$on_mac. Tested on macOS $host_os."
  print -r -- ""
  if [[ -n $headline ]]; then
    tail -n +2 "$notes_file" | sed '/[^[:space:]]/,$!d'
  elif [[ -n $notes_file ]]; then
    cat "$notes_file"
  elif [[ -z $prev_sha && $mode != dry ]]; then
    print -r -- "The first release."
  else
    range=HEAD; [[ -z $prev_sha ]] || range=$prev_sha..HEAD
    subjects=(${(f)"$(git log --no-merges --format=%s "$range")"})
    print -r -- "What changed:"
    for s in "${(@)subjects[1,30]}"; do print -r -- "- $s"; done
    (( ${#subjects} <= 30 )) || print -r -- "- and $(( ${#subjects} - 30 )) more"
  fi
} > "$notes_md"
notes_html=$(
  in_list=0
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == '- '* ]]; then
      (( in_list )) || print -r -- "<ul>"
      in_list=1
      print -r -- "<li>$(xml "${line#- }")</li>"
    else
      (( ! in_list )) || print -r -- "</ul>"
      in_list=0
      [[ -z ${line//[[:space:]]/} ]] || print -r -- "<p>$(xml "$line")</p>"
    fi
  done < "$notes_md"
  (( ! in_list )) || print -r -- "</ul>"
)
appcast=$out/appcast.xml
download=https://github.com/$public_repo/releases/download/v$version/${dmg:t}
cat > "$appcast" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$(xml "$name")</title>
    <link>https://github.com/$(xml "$public_repo")</link>
    <description>$(xml "$name") updates</description>
    <language>en</language>
    <item>
      <title>$(xml "$name $version")</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$(xml "$app_build")</sparkle:version>
      <sparkle:shortVersionString>$(xml "$app_version")</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(xml "$min_os")</sparkle:minimumSystemVersion>
      <link>https://github.com/$(xml "$public_repo")/releases/tag/v$version</link>
      <description><![CDATA[${notes_html//]]>/]]]]><![CDATA[>}]]></description>
      <enclosure url="$(xml "$download")" length="$size" type="application/octet-stream" sparkle:edSignature="$ed_sig"/>
    </item>
  </channel>
</rss>
EOF
/usr/bin/xmllint --noout "$appcast" 2>>"$log" || die "the appcast is not valid XML: $appcast"

# --- The GitHub Release --------------------------------------------------------------------------------------------
say "creating the release v$version on $public_repo"
answer=$(run gh release create "v$version" "$dmg" "$stable" "$appcast" --repo "$public_repo" --target "$head" \
           --title "$name $version${headline:+: $headline}" --notes-file "$notes_md" --latest 2>&1) \
  || die "gh could not create the release: $answer (the DMG and the appcast are in $out)"
assets=$(run gh release view "v$version" --repo "$public_repo" --json assets --jq '.assets[].name' 2>/dev/null) || assets=
for a in "${dmg:t}" "${stable:t}" appcast.xml; do
  [[ $'\n'$assets$'\n' == *$'\n'$a$'\n'* ]] || die "the release v$version on $public_repo has no $a: look at it before anyone updates"
done

# --- The Homebrew cask (P978) ---------------------------------------------------------------------------------------
# brew install --cask <owner>/tap/juiceisland reads Casks/juiceisland.rb in <owner>/homebrew-tap. Everything in it
# comes from this release: the version, the DMG's SHA-256, and the folders the built app keeps, for zap.
bundle_id=$(info CFBundleIdentifier "$shipped")
app_group=$(ent com.apple.security.application-groups:0 "$app")
zap=("~/Library/Application Support/$bundle_id" "~/Library/Caches/$bundle_id" "~/Library/HTTPStorages/$bundle_id"
     "~/Library/Logs/$bundle_id" "~/Library/Preferences/$bundle_id.plist"
     "~/Library/Saved Application State/$bundle_id.savedState")
[[ -z $app_group ]] || zap+=("~/Library/Group Containers/$app_group")
for w in "${appexes[@]}"; do
  widget_id=$(info CFBundleIdentifier "$w/Contents/Info.plist")
  [[ -z $widget_id ]] || zap+=("~/Library/Containers/$widget_id")
done
zap=(${(o)zap})
cask=$out/Casks/juiceisland.rb
mkdir -p "${cask:h}"
{
  print -r -- 'cask "juiceisland" do'
  print -r -- "  version \"$version\""
  print -r -- "  sha256 \"$(shasum -a 256 "$dmg" | cut -d' ' -f1)\""
  print -r -- ''
  print -r -- "  url \"https://github.com/$public_repo/releases/download/v#{version}/${name// /-}-#{version}.dmg\""
  print -r -- "  name \"$name\""
  print -r -- '  desc "Notch island for coding agents: approvals, sessions and usage limits"'
  print -r -- "  homepage \"https://github.com/$public_repo\""
  print -r -- ''
  print -r -- '  livecheck do'
  print -r -- '    url :url'
  print -r -- '    strategy :github_latest'
  print -r -- '  end'
  print -r -- ''
  print -r -- '  auto_updates true'
  print -r -- "  depends_on macos: \">= :tahoe\""
  print -r -- ''
  print -r -- "  app \"${app:t}\""
  print -r -- ''
  print -r -- "  uninstall quit: \"$bundle_id\""
  print -r -- ''
  print -r -- '  zap trash: ['
  for z in "${zap[@]}"; do print -r -- "    \"$z\","; done
  print -r -- '  ]'
  print -r -- ''
  print -r -- '  caveats <<~EOS'
  print -r -- "    Before you uninstall, click Remove from all agents in $name's Settings > Agents,"
  print -r -- "    so no agent keeps calling $name's hook helper."
  print -r -- '  EOS'
  print -r -- 'end'
} > "$cask"
if (( $+commands[ruby] )); then
  ruby -c "$cask" >/dev/null 2>>"$log" || die "the cask is not valid Ruby: $cask"
fi
if [[ $mode == dry ]]; then
  say "dry run: the cask is $cask; a real release would put it in $tap_dir/Casks"
elif [[ -d $tap_dir ]]; then
  mkdir -p "$tap_dir/Casks"
  cp "$cask" "$tap_dir/Casks/juiceisland.rb"
  say "the cask for $version is in $tap_dir/Casks/juiceisland.rb. Publish it:"
  print -r -- "  git -C ${(q)tap_dir} add Casks/juiceisland.rb && git -C ${(q)tap_dir} commit -m \"juiceisland $version\" && git -C ${(q)tap_dir} push"
else
  say "the tap's clone at $tap_dir is gone, so the cask is only in $cask: clone it there and copy the cask in"
fi
if [[ $mode == dry ]]; then
  say "dry run finished: nothing was signed, sent or uploaded; the calls it would make are in $JI_RELEASE_FAKE_LOG"
  if (( ${#stops} )); then
    if (( ${#stops} == 1 )); then say "1 thing would stop a real release:"; else say "${#stops} things would stop a real release:"; fi
    for s in "${stops[@]}"; do print -r -- "  - ${(j: :)${=s}}"; done
  fi
  exit 0
fi
say "released: https://github.com/$public_repo/releases/tag/v$version"
