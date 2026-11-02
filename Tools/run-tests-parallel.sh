#!/bin/bash
# run-tests-parallel.sh
# AVM — Accessible Virtual Machine
#
# The whole suite in about half the time (2026-11-01, the user's request): one
# group for each Linux distribution, side by side, then what can't be.
#   - The app's own identifier and signature run Windows, the update and what
#     the Mac has one of. Every other group is a clone with an identifier of its
#     own: two copies with one identifier lose their arguments, and loginwindow
#     stops the second (avm-own-copy.sh). A clone is signed for this Mac only.
#   - A second group can't use a machine's disk, so the Debian tests that need
#     the app's own signature (camera, microphone) or that a clone can't do
#     (Finder send) run last, one at a time, with two machines at once.
#   - With AVM open, even the app's own groups run from a copy: quit AVM first,
#     or the camera and microphone tests fail for want of its signature.
#   - A clone may not be able to look up .local names, so Remote Desktop's name is checked
#     only on the app's own identifier.
#
#   Tools/run-tests-parallel.sh --app PATH [--windows FOLDER] [--with-downloads] --out FOLDER
#
# A failure here still gets a rerun alone before it's believed: load can do it.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP=""; OUT=""; PASS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --windows) PASS+=(--windows "$2"); shift 2 ;;
        --with-downloads) PASS+=(--with-downloads); shift ;;
        *) echo "Unknown option: $1"; exit 64 ;;
    esac
done
[ -n "$APP" ] && [ -n "$OUT" ] || { echo "Usage: $0 --app PATH --out FOLDER [--windows FOLDER] [--with-downloads]"; exit 64; }
mkdir -p "$OUT"
. "$REPO_ROOT/Tools/avm-own-copy.sh"
LAST="debian-camera debian-microphone debian-two debian-finder"
COPIES=()
"$REPO_ROOT/Tools/run-all-tests.sh" --app "$APP" ${PASS[@]+"${PASS[@]}"} --out "$OUT/main" \
    --only "unit accessibility monitors windows update tour screen-reader-downloads" > "$OUT/main.log" 2>&1 < /dev/null &
group() {
    local name="$1"; shift
    avm_own_copy "$APP" "par$name" always
    COPIES+=("$AVM_COPY_DIR")
    "$REPO_ROOT/Tools/run-all-tests.sh" --app "$AVM_COPY" ${PASS[@]+"${PASS[@]}"} --out "$OUT/$name" "$@" > "$OUT/$name.log" 2>&1 < /dev/null &
}
group debian --only debian --skip "$LAST"
for distro in ubuntu fedora kali almalinux rocky opensuse; do group "$distro" --only "$distro"; done
wait
"$REPO_ROOT/Tools/run-all-tests.sh" --app "$APP" ${PASS[@]+"${PASS[@]}"} --out "$OUT/last" --only "$LAST" > "$OUT/last.log" 2>&1 < /dev/null
for copy in ${COPIES[@]+"${COPIES[@]}"}; do rm -rf "$copy"; done
echo
FAILED=0; PASSED=0
for log in "$OUT"/*.log; do
    grep -E "^   (FAILED|TIMED OUT|NO VERDICT|SKIPPED)|not checked" "$log" | cut -c1-160
    p="$(grep -c '… PASSED' "$log")"; f="$(grep -cE '… (FAILED|TIMED OUT|NO VERDICT)' "$log")"
    PASSED=$((PASSED + p)); FAILED=$((FAILED + f))
done
echo "$PASSED passed, $FAILED failed. Outputs: $OUT"
[ "$FAILED" = 0 ] && [ "$PASSED" -gt 0 ]
