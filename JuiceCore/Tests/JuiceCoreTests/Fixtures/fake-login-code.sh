#!/bin/sh
# Pretends to be `claude auth login` when the sign-in page ends on a code: prints the URL, then the prompt with no
# newline, and reads codes from stdin. A code without `#` is refused on stderr and another one is read, as Claude does;
# $FAKE_LOGIN_CODE signs in (exit 0); any other code fails (exit 1). Every refusal and failure repeats the code on
# stdout and stderr, so the tests can prove it never reaches a phase, an error or a transcript. Each code received is
# appended to $FAKE_LOGIN_RECEIVED when that is set. With $FAKE_LOGIN_DEAF set, it stops reading stdin before it
# prompts (as when the browser's own redirect finished the login), waits for that file to exist, prints another URL and
# exits 0.
# Every launch site builds its environment with CLIEnvironment.make, so both island skip switches must arrive;
# a site that drops either one fails its tests here instead of passing silently.
[ "$OPEN_ISLAND_SKIP_HOOKS" = 1 ] && [ "$VIBE_ISLAND_SKIP" = 1 ] || { echo "island skip vars missing" >&2; exit 97; }
echo "Opening browser to sign in…"
echo "If the browser didn't open, visit: https://example.com/oauth/authorize?code=true&state=abc123"
if [ -n "$FAKE_LOGIN_DEAF" ]; then
  exec 0<&-
  printf 'Paste code here if prompted > '
  while [ ! -e "$FAKE_LOGIN_DEAF" ]; do sleep 0.05; done
  echo
  echo "Login successful. Manage it at https://example.com/after"
  exit 0
fi
printf 'Paste code here if prompted > '
while IFS= read -r code; do
  [ -n "$FAKE_LOGIN_RECEIVED" ] && printf '%s\n' "$code" >> "$FAKE_LOGIN_RECEIVED"
  case "$code" in
    *'#'*) ;;
    *) echo "heard $code"; echo "Invalid code. Please make sure the full code was copied. ($code)" >&2; continue ;;
  esac
  if [ "$code" = "$FAKE_LOGIN_CODE" ]; then echo "Login successful."; exit 0; fi
  echo "heard $code"
  echo "Login failed: $code was rejected" >&2
  exit 1
done
exit 1
