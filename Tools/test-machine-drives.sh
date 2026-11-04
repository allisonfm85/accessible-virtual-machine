#!/bin/bash
# test-machine-drives.sh
# AVM — Accessible Virtual Machine
#
# The second drive and a grown disk on real machines (2026-11-03). That test
# changes the disk, so it's apart from run-all-tests.sh and runs on throwaway
# clones of the newest Windows and Debian test machines, side by side.
#
#   Tools/test-machine-drives.sh [--app PATH] OUT_FOLDER

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/Tools/avm-own-copy.sh"
C="$HOME/Library/Caches/AVM-build"
APP="$C/DerivedData/Build/Products/Debug/AVM.app"
if [ "${1:-}" = "--app" ]; then APP="$2"; shift 2; fi
OUT="${1:?Usage: $0 [--app PATH] OUT_FOLDER}"
mkdir -p "$OUT"

run() {
    local guest="$1" machine work copy dir
    machine="$(ls -dt "$C"/"$2"-* 2>/dev/null | head -1)"
    [ -n "$machine" ] || { echo "No $2 machine." > "$OUT/$guest.txt"; return; }
    work="$C/dt-$guest"
    rm -rf "$work"
    cp -c -R "$machine" "$work"
    rm -f "$work"/*.sock
    avm_own_copy "$APP" "dt$guest" always
    copy="$AVM_COPY"; dir="$AVM_COPY_DIR"
    "$copy/Contents/MacOS/AVM" --test-machine-drives --vm "$work" --guest "$guest" > "$OUT/$guest.txt" 2>&1
    echo "exit $?" >> "$OUT/$guest.txt"
    cp "$work/qemu.log" "$OUT/$guest-qemu.log" 2>/dev/null
    [ -n "$dir" ] && rm -rf "$dir"
    rm -rf "$work"
}

run windows install-test &
run debian debian-test &
wait
echo finished
