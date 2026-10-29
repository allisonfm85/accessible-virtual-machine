#!/bin/bash
# run-all-tests.sh
# AVM — Accessible Virtual Machine
#
# Runs every automatic test AVM has, one after another, and prints one
# report (2026-10-28). It builds nothing: it uses an AVM build that already
# exists, and the test machines that Tools/test-windows-install.sh and
# Tools/test-linux-install.sh --keep leave in ~/Library/Caches/AVM-build.
# Nothing of yours is opened: the test jobs run machines from those
# folders only.
#
#   Tools/run-all-tests.sh [options]
#
#   --app PATH         the AVM.app to test (default: the Debug build)
#   --windows FOLDER   a Windows test machine (default: the newest install-test-*)
#   --debian FOLDER    a Debian test machine (default: the newest debian-test-*)
#   --debian2 FOLDER   a second one, for two machines at once (default: the next newest)
#   --fedora FOLDER    a Fedora test machine, on NVMe (default: the newest fedora-test-*);
#                      only disk info runs there: its agent can't run programs (SELinux)
#   --only WORDS       run only the tests whose names contain one of the words
#   --skip WORDS       skip the tests whose names contain one of the words
#   --with-downloads   include the screen-reader download test (1.5 GB)
#   --out FOLDER       keep every test's output there (default: a temporary folder)
#   --list             print the tests that would run, and stop
#
# The whole run takes about 45 minutes. Each test gets at most 25 minutes.
# One AVM runs at a time: two launched
# together have lost their arguments before (2026-10-28). The report says
# PASSED, FAILED (with the checks that said NO), or NO VERDICT (the test
# ended without saying), and the script exits 1 when anything failed.

set -uo pipefail

CACHE="$HOME/Library/Caches/AVM-build"
APP="$CACHE/DerivedData/Build/Products/Debug/AVM.app"
WINDOWS=""; DEBIAN=""; DEBIAN2=""; FEDORA=""
ONLY=""; SKIP=""; DOWNLOADS=0; OUT=""; LIST=0
LIMIT=1500
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --windows) WINDOWS="$2"; shift 2 ;;
        --debian) DEBIAN="$2"; shift 2 ;;
        --debian2) DEBIAN2="$2"; shift 2 ;;
        --fedora) FEDORA="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --skip) SKIP="$2"; shift 2 ;;
        --with-downloads) DOWNLOADS=1; shift ;;
        --out) OUT="$2"; shift 2 ;;
        --list) LIST=1; shift ;;
        -h|--help) sed -n 2,29p "$0"; exit 0 ;;
        *) echo "Unknown option $1. Run with --help."; exit 64 ;;
    esac
done

# By the date in the name, not the folder's modification time: the newest
# install has every feature the tests expect (an older Debian lacks the
# shared folder's sign-in script, 2026-10-28).
newest() { ls -d "$CACHE"/$1 2>/dev/null | sort | tail -1; }
second_newest() { ls -d "$CACHE"/$1 2>/dev/null | sort | tail -2 | head -1; }
[ -n "$WINDOWS" ] || WINDOWS="$(newest 'install-test-*')"
[ -n "$DEBIAN" ] || DEBIAN="$(newest 'debian-test-*')"
[ -n "$DEBIAN2" ] || DEBIAN2="$(second_newest 'debian-test-*')"
[ -n "$FEDORA" ] || FEDORA="$(newest 'fedora-test-*')"
[ -n "$OUT" ] || OUT="$(mktemp -d "${TMPDIR:-/tmp}/avm-tests-XXXXXX")"
mkdir -p "$OUT"

BIN="$APP/Contents/MacOS/AVM"
[ -x "$BIN" ] || { echo "No AVM at $APP. Build it first, or pass --app."; exit 1; }

# The tests: name | what it needs | the AVM arguments.
# Needs: none, windows, debian, debian2 (both Debian machines), fedora, downloads.
TESTS=()
add() { TESTS+=("$1|$2|$3"); }
add "unit tests"                       none     "swift-test"
add "accessibility audit"              none     "audit"
add "monitors"                         none     "--test-monitors"
add "windows save and resume"          windows  "--test-save-resume"
add "windows duplicate"                windows  "--test-duplicate"
add "windows send file"                windows  "--test-send-file"
add "windows control socket"           windows  "--test-ctl"
add "windows disk info"                windows  "--test-disk-info"
add "windows printers"                 windows  "--test-printers"
add "windows camera"                   windows  "--test-camera"
add "windows braille bridge"           windows  "--test-hid-bridge --braille"
add "windows agent shutdown"           windows  "--test-agent-shutdown"
add "windows remote desktop"           windows  "--test-remote-desktop"
add "debian save and resume"           debian   "--test-save-resume"
add "debian duplicate"                 debian   "--test-duplicate"
add "debian send file"                 debian   "--test-send-file"
add "debian shared folder"             debian   "--test-linux-share"
add "debian control socket"            debian   "--test-ctl"
add "debian disk info"                 debian   "--test-disk-info"
add "debian printers"                  debian   "--test-printers"
add "debian camera"                    debian   "--test-camera"
add "debian camera save"               debian   "--test-camera-save"
add "debian microphone"                debian   "--test-microphone"
add "debian hid bridge"                debian   "--test-hid-bridge"
add "debian background mode"           debian   "--test-background"
add "debian agent shutdown"            debian   "--test-agent-shutdown"
add "debian remote desktop"            debian   "--test-remote-desktop"
add "debian two machines"              debian2  "--test-two-machines"
add "debian 3d"                        debian   "--test-3d"
# Fedora: its guest agent can't run programs (SELinux), so the tests that
# read the guest don't work there, and its test machine is on NVMe, where
# Save isn't offered. 3D on Fedora was checked by hand (2026-10-27).
add "fedora disk info"                 fedora   "--test-disk-info --nvme"
add "screen reader downloads"          downloads "--test-screen-readers"

wanted() {
    local name="$1" w
    if [ -n "$ONLY" ]; then
        local hit=0
        for w in $ONLY; do case "$name" in *"$w"*) hit=1 ;; esac; done
        [ $hit = 1 ] || return 1
    fi
    for w in $SKIP; do case "$name" in *"$w"*) return 1 ;; esac; done
    return 0
}

machine_for() {
    case "$1" in
        windows) echo "$WINDOWS" ;;
        debian|debian2) echo "$DEBIAN" ;;
        fedora) echo "$FEDORA" ;;
        *) echo "" ;;
    esac
}

guest_for() {
    case "$1" in
        windows) echo windows ;;
        debian|debian2) echo debian ;;
        fedora) echo fedora ;;
    esac
}

# No test AVM may still be running from the last test.
wait_for_quiet() {
    local i
    for i in $(seq 1 60); do
        pgrep -f "$BIN" >/dev/null 2>&1 || return 0
        sleep 1
    done
    echo "   (an AVM from the last test is still running; stopping it)"
    pkill -f "$BIN" 2>/dev/null
    sleep 2
}

if [ $LIST = 1 ]; then
    for entry in "${TESTS[@]}"; do
        IFS='|' read -r name needs args <<< "$entry"
        wanted "$name" || continue
        folder="$(machine_for "$needs")"
        case "$needs" in
            none) place="" ;;
            downloads) place="(downloads; --with-downloads)" ;;
            *) place="($(basename "${folder:-missing}"))" ;;
        esac
        printf '   %-34s %s\n' "$name" "$place"
    done
    exit 0
fi

echo "AVM tests"
echo "   app: $APP"
echo "   Windows: ${WINDOWS:-none}"
echo "   Debian: ${DEBIAN:-none}${DEBIAN2:+, and $DEBIAN2}"
echo "   Fedora: ${FEDORA:-none}"
echo "   outputs: $OUT"
echo

RESULTS=()
FAILED=0
SUITE_START=$(date +%s)

run_one() {
    local name="$1" needs="$2" args="$3"
    local safe; safe="$(echo "$name" | tr ' ' '-')"
    local log="$OUT/$safe.txt" err="$OUT/$safe.err"
    local start; start=$(date +%s)
    local verdict="NO VERDICT" status=0

    case "$needs" in
        none) ;;
        downloads) [ $DOWNLOADS = 1 ] || { RESULTS+=("$name|SKIPPED|0|needs --with-downloads"); return; } ;;
        *)
            local folder; folder="$(machine_for "$needs")"
            if [ -z "$folder" ] || [ ! -d "$folder" ]; then
                RESULTS+=("$name|SKIPPED|0|no $needs test machine"); return
            fi
            if [ "$needs" = debian2 ] && { [ -z "$DEBIAN2" ] || [ ! -d "$DEBIAN2" ]; }; then
                RESULTS+=("$name|SKIPPED|0|no second Debian machine"); return
            fi
            ;;
    esac

    printf '%s… ' "$name"
    case "$args" in
        swift-test)
            (cd "$REPO_ROOT" && swift test --scratch-path "$CACHE/swiftpm" >"$log" 2>"$err")
            status=$?
            if grep -qE "Executed [0-9]+ tests, with [0-9]+ test(s)? skipped and 0 failures|Executed [0-9]+ tests, with 0 failures" "$log" && [ $status = 0 ]; then verdict=PASSED; else verdict=FAILED; fi
            ;;
        audit)
            "$REPO_ROOT/Tools/audit-accessibility.sh" --app "$APP" --out "$OUT/audit" >"$log" 2>"$err"
            status=$?
            if grep -q "^0 errors, " "$log" && [ $status = 0 ]; then verdict=PASSED; else verdict=FAILED; fi
            ;;
        *)
            wait_for_quiet
            local folder; folder="$(machine_for "$needs")"
            local extra=()
            if [ -n "$folder" ]; then extra+=(--vm "$folder" --guest "$(guest_for "$needs")"); fi
            if [ "$needs" = debian2 ]; then extra+=(--vm2 "$DEBIAN2" --guest2 debian); fi
            # shellcheck disable=SC2086
            timeout "$LIMIT" open -W -n "$APP" --stdout "$log" --stderr "$err" --args $args ${extra[@]+"${extra[@]}"}
            status=$?
            # open -W has come back before the test ended (2026-10-28: a
            # 4-minute test reported in 3 s): the verdict, or the test's
            # AVM gone, is what ends the wait, within the limit.
            local waited=$(( $(date +%s) - start ))
            while ! grep -qE "^(PASSED|FAILED)" "$log" 2>/dev/null && pgrep -f "$BIN" >/dev/null 2>&1 && [ $waited -lt "$LIMIT" ]; do
                sleep 2; waited=$((waited + 2))
            done
            [ $waited -lt "$LIMIT" ] || status=124
            wait_for_quiet
            if [ $status = 124 ]; then verdict="TIMED OUT"
            elif grep -q "^PASSED" "$log" 2>/dev/null; then verdict=PASSED
            elif grep -q "^FAILED" "$log" 2>/dev/null; then verdict=FAILED
            fi
            ;;
    esac
    local took=$(( $(date +%s) - start ))
    local detail=""
    if [ "$verdict" != PASSED ]; then
        detail="$(grep -E "^ *NO  " "$log" 2>/dev/null | sed 's/^ *NO  *//' | head -3 | tr '\n' ';' | sed 's/;$//')"
        FAILED=$((FAILED + 1))
    fi
    printf '%s (%d s)\n' "$verdict" "$took"
    RESULTS+=("$name|$verdict|$took|$detail")
}

for entry in "${TESTS[@]}"; do
    IFS='|' read -r name needs args <<< "$entry"
    wanted "$name" || continue
    run_one "$name" "$needs" "$args"
done

echo
echo "== Report"
passed=0; skipped=0
for r in ${RESULTS[@]+"${RESULTS[@]}"}; do
    IFS='|' read -r name verdict took detail <<< "$r"
    case "$verdict" in PASSED) passed=$((passed + 1)) ;; SKIPPED) skipped=$((skipped + 1)) ;; esac
    printf '   %-10s %-34s %4s s  %s\n' "$verdict" "$name" "$took" "$detail"
done
total=$(( $(date +%s) - SUITE_START ))
echo
echo "$passed passed, $FAILED failed, $skipped skipped, in $((total / 60)) min $((total % 60)) s. Outputs: $OUT"
[ $FAILED = 0 ]
