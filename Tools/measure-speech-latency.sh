#!/bin/bash
# measure-speech-latency.sh
# AVM — Accessible Virtual Machine
#
# Compiles Tools/speech-latency (once, or again when it changes) and runs
# it with any options given. It measures how long a screen reader in a VM
# takes to start speaking after a key press; Tools/speech-latency/main.swift
# explains how, and what to set up first.
#
#   Tools/measure-speech-latency.sh --label "AVM 0.1.3"
#   Tools/measure-speech-latency.sh --label Parallels --csv parallels.csv
#   Tools/measure-speech-latency.sh --help

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/speech-latency/main.swift"
BIN="${AVM_TOOLS_BUILD:-$HOME/Library/Caches/AVM-tools}/speech-latency"

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    mkdir -p "$(dirname "$BIN")"
    echo "Compiling the speech latency tool..."
    xcrun swiftc -O -target arm64-apple-macos14.2 "$SRC" -o "$BIN" || {
        echo "FAILED: the speech latency tool did not compile."
        exit 1
    }
fi

exec "$BIN" "$@"
