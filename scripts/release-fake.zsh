#!/bin/zsh
# Stand-in for every tool release.sh reaches beyond this Mac or into the keychain with: codesign (signing, checking
# and showing a signature), xcrun notarytool, xcrun stapler, spctl, security (the list of signing identities),
# Sparkle's sign_update and generate_keys, and gh. release.sh --dry-run runs through it, and so do the release
# script's tests. It signs, sends, uploads and reads nothing: each call is one line in $JI_RELEASE_FAKE_LOG
# ("<tool> <args>"), and it answers the way the real tool does when all is well. It keeps two notes beside that log
# so later answers follow earlier calls: what was stapled (spctl calls only those notarized) and what a release was
# created with (gh release view lists those assets).
# The one real call: codesign -d --entitlements reads a signature already on this Mac, which a dry run needs.
# Knobs, for tests (all off unless set):
#   JI_RELEASE_FAKE_TEAM      the team every identity and signature belongs to (default ABCDE12345)
#   FAKE_NO_IDENTITY=1        the keychain has an Apple Development identity only
#   FAKE_SIGN_FAIL=1          codesign cannot sign
#   FAKE_NO_RUNTIME=1         signatures lack the hardened runtime
#   FAKE_NO_TIMESTAMP=1       signatures lack a secure timestamp
#   FAKE_NOTARY=missing       no notary credentials under that profile
#   FAKE_NOTARY=invalid       Apple refuses what is submitted
#   FAKE_NOTARY=chatty        a line of progress comes before the answer
#   FAKE_NO_SPARKLE_KEY=1     no Sparkle key in the keychain
#   FAKE_SPARKLE_KEY=<key>    the keychain's Sparkle public key (default the fake app's)
#   FAKE_GH=logged-out|no-repo|private|tag-exists|create-fails
#   FAKE_GH_HEAD=<sha>        the public repository's main (default this repository's HEAD)
#   FAKE_GH_LATEST=<tag>      the last release (default none)
#   FAKE_GH_LATEST_SHA=<sha>  that release's commit
# Usage: zsh release-fake.zsh <tool> <args...>
set -euo pipefail
tool=${1:?usage: release-fake.zsh <tool> <args...>}
shift
log=${JI_RELEASE_FAKE_LOG:?release-fake: JI_RELEASE_FAKE_LOG is not set}
print -r -- "$tool $*" >> "$log"
team=${JI_RELEASE_FAKE_TEAM:-ABCDE12345}
identity="Developer ID Application: Test Person ($team)"
fake_key=${FAKE_SPARKLE_KEY:-anVpY2UtcmVsZWFzZS1mYWtlLXB1YmxpYy1rZXktMzI=}
args=" $* "

case $tool in
  (security)
    print -r -- "  1) 1111111111111111111111111111111111111111 \"Apple Development: Test Person (ZYXWV98765)\""
    if [[ -z "${FAKE_NO_IDENTITY-}" ]]; then
      print -r -- "  2) 2222222222222222222222222222222222222222 \"$identity\""
      print -r -- "     2 valid identities found"
    else
      print -r -- "     1 valid identities found"
    fi ;;
  (codesign)
    if [[ "$args" == *" --entitlements "* && "$args" != *" --sign "* ]]; then
      exec codesign "$@"
    elif [[ "$args" == *" --sign "* || "$args" == *" -s "* ]]; then
      [[ -z "${FAKE_SIGN_FAIL-}" ]] || { print -u2 "${@[-1]}: errSecInternalComponent"; exit 1 }
    elif [[ "$args" == *" --verify "* ]]; then
      :
    else
      flags='0x10000(runtime)' stamp="Timestamp=2 Oct 2026 at 12:00:00"
      [[ -z "${FAKE_NO_RUNTIME-}" ]] || flags='0x0(none)'
      [[ -z "${FAKE_NO_TIMESTAMP-}" ]] || stamp="Signed Time=2 Oct 2026 at 12:00:00"
      print -u2 -r -- "Executable=${@[-1]}"
      print -u2 -r -- "CodeDirectory v=20500 size=1 flags=$flags hashes=1+1 location=embedded"
      print -u2 -r -- "Authority=$identity"
      print -u2 -r -- "Authority=Developer ID Certification Authority"
      print -u2 -r -- "Authority=Apple Root CA"
      print -u2 -r -- "$stamp"
      print -u2 -r -- "TeamIdentifier=$team"
    fi ;;
  (notarytool)
    case $1 in
      (history)
        [[ "${FAKE_NOTARY-}" != missing ]] \
          || { print -u2 "Error: No Keychain password item found for profile: ${@[${@[(i)--keychain-profile]}+1]}"; exit 1 }
        print -r -- '{"history":[]}' ;;
      (submit)
        [[ "${FAKE_NOTARY-}" != missing ]] || { print -u2 "Error: No Keychain password item found for profile"; exit 1 }
        if [[ "${FAKE_NOTARY-}" == invalid ]]; then
          print -r -- '{"id":"00000000-fake-0000-0000-000000000000","status":"Invalid","message":"Processing complete"}'
        else
          print -r -- "${2:A}" >> "$log.notarized"
          [[ "${FAKE_NOTARY-}" != chatty ]] || print -r -- "Conducting pre-submission checks for ${2:t} and initiating connection"
          print -r -- '{"id":"00000000-fake-0000-0000-000000000000","status":"Accepted","message":"Processing complete"}'
        fi ;;
      (log) print -r -- '{"status":"Invalid","issues":[{"message":"The signature does not include a secure timestamp."}]}' > "${@[-1]}" ;;
    esac ;;
  (stapler)
    target=${@[-1]:A}
    if [[ "$1" == staple ]]; then
      # A ticket exists for what was notarized, and for the app in a notarized <app>.zip beside it.
      grep -qxF -e "$target" -e "${target:r}.zip" "$log.notarized" 2>/dev/null \
        || { print -u2 "CloudKit query for ${target:t} failed due to \"Record not found\"."; exit 65 }
      print -r -- "$target" >> "$log.stapled"
    else
      grep -qxF -- "$target" "$log.stapled" 2>/dev/null || { print -u2 "${target:t} does not have a ticket stapled to it."; exit 65 }
    fi
    print -r -- "The ${1} and validate action worked!" ;;
  (spctl)
    target=${@[-1]:A}
    if grep -qxF -- "$target" "$log.stapled" 2>/dev/null; then
      print -u2 -r -- "$target: accepted"; print -u2 -r -- "source=Notarized Developer ID"
    else
      print -u2 -r -- "$target: rejected"; print -u2 -r -- "source=Unnotarized Developer ID"; exit 3
    fi
    print -u2 -r -- "origin=$identity" ;;
  (generate_keys)
    [[ -z "${FAKE_NO_SPARKLE_KEY-}" ]] || { print -u2 "ERROR! There is no existing key in the keychain."; exit 1 }
    print -r -- "$fake_key" ;;
  (sign_update)
    [[ -z "${FAKE_NO_SPARKLE_KEY-}" ]] || { print -u2 "ERROR! Unable to access the EdDSA key from the keychain."; exit 1 }
    print -r -- "sparkle:edSignature=\"anVpY2UtcmVsZWFzZS1mYWtlLWVkMjU1MTktc2lnbmF0dXJlLWZvci10ZXN0cy1vbmx5LTAxMjM0NTY3ODlhYg==\" length=\"$(stat -f %z "${@[-1]}")\"" ;;
  (gh)
    case "$1 $2" in
      ("auth status")
        [[ "${FAKE_GH-}" != logged-out ]] \
          || { print -u2 "You are not logged into any GitHub hosts. To log in, run: gh auth login"; exit 1 }
        print -r -- "github.com"; print -r -- "  ✓ Logged in to github.com account test (keyring)" ;;
      ("repo view")
        [[ "${FAKE_GH-}" != no-repo ]] \
          || { print -u2 "GraphQL: Could not resolve to a Repository with the name '$3'. (repository)"; exit 1 }
        [[ "${FAKE_GH-}" == private ]] && print -r -- $'true\tmain' || print -r -- $'false\tmain' ;;
      ("api repos/"*/commits/main)
        print -r -- "${FAKE_GH_HEAD:-$(git -C "${0:A:h:h}" rev-parse HEAD)}" ;;
      ("api repos/"*/commits/v*)
        [[ -n "${FAKE_GH_LATEST_SHA-}" ]] || { print -u2 "gh: No commit found for SHA: ${2##*/} (HTTP 422)"; exit 1 }
        print -r -- "$FAKE_GH_LATEST_SHA" ;;
      ("api repos/"*/git/ref/tags/*)
        [[ "${FAKE_GH-}" == tag-exists ]] || { print -u2 "gh: Not Found (HTTP 404)"; exit 1 }
        print -r -- "refs/tags/${2##*/}" ;;
      ("release view")
        if [[ "$3" == v* ]]; then
          [[ -s "$log.assets" ]] || { print -u2 "release not found"; exit 1 }
          cat "$log.assets"
        else
          [[ -n "${FAKE_GH_LATEST-}" ]] || { print -u2 "release not found"; exit 1 }
          print -r -- "$FAKE_GH_LATEST"
        fi ;;
      ("release create")
        [[ "${FAKE_GH-}" != create-fails ]] || { print -u2 "HTTP 422: Validation Failed"; exit 1 }
        for a in "${@[3,-1]}"; do [[ "$a" != *.dmg && "$a" != *.xml ]] || print -r -- "${a:t}" >> "$log.assets"; done
        print -r -- "https://github.com/${${@[${@[(i)--repo]}+1]}}/releases/tag/$3" ;;
    esac ;;
  (*) print -u2 "release-fake: no stand-in for $tool"; exit 2 ;;
esac
