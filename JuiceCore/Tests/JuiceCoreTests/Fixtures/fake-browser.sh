#!/bin/sh
# Juice's BROWSER helper, faked: records the URL it was handed in $FAKE_BROWSER_TARGET and opens nothing.
printf '%s' "$1" > "$FAKE_BROWSER_TARGET"
