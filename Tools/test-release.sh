#!/bin/bash
# test-release.sh
# AVM — Accessible Virtual Machine
#
# Checks a release before it's published (2026-10-31): 0.4.19 went out
# tested only as a Debug build. It takes what build-installer.sh made, the
# DMG, the update zip and its feed entry, and checks what a new user and an
# updating user get:
#   1. the DMG and the app in it: signed, notarized, stapled, accepted by
#      Gatekeeper as a download would be;
#   2. the version in the app, the zip and the feed entry agree, and is
#      newer than the last release's;
#   3. the update: the zip's size is the feed entry's, its Ed25519 signature
#      is valid for the key in the app (SUPublicEDKey), and that key is the
#      last release's, so installed copies accept it;
#   4. with --machines, a few real tests with the app from the DMG itself
#      (save and resume, send file, the control socket, disk info), which
#      need AVM quit: the suite would otherwise run a re-signed copy.
# Nothing is published or installed. The app is copied out of the DMG to
# a temporary folder and removed afterwards.
#
#   Tools/test-release.sh [--dmg PATH] [--machines] [--out FOLDER]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$REPO_ROOT/build/installer"
DMG=""; MACHINES=0; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dmg) DMG="$2"; shift 2 ;;
        --machines) MACHINES=1; shift ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n "2,/^$/p" "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done
[ -n "$DMG" ] || DMG="$(ls -t "$INSTALLER"/AVM-*.dmg 2>/dev/null | head -1)"
[ -f "$DMG" ] || { echo "FAILED: no DMG (build one with Tools/build-installer.sh, or pass --dmg)."; exit 1; }
VERSION="$(basename "$DMG" .dmg | sed 's/^AVM-//')"
ZIP="$(dirname "$DMG")/AVM-$VERSION.zip"
ITEM="$(dirname "$DMG")/appcast-item.xml"

FAILED=0
check() { if [ "$2" = 0 ]; then echo "   yes  $1"; else echo "   NO   $1${3:+: $3}"; FAILED=1; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/avm-release-test.XXXXXX")"
MOUNT="$WORK/mount"
cleanup() { hdiutil detach -quiet "$MOUNT" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

echo "== AVM $VERSION: $DMG"
echo
echo "== The DMG"
out="$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1)"
check "Gatekeeper accepts it" $? "$out"
out="$(xcrun stapler validate "$DMG" 2>&1)"
check "its notarization ticket is stapled" $? "$(echo "$out" | tail -1)"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT" "$DMG"
check "it opens" $?
[ -d "$MOUNT/AVM.app" ]; check "it holds AVM.app" $?
ditto "$MOUNT/AVM.app" "$WORK/AVM.app" 2>/dev/null
APP="$WORK/AVM.app"

echo
echo "== The app in it"
out="$(codesign --verify --deep --strict "$APP" 2>&1)"
check "its signature is whole" $? "$out"
out="$(spctl -a -t exec -vv "$APP" 2>&1)"
echo "$out" | grep -q "source=Notarized Developer ID"; check "Gatekeeper accepts it as notarized" $? "$(echo "$out" | tail -2 | tr '\n' ' ')"
out="$(xcrun stapler validate "$APP" 2>&1)"
check "its ticket is stapled" $? "$(echo "$out" | tail -1)"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }
SHORT="$(plist CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD="$(plist CFBundleVersion "$APP/Contents/Info.plist")"
[ "$SHORT" = "$VERSION" ]; check "it says it's $VERSION" $? "it says $SHORT"
for helper in "$APP"/Contents/Library/LaunchServices/* "$APP"/Contents/Resources/qemu-system-aarch64; do
    [ -e "$helper" ] || continue
    out="$(codesign --verify --strict "$helper" 2>&1)"
    check "$(basename "$helper") is signed" $? "$out"
done

echo
echo "== The update"
if [ -f "$ZIP" ] && [ -f "$ITEM" ]; then
    item_short="$(sed -n 's:.*<sparkle\:shortVersionString>\(.*\)</sparkle\:shortVersionString>.*:\1:p' "$ITEM")"
    item_build="$(sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' "$ITEM")"
    length="$(sed -n 's:.*length="\([0-9]*\)".*:\1:p' "$ITEM")"
    signature="$(sed -n 's:.*sparkle\:edSignature="\([^"]*\)".*:\1:p' "$ITEM")"
    [ "$item_short" = "$SHORT" ] && [ "$item_build" = "$BUILD" ]; check "the feed entry is $SHORT ($BUILD), as the app" $? "it says $item_short ($item_build)"
    [ "$length" = "$(stat -f %z "$ZIP")" ]; check "the zip's size is the feed entry's" $?
    unzip -qq -o "$ZIP" -d "$WORK/zip"
    [ "$(plist CFBundleVersion "$WORK/zip/AVM.app/Contents/Info.plist")" = "$BUILD" ]; check "the zip holds the same build" $?
    KEY="$(plist SUPublicEDKey "$APP/Contents/Info.plist" | tr -d '[:space:]')"
    cat > "$WORK/verify.swift" <<'EOF'
import CryptoKit
import Foundation
let a = CommandLine.arguments
guard let key = Data(base64Encoded: a[1]), let sig = Data(base64Encoded: a[2]),
      let data = FileManager.default.contents(atPath: a[3]),
      let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else { exit(2) }
exit(pub.isValidSignature(sig, for: data) ? 0 : 1)
EOF
    xcrun swift "$WORK/verify.swift" "$KEY" "$signature" "$ZIP" 2>/dev/null
    check "its signature is valid for the app's update key" $?
    last_tag="$(git -C "$REPO_ROOT" tag --list 'v*' --sort=-v:refname | grep -vx "v$VERSION" | head -1)"
    if [ -n "$last_tag" ]; then
        last_key="$(git -C "$REPO_ROOT" show "$last_tag:AVM/Info.plist" 2>/dev/null | plutil -extract SUPublicEDKey raw - 2>/dev/null | tr -d '[:space:]')"
        [ -n "$last_key" ] && [ "$last_key" = "$KEY" ]; check "the update key is $last_tag's, so installed copies accept it" $?
        last_build="$(git -C "$REPO_ROOT" show "$last_tag:AVM.xcodeproj/project.pbxproj" 2>/dev/null | sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' | head -1)"
        [ -n "$last_build" ] && [ "$BUILD" -gt "$last_build" ]; check "build $BUILD is newer than $last_tag's ($last_build)" $?
    fi
else
    check "the update zip and feed entry are beside the DMG" 1
fi

if [ $MACHINES = 1 ]; then
    echo
    echo "== Machines, with the app from the DMG"
    if pgrep -x AVM >/dev/null; then
        check "AVM is quit (the suite would test a re-signed copy)" 1
    else
        SUITE_LOG="$WORK/machines.txt"
        "$REPO_ROOT/Tools/run-all-tests.sh" --app "$APP" --only "windows-save windows-send windows-control debian-send debian-control debian-disk" \
            ${OUT:+--out "$OUT"} < /dev/null > "$SUITE_LOG"
        check "they passed" "$?"
        grep -E "^   (PASSED|FAILED|NO VERDICT|TIMED OUT|SKIPPED)" "$SUITE_LOG"
        # A skipped machine test isn't a tested release (2026-11-01 audit:
        # with no test machines this said "ready to publish").
        ! grep -q "^   SKIPPED" "$SUITE_LOG"; check "none of them was skipped" "$?"
    fi
fi

echo
if [ $FAILED = 0 ]; then echo "PASSED: AVM $VERSION is ready to publish."; else echo "FAILED: see the NO lines above."; fi
exit $FAILED
