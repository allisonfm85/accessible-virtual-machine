#!/bin/bash
# test-linux-install.sh
# AVM — Accessible Virtual Machine
#
# A complete unattended Ubuntu, Debian or Fedora install with no one at the screen
# (2026-10-26), the Linux counterpart of test-windows-install.sh:
#   1. builds install media with AVM's own pipeline
#      (AVM --build-install-media --guest ubuntu|debian|fedora), with a test
#      account in the form the wizard writes;
#   2. makes a blank disk and firmware settings, and starts QEMU the way
#      AVM starts a Linux machine, with no window;
#   3. waits for the answer file's last step, the install-complete marker
#      (AVMDONE.TAG on the UNATTEND volume), or the failure marker
#      (AVMFAIL.TAG, Ubuntu and Fedora), and for the installer to power off;
#   4. says which. A screenshot (screen.png) is saved every 10 minutes and
#      when it gives up.
# It takes 20 to 60 minutes (Debian's and Fedora's netinstalls download the desktop) and
# about 15 GB while it runs. The test machine is deleted afterwards unless
# it failed or --keep.
#
#   Tools/test-linux-install.sh --iso PATH [--guest debian|ubuntu|fedora] [--app PATH] [--minutes N] [--keep] [--disk virtio|nvme]

set -euo pipefail

ISO=""
GUEST=debian
APP="$HOME/Library/Caches/AVM-build/DerivedData/Build/Products/Debug/AVM.app"
MINUTES=120
KEEP=0
DISK=virtio   # the disk new machines get (2026-10-27); nvme as older ones
LAYOUT=us
VARIANT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --iso) ISO="$2"; shift 2 ;;
        --guest) GUEST="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        --minutes) MINUTES="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --disk) DISK="$2"; shift 2 ;;
        --keyboard) LAYOUT="${2%%:*}"; [ "$2" != "$LAYOUT" ] && VARIANT="${2#*:}"; shift 2 ;;
        -h|--help) sed -n 2,22p "$0"; exit 0 ;;
        *) echo "Unknown option $1. Run with --help."; exit 64 ;;
    esac
done

case "$DISK" in nvme) DISKDEV=nvme ;; *) DISKDEV=virtio-blk-pci ;; esac
step() { echo; echo "== $1"; }
info() { echo "   $1"; }
fail() {
    echo "FAILED: $1"
    if [ $# -ge 2 ]; then echo "Next: $2"; fi
    command -v say >/dev/null && say "The $GUEST install test failed." || true
    exit 1
}

case "$GUEST" in ubuntu|debian|fedora) ;; *) fail "--guest must be ubuntu, debian or fedora." ;; esac
[ -n "$ISO" ] && [ -f "$ISO" ] || fail "No installer ISO given." "Pass one with --iso."
R="$APP/Contents/Resources"
[ -x "$APP/Contents/MacOS/AVM" ] && [ -x "$R/qemu-system-aarch64" ] || fail "No AVM build at $APP." "Build AVM first, or pass --app."

WORK="$HOME/Library/Caches/AVM-build/$GUEST-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"
chmod 700 "$WORK"
QMP="$WORK/qmp.sock"
QEMU_PID=""
RESULT=1

screenshot() {
    python3 -I - "$QMP" "$WORK/screen.png" <<'PY' >/dev/null 2>&1 || true
import json, os, socket, struct, sys, zlib
qmp, out = sys.argv[1], sys.argv[2]
ppm = out + ".ppm"
s = socket.socket(socket.AF_UNIX); s.settimeout(20); s.connect(qmp); f = s.makefile("rw")
f.readline(); f.write('{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()
f.write(json.dumps({"execute": "screendump", "arguments": {"filename": ppm}}) + "\n"); f.flush(); f.readline()
data = open(ppm, "rb").read()
magic, size, maxval, pixels = data.split(b"\n", 3)
w, h = map(int, size.split())
raw = b"".join(b"\x00" + pixels[y * w * 3:(y + 1) * w * 3] for y in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
open(out, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
os.remove(ppm)
PY
}

markers() {
    MTOOLS_SKIP_CHECK=1 env -u DYLD_LIBRARY_PATH "$R/mtools" -c mdir -b -i "$WORK/autounattend.img" :: 2>/dev/null | tr -d '\r' || true
}

cleanup() {
    # A kept machine is shut down properly first (2026-10-26): a power cut
    # right after the first sign-in left Orca's new settings file empty,
    # and Orca crashed on it at every later start.
    if [ "$KEEP" = "1" ] && [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null && [ -S "$WORK/qga.sock" ]; then
        python3 -I - "$WORK/qga.sock" <<'PY' >/dev/null 2>&1 || true
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-shutdown","arguments":{"mode":"powerdown"}}\n')
PY
        for _ in $(seq 1 24); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 5; done
    fi
    [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null && kill "$QEMU_PID" 2>/dev/null || true
    if [ "$RESULT" = "0" ] && [ "$KEEP" = "0" ]; then rm -rf "$WORK"; else echo "   The test machine is kept in $WORK"; fi
}
trap cleanup EXIT

step "Building install media with AVM's pipeline ($GUEST)"
info "ISO: $ISO"
# The test account, as the wizard saves it: password "Hello world!", in
# the SHA-512 crypt form (the specification's own test vector).
cat > "$WORK/ubuntu-account.json" <<'JSON'
{"realName":"AVM Test","userName":"avmtest","passwordHash":"$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1","signInAutomatically":true,"keyboardLayout":"LAYOUT_HERE"VARIANT_HERE}
JSON
# --keyboard LAYOUT[:VARIANT] (2026-10-26): the account's keyboard, as the
# wizard writes it, so a layout and Mac variant reaching the installed
# system can be checked (the desktop check prints /etc/default/keyboard).
sed -i '' -e "s/LAYOUT_HERE/$LAYOUT/" -e "s/VARIANT_HERE/${VARIANT:+,\"keyboardVariant\":\"$VARIANT\"}/" "$WORK/ubuntu-account.json"
chmod 600 "$WORK/ubuntu-account.json"
"$APP/Contents/MacOS/AVM" --build-install-media --guest "$GUEST" --disk "$DISK" --iso "$ISO" --out "$WORK" \
    || fail "AVM couldn't build the install media." "See the line above, and AVM's diagnostic log."
[ -f "$WORK/install-avm.iso" ] && [ -f "$WORK/autounattend.img" ] || fail "AVM said it built the media, but the files aren't there."

step "Making the test machine"
"$R/qemu-img" create -q -f qcow2 "$WORK/disk.qcow2" 40G
python3 -I - "$R/edk2-arm-vars.fd" "$WORK/nvram.fd" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(data + b"\0" * (64 * 1024 * 1024 - len(data)))
PY
info "40 GB disk, 4 cores, 4 GB of memory"

step "Starting the $GUEST installer (no window)"
"$R/qemu-system-aarch64" -L "$R" \
    -machine virt,accel=hvf -cpu host -smp 4 -m 4096M \
    -drive "if=pflash,format=raw,file=$R/edk2-aarch64-code.fd,readonly=on" \
    -drive "if=pflash,format=raw,file=$WORK/nvram.fd" \
    -device qemu-xhci,id=usb,p2=8,p3=8 \
    -device usb-kbd,bus=usb.0,port=1 \
    -device usb-tablet,bus=usb.0,port=2,display=gpu0 \
    -drive "if=none,id=disk0,file=$WORK/disk.qcow2,format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap" \
    -device "$DISKDEV,drive=disk0,serial=avmdisk0,bootindex=1" \
    -drive "if=none,id=cdrom0,file=$WORK/install-avm.iso,media=cdrom,readonly=on" \
    -device usb-storage,drive=cdrom0,bus=usb.0,port=3,bootindex=0,removable=on \
    -drive "if=none,id=unattend,file=$WORK/autounattend.img,format=raw,cache=writeback" \
    -device usb-storage,drive=unattend,bus=usb.0,port=4,removable=on \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -spice "unix=on,addr=$WORK/spice.sock,disable-ticketing=on,agent-mouse=on,gl=off" \
    -device ramfb -device virtio-gpu-pci,id=gpu0 \
    -audiodev none,id=noaudio -device intel-hda -device hda-duplex,audiodev=noaudio \
    -device virtio-serial-pci \
    -chardev spicevmc,id=vdagent,name=vdagent \
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
    -chardev "socket,id=char-qmp,path=$QMP,server=on,wait=off" -qmp chardev:char-qmp \
    -rtc base=utc,clock=host \
    -serial "file:$WORK/serial.log" -display none -monitor none \
    > "$WORK/qemu.log" 2>&1 &
QEMU_PID=$!
for _ in $(seq 1 20); do [ -S "$QMP" ] && break; sleep 0.5; done
[ -S "$QMP" ] || fail "QEMU didn't start." "See $WORK/qemu.log."

step "Waiting for the install (checking every minute, up to $MINUTES minutes)"
START=$(date +%s)
while :; do
    ELAPSED=$(( ($(date +%s) - START) / 60 ))
    M="$(markers)"
    if echo "$M" | grep -qi "AVMDONE.TAG"; then
        info "$ELAPSED min: the install-complete marker is written."
        break
    fi
    if echo "$M" | grep -qi "AVMFAIL.TAG"; then
        screenshot
        fail "The installer reported a failure (AVMFAIL.TAG)." "Its logs are on the UNATTEND volume in $WORK/autounattend.img."
    fi
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        fail "The machine powered off without the install-complete marker." "See $WORK/serial.log and $WORK/qemu.log."
    fi
    [ $((ELAPSED % 10)) -eq 0 ] && [ "$ELAPSED" -gt 0 ] && screenshot
    if [ "$ELAPSED" -ge "$MINUTES" ]; then
        screenshot
        fail "The install didn't finish in $MINUTES minutes." "See $WORK/screen.png."
    fi
    sleep 60
done

# The installer powers off after its last step.
for _ in $(seq 1 30); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 10; done
if kill -0 "$QEMU_PID" 2>/dev/null; then
    screenshot
    info "The marker is written, but the installer hasn't powered off after 5 minutes (screen.png)."
else
    info "The installer powered off, as AVM expects."
fi

kill "$QEMU_PID" 2>/dev/null || true
sleep 3

# THE DESKTOP AFTER THE INSTALL (2026-10-26): the installed disk started
# again, with the guest agent's channel, and asked what a person at the
# screen gets: the signed-in session and its kind (Wayland or X11), and
# whether spice-vdagent (clipboard, mouse) and Orca are running.
step "Starting the installed $GUEST and checking its desktop (up to 10 minutes)"
rm -f "$QMP"
"$R/qemu-system-aarch64" -L "$R" \
    -machine virt,accel=hvf -cpu host -smp 4 -m 4096M \
    -drive "if=pflash,format=raw,file=$R/edk2-aarch64-code.fd,readonly=on" \
    -drive "if=pflash,format=raw,file=$WORK/nvram.fd" \
    -device qemu-xhci,id=usb,p2=8,p3=8 \
    -device usb-kbd,bus=usb.0,port=1 \
    -device usb-tablet,bus=usb.0,port=2,display=gpu0 \
    -drive "if=none,id=disk0,file=$WORK/disk.qcow2,format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap" \
    -device "$DISKDEV,drive=disk0,serial=avmdisk0,bootindex=1" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    -spice "unix=on,addr=$WORK/spice.sock,disable-ticketing=on,agent-mouse=on,gl=off" \
    -device ramfb -device virtio-gpu-pci,id=gpu0 \
    -audiodev none,id=noaudio -device intel-hda -device hda-duplex,audiodev=noaudio \
    -device virtio-serial-pci \
    -chardev spicevmc,id=vdagent,name=vdagent \
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
    -chardev "socket,id=qga0,path=$WORK/qga.sock,server=on,wait=off" \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -chardev "socket,id=char-qmp,path=$QMP,server=on,wait=off" -qmp chardev:char-qmp \
    -rtc base=utc,clock=host \
    -serial "file:$WORK/serial-2.log" -display none -monitor none \
    > "$WORK/qemu-2.log" 2>&1 &
QEMU_PID=$!
DESKTOP=""
for _ in $(seq 1 40); do
    sleep 15
    DESKTOP=$(python3 -I - "$WORK/qga.sock" <<'PY' 2>/dev/null || true
import base64, json, socket, sys, time
def call(cmd, args=None):
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
    msg = {"execute": cmd}
    if args: msg["arguments"] = args
    s.sendall((json.dumps(msg) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"): data += s.recv(65536)
    return json.loads(data)["return"]
script = r"""
s=$(loginctl list-sessions --no-legend | awk '$3=="avmtest"{print $1; exit}')
[ -n "$s" ] && echo "session $(loginctl show-session "$s" -p Type --value)" || echo "session none"
pgrep -x spice-vdagent >/dev/null && echo "spice-vdagent running" || echo "spice-vdagent not running"
grep -h "^XKB[LV]" /etc/default/keyboard 2>/dev/null
# [o]rca: this script's own command line holds the word, and pgrep -f
# matched itself (2026-10-26, code audit), so Orca always "ran".
ps -eo args | grep -q "[o]rca" && echo "orca running" || echo "orca not running"
"""
pid = call("guest-exec", {"path": "/bin/sh", "arg": ["-c", script], "capture-output": True})["pid"]
for _ in range(20):
    st = call("guest-exec-status", {"pid": pid})
    if st.get("exited"): break
    time.sleep(1)
print(base64.b64decode(st.get("out-data", "")).decode())
PY
)
    echo "$DESKTOP" | grep -q "session [a-z]" && ! echo "$DESKTOP" | grep -q "session none" && break
done
if [ -z "$DESKTOP" ]; then
    screenshot
    fail "The installed $GUEST didn't answer through the guest agent in 10 minutes." "See $WORK/screen.png."
fi
if echo "$DESKTOP" | grep -q "session none" && [ "$GUEST" != "fedora" ]; then
    screenshot
    fail "Nobody was signed in after 10 minutes: the automatic sign-in didn't happen." "See $WORK/screen.png."
fi
echo "$DESKTOP" | sed 's/^/   /'
# MEASURED 2026-10-26, Debian 13.7: a Wayland session, with spice-vdagent
# 0.22.1 running and talking to GNOME's compositor (its log reads Mutter's
# monitors). Whether the clipboard then crosses isn't proven here: that
# needs a SPICE client offering one. The agent running is the requirement.
CLIPBOARD="no"
echo "$DESKTOP" | grep -q "spice-vdagent running" && CLIPBOARD="yes"
info "the clipboard agent is running: $CLIPBOARD"
# Fedora's SELinux policy keeps the guest agent from listing processes
# (2026-10-26), so there it's reported, not required.
if ! echo "$DESKTOP" | grep -q "orca running"; then
    if [ "$GUEST" = "fedora" ]; then
        info "(Orca can't be seen from the guest agent on Fedora; its setting is checked by the install)"
    else
        screenshot; fail "Orca isn't running after sign-in."
    fi
fi

RESULT=0
ELAPSED=$(( ($(date +%s) - START) / 60 ))
echo; echo "PASSED: $GUEST installed in $ELAPSED minutes."
[ "$CLIPBOARD" = "yes" ] || echo "   (but the clipboard agent isn't running; see above)"
command -v say >/dev/null && say "The $GUEST install test passed." || true
