#!/bin/zsh
# The public flavor's settings (P821, P822), resolved once for scripts/build-public.sh and any script that ships what it
# builds. Prints one shell assignment per line, quoted for eval:
#   public_repo  owner/name of the public repository: $PUBLIC_REPO, else the local file's PUBLIC_REPO, else
#                michaelofengenden/juiceisland (the one default every script that needs it shares)
#   feed         https://github.com/<public_repo>/releases/latest/download/appcast.xml, the only place Sparkle checks
#   bundle_id    io.github.michaelofengenden.juice, or the local file's JI_PUBLIC_BUNDLE_ID (someone building their own copy)
#   team         the local file's DEVELOPMENT_TEAM; empty for an ad hoc build
#   identity     the local file's CODE_SIGN_IDENTITY (its name or SHA-1 hash); "-" (ad hoc) when the file names none
#   app_group    <team>.<bundle_id>, team-prefixed so no provisioning profile is needed; <bundle_id> in an ad hoc build,
#                which no group vouches for, so the app writes no widget snapshot there (P342)
#   sparkle_key  the local file's SPARKLE_PUBLIC_ED_KEY, Sparkle's EdDSA public key (base64 of 32 bytes); empty: the
#                build ships with updates off and About says so
#   release      1 when the identity is a "Developer ID Application" one: signed with a secure timestamp, for
#                notarizing; 0 otherwise (ad hoc or Apple Development: no timestamp, so signing sends nothing anywhere)
# The local file is Signing.local.xcconfig at the repository's root (JI_SIGNING_FILE names another): untracked
# (.gitignore), copied from the committed Signing.example.xcconfig. Lines are `KEY = value`; blank lines and lines that
# start with // or # are skipped; keys it does not know are left for other scripts. No team id is ever committed.
# It reads that file and nothing else: no keychain, no network.
# This file is the one place PUBLIC_REPO's default is named: release.sh, export-public.sh and the build all ask it.
# Usage: zsh scripts/public-settings.sh [--repo]   (exit 1, with the reason, on a malformed value)
#   --repo  only public_repo, checking nothing else in the file (the export needs the name and no signing settings)
set -euo pipefail
setopt extendedglob
root=${0:A:h:h}
only_repo=0
case ${1-} in
  (--repo) only_repo=1 ;;
  ('') ;;
  (*) print -u2 "usage: public-settings.sh [--repo]"; exit 2 ;;
esac
file=${JI_SIGNING_FILE:-$root/Signing.local.xcconfig}
default_repo=michaelofengenden/juiceisland
default_bundle_id=io.github.michaelofengenden.juice

typeset -A local_values
if [[ -f "$file" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line##[[:space:]]#}
    [[ -z "$line" || "$line" == '//'* || "$line" == '#'* ]] && continue
    [[ "$line" == *=* ]] || { print -u2 "public-settings: ${file:t}: not KEY = value: ${line%%[[:space:]]*}"; exit 1 }
    key=${${line%%=*}%%[[:space:]]#}
    value=${${line#*=}##[[:space:]]#}
    value=${value%%[[:space:]]##//*}  # a note after the value, as xcconfig allows ("ABCDE12345   // the team")
    value=${value%%[[:space:]]#}
    [[ "$value" == \"*\" && ${#value} -ge 2 ]] && value=${value[2,-2]}
    local_values[$key]=$value
  done < "$file"
fi

public_repo=${PUBLIC_REPO:-${local_values[PUBLIC_REPO]:-$default_repo}}
[[ "$public_repo" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]] \
  || { print -u2 "public-settings: PUBLIC_REPO is not owner/name: $public_repo"; exit 1 }
if (( only_repo )); then print -r -- "public_repo=${(q)public_repo}"; exit 0; fi
bundle_id=${local_values[JI_PUBLIC_BUNDLE_ID]:-$default_bundle_id}
[[ "$bundle_id" =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]] \
  || { print -u2 "public-settings: JI_PUBLIC_BUNDLE_ID is not a bundle id: $bundle_id"; exit 1 }
# Never one of the private app's ids (com.ofengenden.juice, its dev build, their widgets): the flavors stay apart.
[[ "$bundle_id" != com.ofengenden.juice && "$bundle_id" != com.ofengenden.juice.* ]] \
  || { print -u2 "public-settings: $bundle_id is the private app's"; exit 1 }

team=${local_values[DEVELOPMENT_TEAM]-}
identity=${local_values[CODE_SIGN_IDENTITY]-}
if [[ -n "$team" ]]; then
  [[ "$team" =~ '^[A-Z0-9]{10}$' ]] || { print -u2 "public-settings: DEVELOPMENT_TEAM is not a 10-character team id"; exit 1 }
  [[ -n "$identity" && "$identity" != - ]] || { print -u2 "public-settings: DEVELOPMENT_TEAM is set but CODE_SIGN_IDENTITY is not"; exit 1 }
  app_group=$team.$bundle_id
else
  [[ -z "$identity" || "$identity" == - ]] || { print -u2 "public-settings: CODE_SIGN_IDENTITY is set but DEVELOPMENT_TEAM is not"; exit 1 }
  identity=- app_group=$bundle_id
fi
release=0
[[ "$identity" != "Developer ID Application"* ]] || release=1

sparkle_key=${local_values[SPARKLE_PUBLIC_ED_KEY]-}
if [[ -n "$sparkle_key" ]]; then
  [[ "$sparkle_key" =~ '^[A-Za-z0-9+/]{43}=$' && "$(print -rn -- "$sparkle_key" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" == 32 ]] \
    || { print -u2 "public-settings: SPARKLE_PUBLIC_ED_KEY is not an EdDSA public key (base64 of 32 bytes)"; exit 1 }
fi

for name in public_repo bundle_id team identity app_group sparkle_key release; do
  print -r -- "$name=${(q)${(P)name}}"
done
print -r -- "feed=${(q):-https://github.com/$public_repo/releases/latest/download/appcast.xml}"
