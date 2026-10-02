#!/bin/zsh
# Tests the public flavor's settings (P821): scripts/public-settings.sh against local files written into <work-dir>, and
# that build-app.sh --public hands over to build-public.sh before anything of the private build runs. Nothing is built,
# signed, read from a keychain or sent anywhere; the files it reads are its own fixtures.
# Usage: zsh scripts/tests/public-flavor-test.zsh <work-dir>   (a folder that does not exist yet)
set -euo pipefail
src=${0:A:h:h:h}
(( $# == 1 )) || { print -u2 "usage: public-flavor-test.zsh <work-dir>"; exit 2 }
W=${1:a}
[[ ! -e "$W" ]] || { print -u2 "public-flavor-test: $W exists; pass a new folder"; exit 2 }
mkdir -p "$W"
W=${W:A}
S=$src/scripts

passed=0 failed=0 case=
check() {
  local name=$1; shift
  if "$@"; then passed=$(( passed + 1 )); else failed=$(( failed + 1 )); print "FAIL $case: $name"; fi
}
eq() { [[ "$1" == "$2" ]] || { print -r -- "     got: $1"; print -r -- "     want: $2"; return 1 } }
has() { [[ "$1" == *"$2"* ]] || { print -r -- "     missing: $2"; print -r -- "     in: $1"; return 1 } }
lacks() { [[ "$1" != *"$2"* ]] || { print -r -- "     unexpected: $2"; return 1 } }
run() { out=$("$@" 2>&1) && rc=0 || rc=$? }
# Resolves with <file> (and the environment given before it) and evaluates the result into this shell.
settings() {
  public_repo= bundle_id= team= identity= app_group= sparkle_key= release= feed=
  out=$(env -u PUBLIC_REPO "$@" zsh "$S/public-settings.sh" 2>&1) && rc=0 || rc=$?
  (( rc != 0 )) || eval "$out"
}
key=$(head -c 32 /dev/urandom | base64)

case="no local file"
settings JI_SIGNING_FILE="$W/none.xcconfig"
check "exit 0" eq $rc 0
check "ad hoc" eq "$identity" -
check "no team" eq "$team" ""
check "the App Group is the bundle id" eq "$app_group" io.github.michaelofengenden.juice
check "the default repository" eq "$public_repo" michaelofengenden/juiceisland
check "the feed" eq "$feed" https://github.com/michaelofengenden/juiceisland/releases/latest/download/appcast.xml
check "no key: updates off" eq "$sparkle_key" ""
check "not a release" eq "$release" 0

case="the committed example"
settings JI_SIGNING_FILE="$src/Signing.example.xcconfig"
check "exit 0" eq $rc 0
check "every line a note: ad hoc" eq "$identity" -

case="a Developer ID file"
cat > "$W/release.xcconfig" <<EOF
// a note

# another
DEVELOPMENT_TEAM = ABCDE12345
CODE_SIGN_IDENTITY = "Developer ID Application: Test Person (ABCDE12345)"
  SPARKLE_PUBLIC_ED_KEY=$key
NOTARY_PROFILE = left for another script
PUBLIC_REPO = someone/juice
EOF
settings JI_SIGNING_FILE="$W/release.xcconfig"
check "exit 0" eq $rc 0
check "the team" eq "$team" ABCDE12345
check "the identity, quotes off" eq "$identity" "Developer ID Application: Test Person (ABCDE12345)"
check "a team-prefixed App Group" eq "$app_group" ABCDE12345.io.github.michaelofengenden.juice
check "the key" eq "$sparkle_key" "$key"
check "a release: timestamped" eq "$release" 1
check "the file's repository" eq "$public_repo" someone/juice
check "its feed" eq "$feed" https://github.com/someone/juice/releases/latest/download/appcast.xml
settings PUBLIC_REPO=owner/other JI_SIGNING_FILE="$W/release.xcconfig"
check "PUBLIC_REPO wins over the file" eq "$public_repo" owner/other

case="a note after a value, as xcconfig allows"
print -r -- $'DEVELOPMENT_TEAM = ABCDE12345   // the team\nCODE_SIGN_IDENTITY = "Developer ID Application: Test Person (ABCDE12345)"  // release' > "$W/notes.xcconfig"
settings JI_SIGNING_FILE="$W/notes.xcconfig"
check "exit 0" eq $rc 0
check "the team without the note" eq "$team" ABCDE12345
check "the identity without the note" eq "$identity" "Developer ID Application: Test Person (ABCDE12345)"

case="--repo: the name alone (the export)"
print -r -- $'DEVELOPMENT_TEAM = ABCDE12345\nPUBLIC_REPO = someone/juice' > "$W/repo-only.xcconfig"
run env -u PUBLIC_REPO JI_SIGNING_FILE="$W/repo-only.xcconfig" zsh "$S/public-settings.sh" --repo
check "a team with no identity is not its business" eq $rc 0
check "only the name" eq "$out" "public_repo=someone/juice"
run env -u PUBLIC_REPO JI_SIGNING_FILE="$W/none.xcconfig" zsh "$S/public-settings.sh" --repo
check "the default" eq "$out" "public_repo=michaelofengenden/juiceisland"
run env PUBLIC_REPO=a/b/c JI_SIGNING_FILE="$W/none.xcconfig" zsh "$S/public-settings.sh" --repo
check "a name that is not owner/name is still refused" eq $rc 1
run zsh "$S/public-settings.sh" --bogus
check "an unknown argument" eq $rc 2

case="an Apple Development file"
print -r -- $'DEVELOPMENT_TEAM = ABCDE12345\nCODE_SIGN_IDENTITY = Apple Development: Test Person (XYZ)' > "$W/dev.xcconfig"
settings JI_SIGNING_FILE="$W/dev.xcconfig"
check "exit 0" eq $rc 0
check "signed, not a release: no timestamp" eq "$release" 0

case="another bundle id"
print -r -- 'JI_PUBLIC_BUNDLE_ID = io.github.someone.juice' > "$W/id.xcconfig"
settings JI_SIGNING_FILE="$W/id.xcconfig"
check "exit 0" eq $rc 0
check "its id" eq "$bundle_id" io.github.someone.juice

case="refusals"
refuse() {
  local name=$1 text=$2 says=$3
  print -r -- "$text" > "$W/bad.xcconfig"
  settings JI_SIGNING_FILE="$W/bad.xcconfig"
  check "$name: exit 1" eq $rc 1
  check "$name: says why" has "$out" "$says"
}
refuse "a short team" $'DEVELOPMENT_TEAM = ABC\nCODE_SIGN_IDENTITY = x' "not a 10-character team id"
refuse "a team without an identity" 'DEVELOPMENT_TEAM = ABCDE12345' "CODE_SIGN_IDENTITY is not"
refuse "an identity without a team" 'CODE_SIGN_IDENTITY = Developer ID Application: X' "DEVELOPMENT_TEAM is not"
refuse "a key that is not 32 bytes" "SPARKLE_PUBLIC_ED_KEY = $(head -c 16 /dev/urandom | base64)" "not an EdDSA public key"
refuse "a repository that is not owner/name" 'PUBLIC_REPO = a/b/c' "not owner/name"
refuse "the private app's bundle id" 'JI_PUBLIC_BUNDLE_ID = com.ofengenden.juice' "the private app's"
refuse "the private dev build's id" 'JI_PUBLIC_BUNDLE_ID = com.ofengenden.juice.dev' "the private app's"
refuse "a line with no =" 'SECRETWORD and more' "not KEY = value"
check "a malformed line's text is not echoed past its first word" lacks "$out" "and more"

case="build-app.sh --public"
run zsh "$S/build-app.sh" --public one two
check "hands over to build-public.sh" eq $rc 2
check "its usage" has "$out" "usage: build-app.sh --public [--universal] [output-folder]"
run zsh "$S/build-app.sh" --public --universl
check "a misspelt switch is refused, not taken for a folder" eq $rc 2
run zsh "$S/build-app.sh" --public --universal one two
check "--universal with two folders" eq $rc 2
lacks_private() { lacks "$out" "Apple Development identity" && lacks "$out" "Juice Island" }
check "nothing of the private build" lacks_private

case="a folder with no git history (GitHub's source zip)"
Z=$W/zip
mkdir -p "$Z/scripts" "$Z/bin"
cp "$S/build-public.sh" "$S/public-settings.sh" "$S/build-app.sh" "$Z/scripts/"
print -r -- "1.2.3" > "$Z/VERSION"
print -r -- $'#!/bin/zsh\nprint -r -- "xcodegen reached"; exit 3' > "$Z/bin/xcodegen"
chmod +x "$Z/bin/xcodegen"
run env PATH="$Z/bin:$PATH" GIT_CEILING_DIRECTORIES="$W" JI_SIGNING_FILE="$W/none.xcconfig" zsh "$Z/scripts/build-app.sh" --public
check "goes on to the build" has "$out" "xcodegen reached"
check "says what it does without the history" has "$out" "no git history here"
check "no git error" lacks "$out" "not a git repository"

print "public-flavor-test: $passed passed, $failed failed"
(( failed == 0 ))
