#!/bin/bash
# test-update.sh
# AVM — Accessible Virtual Machine
#
# An update really installing (2026-11-01, UpdateTestJob.swift). Makes a copy
# of the app that calls itself version 0.0.1, lets Sparkle in it find the
# newest release in the feed installed copies read, download it, check its
# signature and install it over the copy; then checks what's there. Run it
# after publishing, or give it a feed that names a release to try beforehand.
#
#   Tools/test-update.sh [--app PATH] [--feed URL] [--out FOLDER]
#
# Downloads the whole update, about 100 MB. Touches nothing outside its folder.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="$HOME/Library/Caches/AVM-build"
APP="$CACHE/dd-check/Build/Products/Debug/AVM.app"
FEED=""
OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --feed) FEED="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 64 ;;
    esac
done
[ -x "$APP/Contents/MacOS/AVM" ] || { echo "FAILED: no AVM at $APP."; exit 1; }

WORK="$(mktemp -d "$CACHE/update-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/AVM.app"
ditto "$APP" "$COPY" || { echo "FAILED: couldn't copy the app."; exit 1; }
PLIST="$COPY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" -c "Set :CFBundleVersion 1" "$PLIST"
# The same signer as the app, as the outer signature no longer matches.
IDENTITY="$(codesign -dvv "$APP" 2>&1 | sed -nE 's/^Authority=(.*)$/\1/p' | sed -n 1p)"
ENTITLEMENTS="$WORK/app.entitlements"
codesign -d --entitlements - --xml "$APP" 2>/dev/null > "$ENTITLEMENTS"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "${IDENTITY:--}" "$COPY" 2>/dev/null \
    || { echo "FAILED: couldn't sign the copy (is the Mac unlocked?)."; exit 1; }
echo "== The copy says it's 0.0.1, signed by ${IDENTITY:-nobody}"

LOG="${OUT:-$WORK}/update-job.txt"
"$COPY/Contents/MacOS/AVM" --test-update ${FEED:+--feed "$FEED"} > "$LOG" 2>/dev/null &
JOB=$!
INSTALLED=""
for _ in $(seq 1 240); do
    INSTALLED="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null)"
    [ -n "$INSTALLED" ] && [ "$INSTALLED" != "0.0.1" ] && break
    grep -q "^FAILED" "$LOG" 2>/dev/null && break
    sleep 5
done
kill "$JOB" 2>/dev/null
grep -E "^   " "$LOG"

FAILED=0
check() { if [ "$2" = 0 ]; then echo "   yes  $1"; else echo "   NO   $1"; FAILED=1; fi; }
[ -n "$INSTALLED" ] && [ "$INSTALLED" != "0.0.1" ]; check "the copy is now ${INSTALLED:-unknown}" $?
sleep 3
codesign --verify --deep --strict "$COPY" 2>/dev/null; check "its signature is whole" $?
spctl -a -t exec "$COPY" 2>/dev/null; check "Gatekeeper accepts it" $?
[ -x "$COPY/Contents/Resources/qemu-system-aarch64" ]; check "it has QEMU" $?

if [ $FAILED = 0 ]; then echo "PASSED"; else echo "FAILED"; fi
exit $FAILED
