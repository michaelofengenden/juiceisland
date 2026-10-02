#!/bin/zsh
# Repository rules a build does not catch. Run before every commit and in the upstream sync routine.
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
failed=0
fail() { print -u2 "check-guardrails: $*"; failed=1 }

# 1. Vendor/open-vibe-island is exactly the upstream commit recorded in vendor.lock, with nothing uncommitted.
source ./vendor.lock
[[ -z "$(git status --porcelain -- Vendor)" ]] || fail "Vendor/ has uncommitted changes; it is never edited"
[[ "$(git rev-parse HEAD:Vendor/open-vibe-island)" == "$UPSTREAM_TREE" ]] || fail "Vendor/open-vibe-island differs from upstream $UPSTREAM_COMMIT"

# 2. Files derived from Vendor/ are current.
zsh scripts/vendor-derive.sh --check >/dev/null || fail "derived files are stale; run zsh scripts/vendor-derive.sh"

# 3. Our sources never name the forbidden endpoints or hosts (Juice spec 8.3). Vendor code is reviewed in the sync
#    routine instead, by reading upstream's diff. The one exception is the money client's host policy (M6), which
#    names them to allow its one Anthropic request and refuse the rest (Juice spec amendment 10), and has its own
#    tests. Only the money client sends HTTP: URLSession only in its client, and no other way to reach the network
#    (another HTTP API, a remote contentsOf: read, a curl, wget or nscurl launch) anywhere. A tripwire, not a proof:
#    reviews still read the diff. The public flavor's own sources (PublicApp/) are held to the same; its one way out is
#    Sparkle's, which check 8 keeps to its feed.
candidates=(JuiceCore/Sources Sources App PublicApp)
ours=(${^candidates}(N/))
skip=(--exclude-dir=Vendored --exclude-dir=Derived)
hostpolicy='JuiceCore/Sources/JuiceCore/Money/MoneyHostPolicy.swift'
httpclient='JuiceCore/Sources/JuiceCore/Money/MoneyHTTPClient.swift'
if (( ${#ours} )); then
  if grep -rnE "${skip[@]}" 'oauth/usage|wham/usage|api\.anthropic\.com|chatgpt\.com|/v1/organizations' "${ours[@]}" | grep -v "^$hostpolicy:"; then
    fail "forbidden endpoint or host in our sources"
  fi
  hits=$({ grep -rlE "${skip[@]}" 'URLSession' "${ours[@]}" | grep -v "^$httpclient\$"
           grep -rlE "${skip[@]}" 'NSURLConnection|NWConnection|nw_connection_create|CFHTTPMessage|CFReadStreamCreateForHTTPRequest|contentsOf:[^)]*https?:|"(/usr/bin/)?(curl|wget|nscurl)"' "${ours[@]}"
         } | sort -u || true)
  [[ -z "$hits" ]] || fail "HTTP outside the money client: ${hits//$'\n'/ }"
  # 4. No event monitors or event taps in any file, the hot key's own included; the one registered hot key only in
  #    App/Shortcuts/GlobalJumpHotKey.swift.
  hits=$(grep -rlE "${skip[@]}" 'addGlobalMonitorForEvents|addLocalMonitorForEvents|CGEvent\.tapCreate|CGEventTapCreate' "${ours[@]}" || true)
  [[ -z "$hits" ]] || fail "event monitor or event tap in our sources: $hits"
  hits=$(grep -rlE "${skip[@]}" 'RegisterEventHotKey' "${ours[@]}" | grep -v '^App/Shortcuts/GlobalJumpHotKey.swift$' || true)
  [[ -z "$hits" ]] || fail "hot key outside App/Shortcuts/GlobalJumpHotKey.swift: $hits"
  # 6. The engine and the app never use upstream's Codex.app follower or its client: a separately spawned app-server
  #    sees only threads it loaded itself, never the Codex app's (spec 8 Q3). The follower is not compiled; outside a
  #    comment our sources do not even name it or the client, so no call, .init( or type annotation can slip past.
  hits=$(grep -rnE "${skip[@]}" 'CodexAppServer(Coordinator|Client)' "${ours[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | cut -d: -f1 | sort -u || true)
  [[ -z "$hits" ]] || fail "Codex app-server follower named in our sources: ${hits//$'\n'/ }"
  # 7. A CLI login file is never opened (Juice spec 8.3, P66). Outside comments, our sources name auth.json,
  #    .credentials.json, credentials.env or .claude.json only in a fileExists(atPath:) test, in an identity watch (Codex's
  #    stats auth.json, Claude's .claude.json, and neither uses a file-reading API at all), and in M6's key-file guard,
  #    which names them to refuse them. A line that names one never reads a file, wherever it is. Juice's own discovery,
  #    which decoded each .claude.json for an email (ClaudeProfileInfo, ProfileDiscovery.discover), is gone and never
  #    named again: Settings, Setup and the engine find folders with the stat-only ProfileFolderDiscovery.
  #    No identity watch (Codex's, Claude's, and any other `*IdentityWatch.swift`) uses a file-reading API: each only
  #    stats the file a login rewrites.
  logins='auth\.json|\.credentials\.json|credentials\.env|\.claude\.json'
  watches='JuiceCore/Sources/JuiceCore/Providers/[A-Za-z]*IdentityWatch\.swift'
  keyfile='JuiceCore/Sources/JuiceCore/Money/MoneyKeyFile\.swift'
  reads='contentsOf|contents\(atPath|Data\(|NSData|FileHandle|InputStream|fopen|open\(|mmap'
  named=$(grep -rnE "${skip[@]}" "$logins" "${ours[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  hits=$(print -r -- "$named" | grep -v 'fileExists(atPath:' | grep -vE "^($watches|$keyfile):" | cut -d: -f1,2 || true)
  [[ -z "$hits" ]] || fail "a CLI login file named outside a comment, a fileExists check, an identity watch or the key-file guard: ${hits//$'\n'/ }"
  hits=$(print -r -- "$named" | grep -E "$reads" | cut -d: -f1,2 || true)
  [[ -z "$hits" ]] || fail "a line that names a CLI login file reads a file: ${hits//$'\n'/ }"
  hits=$(grep -rnE "${skip[@]}" 'ClaudeProfileInfo|ProfileDiscovery\.discover\(' "${ours[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | cut -d: -f1,2 || true)
  [[ -z "$hits" ]] || fail "Juice's reading discovery named in our sources (P66; use ProfileFolderDiscovery): ${hits//$'\n'/ }"
  for file in JuiceCore/Sources/JuiceCore/Providers/*IdentityWatch.swift(N); do
    hits=$(grep -nE 'FileManager|contents|Stream|Handle|mmap|NSData|fopen|open\(|Data\(|String\(contentsOf' "$file" | grep -vE '^[0-9]+:[[:space:]]*//' | cut -d: -f1 || true)
    [[ -z "$hits" ]] || fail "file-reading API in $file, line ${hits//$'\n'/ and }; an identity watch only stats its login file"
  done
fi

# 8. The public flavor (P827): Sparkle is its updater and reaches only its feed,
#    https://github.com/<PUBLIC_REPO>/releases/latest/download/appcast.xml, and the downloads that feed names. Outside a
#    comment only PublicApp/SparkleFeed.swift names Sparkle (or one of its SPU/SU types); project.yml, Package.swift and
#    JuiceCore/Package.swift never name it, so the private app never links it; project-public.yml names no URL but
#    Sparkle's package and that feed, and the feed's repository only as $(JI_PUBLIC_REPO).
sparkle_words='(^|[^A-Za-z])(Sparkle|SPU[A-Z][A-Za-z]*|SUAppcast[A-Za-z]*|SUUpdate[A-Za-z]*)([^A-Za-z]|$)'
if (( ${#ours} )); then
  hits=$(grep -rnE "${skip[@]}" "$sparkle_words" "${ours[@]}" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*)' \
    | grep -v '^PublicApp/SparkleFeed.swift:' | cut -d: -f1,2 || true)
  [[ -z "$hits" ]] || fail "Sparkle named outside PublicApp/SparkleFeed.swift: ${hits//$'\n'/ }"
fi
for file in project.yml Package.swift JuiceCore/Package.swift; do
  if grep -qi 'sparkle' "$file"; then fail "$file names Sparkle: the private app never links it"; fi
done
if [[ -f project-public.yml ]]; then
  feed='https://github.com/$(JI_PUBLIC_REPO)/releases/latest/download/appcast.xml'
  urls=$(grep -oE 'https?://[^[:space:]"]+' project-public.yml | sort -u)
  others=$(print -r -- "$urls" | grep -vxF -e 'https://github.com/sparkle-project/Sparkle' -e "$feed" -e "https://github.com/<PUBLIC_REPO>/releases/latest/download/appcast.xml" || true)
  [[ -z "$others" ]] || fail "project-public.yml names a URL other than Sparkle's package and the feed: ${others//$'\n'/ }"
  [[ "$(grep -cF "SUFeedURL: $feed" project-public.yml)" == 1 ]] || fail "project-public.yml's SUFeedURL is not $feed"
fi

# 5. No private strings (real emails, real non-default profile folder names, and the aliases made from them) in
#    tracked files outside Vendor/. Prints file names only, never the matching text. The public export (P847) has no
#    make-private-strings.sh, and a stranger's Mac no lists: there, and only there, the check is skipped.
private_strings="$HOME/.config/juice-island/private-strings"
private_words="$HOME/.config/juice-island/private-words"
if [[ ! -f scripts/make-private-strings.sh && ! -e "$private_strings" && ! -e "$private_words" ]]; then
  :
elif [[ -s "$private_strings" && -s "$private_words" ]]; then
  if git ls-files -z -- ':!Vendor' | xargs -0 grep -lIF -f "$private_strings" -- 2>/dev/null; then
    fail "a private string from $private_strings is in a tracked file"
  fi
  if git ls-files -z -- ':!Vendor' | xargs -0 grep -lIwF -f "$private_words" -- 2>/dev/null; then
    fail "a private word from $private_words is in a tracked file"
  fi
else
  fail "missing $private_strings or $private_words (zsh scripts/make-private-strings.sh)"
fi

(( failed == 0 )) && echo "check-guardrails: ok"
exit $failed
