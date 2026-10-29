#!/bin/bash
# measure-audio-latency.sh
# AVM — Accessible Virtual Machine
#
# Compares sound settings for QEMU machines by key-to-speech latency, with
# no one at the screen (2026-10-26). On a Debian machine kept by
# test-linux-install.sh --keep (Orca signs in by itself there), for each
# setting given it starts the machine headless with that sound setting,
# waits for the desktop and Orca, then has Tools/audio-latency press Orca's
# "say the time" 20 times through QEMU's control socket and time the speech.
#
#   Tools/measure-audio-latency.sh --vm FOLDER [--app PATH] SETTING...
#
# Settings:
#   spice            today's default: the guest's sound through SPICE, played
#                    by AVM's audio pipeline
#   spice-low        the same with AVM's "Shorter speech delay" pipeline
#   coreaudio        QEMU plays to the Mac itself, QEMU's default buffers
#   coreaudio-N-C    QEMU plays to the Mac itself with C buffers of N
#                    microseconds (for example coreaudio-5000-2)
#   ...-notimer      any of the above with the sound card's timer off
#   (AVM itself uses coreaudio-2500-2-notimer since 2026-10-27.)
#
# Each line of the summary is "RESULT <setting>: median …".

set -euo pipefail

VM=""
APP="$HOME/Library/Caches/AVM-build/DerivedData/Build/Products/Debug/AVM.app"
SETTINGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --vm) VM="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        -h|--help) sed -n 2,26p "$0"; exit 0 ;;
        *) SETTINGS+=("$1"); shift ;;
    esac
done
[ -n "$VM" ] && [ -f "$VM/disk.qcow2" ] || { echo "FAILED: no kept test machine at $VM"; exit 1; }
[ ${#SETTINGS[@]} -gt 0 ] || SETTINGS=(spice coreaudio)
R="$APP/Contents/Resources"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$HOME/Library/Caches/AVM-tools/audio-latency"
if [ ! -x "$TOOL" ] || [ "$HERE/audio-latency/main.swift" -nt "$TOOL" ]; then
    mkdir -p "$(dirname "$TOOL")"
    xcrun swiftc -O -target arm64-apple-macos14.2 "$HERE/audio-latency/main.swift" -o "$TOOL"
fi

# Only for reference: AVM's QEMU converts 48 kHz to whatever the Mac's output
# runs at (AirPods in hands-free mode run at 24 kHz). QEMU without AVM's
# coreaudio patch plays nothing unless the two match.
echo "The Mac's sound output runs at $("$TOOL" --output-rate) Hz."

QEMU_PID=""
PLAYER_PID=""
stop_all() {
    [ -n "$PLAYER_PID" ] && kill "$PLAYER_PID" 2>/dev/null || true
    if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null; then
        # The guest shut down properly, so the machine stays usable.
        python3 -I - "$VM/qga.sock" <<'PY' >/dev/null 2>&1 || true
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-shutdown","arguments":{"mode":"powerdown"}}\n')
PY
        for _ in $(seq 1 24); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 5; done
        kill "$QEMU_PID" 2>/dev/null || true
    fi
    QEMU_PID=""; PLAYER_PID=""
}
trap stop_all EXIT

desktop_ready() {
    python3 -I - "$VM/qga.sock" <<'PY' 2>/dev/null
import base64, json, socket, sys, time
def call(cmd, args=None):
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
    m = {"execute": cmd}
    if args: m["arguments"] = args
    s.sendall((json.dumps(m) + "\n").encode()); d = b""
    while not d.endswith(b"\n"): d += s.recv(65536)
    return json.loads(d)["return"]
pid = call("guest-exec", {"path": "/bin/sh", "arg": ["-c", "ps -eo args | grep -q '[o]rca' && echo ready"], "capture-output": True})["pid"]
for _ in range(20):
    st = call("guest-exec-status", {"pid": pid})
    if st.get("exited"): break
    time.sleep(1)
sys.exit(0 if b"ready" in base64.b64decode(st.get("out-data", "")) else 1)
PY
}

for SETTING in "${SETTINGS[@]}"; do
    echo
    echo "== $SETTING"
    HDA="hda-duplex,audiodev=snd"
    case "$SETTING" in *-notimer) HDA="$HDA,use-timer=off"; BASE="${SETTING%-notimer}" ;; *) BASE="$SETTING" ;; esac
    case "$BASE" in
        spice|spice-low) AUDIODEV="spice,id=snd" ;;
        coreaudio) AUDIODEV="coreaudio,id=snd,out.frequency=48000" ;;
        coreaudio-*-*)
            LEN="$(echo "$BASE" | cut -d- -f2)"; COUNT="$(echo "$BASE" | cut -d- -f3)"
            AUDIODEV="coreaudio,id=snd,out.frequency=48000,out.buffer-length=$LEN,out.buffer-count=$COUNT,timer-period=$(( LEN / 2 ))" ;;
        *) echo "Unknown setting $SETTING"; continue ;;
    esac
    rm -f "$VM/qmp.sock" "$VM/qga.sock" "$VM/spice.sock"
    "$R/qemu-system-aarch64" -L "$R" \
        -machine virt,accel=hvf -cpu host -smp 4 -m 4096M \
        -drive "if=pflash,format=raw,file=$R/edk2-aarch64-code.fd,readonly=on" \
        -drive "if=pflash,format=raw,file=$VM/nvram.fd" \
        -device qemu-xhci,id=usb,p2=8,p3=8 -device usb-kbd,bus=usb.0,port=1 \
        -device usb-tablet,bus=usb.0,port=2,display=gpu0 \
        -drive "if=none,id=disk0,file=$VM/disk.qcow2,format=qcow2,cache=writeback" \
        -device nvme,drive=disk0,serial=avmdisk0,bootindex=1 \
        -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
        -spice "unix=on,addr=$VM/spice.sock,disable-ticketing=on,agent-mouse=on" \
        -device ramfb -device virtio-gpu-pci,id=gpu0 \
        -audiodev "$AUDIODEV" -device intel-hda -device "$HDA" \
        -device virtio-serial-pci \
        -chardev spicevmc,id=vdagent,name=vdagent -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
        -chardev "socket,id=qga0,path=$VM/qga.sock,server=on,wait=off" -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
        -chardev "socket,id=char-qmp,path=$VM/qmp.sock,server=on,wait=off" -qmp chardev:char-qmp \
        -rtc base=utc,clock=host -display none -monitor none > "$VM/qemu-$SETTING.log" 2>&1 &
    QEMU_PID=$!
    for _ in $(seq 1 20); do [ -S "$VM/spice.sock" ] && break; sleep 0.5; done
    LISTEN_PID="$QEMU_PID"
    case "$BASE" in
        spice|spice-low)
            LOW=""; [ "$BASE" = "spice-low" ] && LOW="--low-latency"
            "$APP/Contents/MacOS/AVM" --play-spice-audio --spice "$VM/spice.sock" $LOW > "$VM/player-$SETTING.log" 2>&1 &
            PLAYER_PID=$!
            LISTEN_PID="$PLAYER_PID" ;;
    esac
    READY=0
    for _ in $(seq 1 60); do sleep 5; desktop_ready && { READY=1; break; }; done
    [ "$READY" = "1" ] || { echo "   the desktop and Orca didn't come up; skipped"; stop_all; continue; }
    sleep 20   # the desktop settles, and the first sound opens the audio path
    "$TOOL" --qmp "$VM/qmp.sock" --pid "$LISTEN_PID" --label "$SETTING" | sed 's/^/   /' || true
    stop_all
done
