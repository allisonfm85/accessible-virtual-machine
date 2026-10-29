#!/bin/bash
# test-macos-machine.sh
# AVM — Accessible Virtual Machine
#
# A macOS machine tested end to end with no one at the screen (2026-10-26),
# the macOS counterpart of test-windows-install.sh. AVM itself does the
# work (AVM --test-mac-machine, MacTestJob.swift):
#   1. installs macOS from an IPSW, as New macOS Virtual Machine does, with
#      its fresh-install restore point;
#   2. starts it and waits for macOS to come up (it asks for a network
#      address once Setup Assistant runs);
#   3. saves it while running and stops it, as Save and Quit does;
#   4. resumes it from the saved state, as the next Start does;
#   5. puts it back to the fresh-install restore point and starts it again.
# It takes 15 to 30 minutes and about 30 GB while it runs. The test machine
# is deleted afterwards unless it failed or --keep.
#
#   Tools/test-macos-machine.sh [--ipsw PATH] [--app PATH] [--keep] [--reuse FOLDER]
#
# --reuse FOLDER runs the steps after the install on a test machine a
# failed run kept, which saves the install's few minutes.
#
# Without --ipsw it uses the macOS installer AVM downloaded before.

set -euo pipefail

IPSW=""
APP="$HOME/Library/Caches/AVM-build/DerivedData/Build/Products/Debug/AVM.app"
KEEP=0
REUSE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ipsw) IPSW="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --reuse) REUSE="$2"; shift 2 ;;
        -h|--help) sed -n 2,24p "$0"; exit 0 ;;
        *) echo "Unknown option $1. Run with --help."; exit 64 ;;
    esac
done

fail() {
    echo "FAILED: $1"
    command -v say >/dev/null && say "The macOS machine test failed." || true
    exit 1
}

if [ -z "$IPSW" ]; then
    IPSW=$(ls -t "$HOME/Library/Application Support/com.alllisonmeloy.AVM/macos-restore-images/"*.ipsw 2>/dev/null | head -1 || true)
fi
[ -n "$IPSW" ] && [ -f "$IPSW" ] || fail "No macOS installer. Pass one with --ipsw, or make a macOS machine in AVM once so it downloads one."
[ -x "$APP/Contents/MacOS/AVM" ] || fail "No AVM build at $APP. Build AVM first, or pass --app."

WORK="${REUSE:-$HOME/Library/Caches/AVM-build/macos-test-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$WORK"
chmod 700 "$WORK"
START=$(date +%s)

set +e
"$APP/Contents/MacOS/AVM" --test-mac-machine --ipsw "$IPSW" --out "$WORK" ${REUSE:+--reuse}
CODE=$?
set -e
MINUTES=$(( ($(date +%s) - START + 59) / 60 ))

if [ $CODE -eq 0 ]; then
    echo
    echo "PASSED in $MINUTES minutes."
    if [ $KEEP -eq 1 ]; then echo "   The test machine is kept in $WORK"; else rm -rf "$WORK"; fi
    command -v say >/dev/null && say "The macOS machine test passed." || true
else
    echo
    echo "   The test machine is kept in $WORK"
    fail "after $MINUTES minutes; see the steps above."
fi
