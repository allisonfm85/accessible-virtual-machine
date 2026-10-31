#!/bin/bash
# audit-accessibility.sh
# AVM — Accessible Virtual Machine
#
# An automatic accessibility check of AVM's own windows (2026-10-26). It
# builds nothing: it runs an AVM build that already exists
# (AVM --audit-accessibility, AccessibilityAudit.swift), which opens each
# screen with sample machines in a temporary folder, off every screen and
# without taking focus, reads it as VoiceOver would, and prints the
# report. Your own virtual machines are never opened. It takes about half
# a minute and says nothing out loud.
#
#   Tools/audit-accessibility.sh [--app PATH] [--out FOLDER] [--only SCREEN] [--keep] [--pictures FOLDER] [--dark]
#
# --out keeps the report (accessibility-report.txt) and everything read
# (accessibility-tree.txt) in FOLDER; without it they go in a temporary
# folder that is printed. --only checks just the screens whose names
# contain SCREEN, for example "Settings". --keep keeps the sample machines.
# Exits 0 when there is nothing at error level, 1 when there is.

set -euo pipefail

APP="$HOME/Library/Caches/AVM-build/DerivedData/Build/Products/Debug/AVM.app"
OUT=""
EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --only) EXTRA+=(--only "$2"); shift 2 ;;
        --keep) EXTRA+=(--keep); shift ;;
        --pictures) EXTRA+=(--pictures "$2"); shift 2 ;;
        --dark) EXTRA+=(--dark); shift ;;
        -h|--help) sed -n 2,19p "$0"; exit 0 ;;
        *) echo "Unknown option $1. Run with --help."; exit 64 ;;
    esac
done

fail() {
    echo "FAILED: $1"
    if [ $# -ge 2 ]; then echo "Next: $2"; fi
    exit 1
}

[ -x "$APP/Contents/MacOS/AVM" ] || fail "No AVM build at $APP." "Build AVM first, or pass --app."
if [ -z "$OUT" ]; then
    OUT="$(mktemp -d "${TMPDIR:-/tmp}/avm-accessibility-XXXXXX")"
fi
mkdir -p "$OUT"

# The audit is its own AVM process; an AVM that's already running is
# left alone. ${EXTRA[@]+...} keeps an empty list working under macOS's
# bash 3.2 with set -u.
# An old report never stands in for this run's (2026-10-26, code audit).
rm -f "$OUT/accessibility-report.txt" "$OUT/accessibility-tree.txt"

# A copy with its own bundle identifier (2026-10-30, avm-own-copy.sh): a
# full audit takes longer than the 30 seconds loginwindow gives a second
# AVM. Always, so its settings are its own too, apart from AVM's.
. "$(dirname "$0")/avm-own-copy.sh"
avm_own_copy "$APP" audit always || fail "Couldn't make the audit's copy of AVM." "Check that $APP is a complete AVM build."
trap 'rm -rf "$AVM_COPY_DIR"' EXIT
AUDIT_APP="$AVM_COPY"

set +e
"$AUDIT_APP/Contents/MacOS/AVM" --audit-accessibility --out "$OUT" ${EXTRA[@]+"${EXTRA[@]}"} 2>"$OUT/audit-stderr.txt"
RESULT=$?
set -e

REPORT="$OUT/accessibility-report.txt"
[ -f "$REPORT" ] || fail "The audit wrote no report (exit $RESULT)." "See $OUT/audit-stderr.txt."
echo
echo "== Findings"
# Level, screen, role, path and problem, without the header lines.
grep -E '^(ERROR|WARNING|NOTE)' "$REPORT" | awk -F '\t' '{ printf "%-7s %s | %s | %s\n        %s\n", $1, $2, $3, $4, $5 }' || echo "   None."
exit "$RESULT"
