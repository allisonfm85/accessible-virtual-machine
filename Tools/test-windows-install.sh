#!/bin/bash
# test-windows-install.sh
# AVM — Accessible Virtual Machine
#
# A complete unattended Windows install with no one at the screen
# (2026-10-26), to prove a change to the answer file or the install media
# before anyone spends an hour on a test install:
#   1. builds fresh install media with AVM's own pipeline
#      (AVM --build-install-media), with NVDA and JAWS, and setup answers
#      for a local test account, so Windows signs in by itself;
#   2. makes a blank disk, Secure Boot firmware settings and a TPM, and
#      starts QEMU the way AVM does, with no window;
#   3. presses Enter at "Press any key to boot from CD", then waits;
#   4. reads AVMSTATUS.TXT, the report the answer file writes on the
#      UNATTEND volume, until the first sign-in has finished;
#   5. says what was installed and what wasn't. It saves a screenshot
#      (screen.png) every 10 minutes, and when it gives up, so a stuck
#      screen can be seen at once.
# It takes 30 to 90 minutes and about 25 GB of disk space while it runs.
# The test machine is deleted afterwards unless it failed or --keep.
#
#   Tools/test-windows-install.sh [--iso PATH] [--app PATH] [--minutes N] [--keep] [--disk virtio|nvme] [--keyboard] [--reuse FOLDER]
#
# --iso      a Windows 11 ARM64 ISO (default: the newest *arm64*.iso in Downloads)
# --app      the AVM.app to test (default: the Debug build in ~/Library/Caches/AVM-build)
# --minutes  how long to wait before giving up (default 150)
# --reuse    start a test machine a failed run kept, instead of installing
#            (with --keyboard: try the keyboard check again in minutes)
# --keyboard after the install, types a fixed set of keys into Windows
#            through AVM's own keyboard path (AVM --test-keyboard) and
#            checks what Windows received: both Shifts released, Delete,
#            Pause, and no Start menu on the way back to the Mac
# --latency  plays Windows' sound to the Mac the way AVM does, and after
#            the install times NVDA's "say the time" (NVDA+F12) 20 times,
#            from the key to the first sound (Tools/audio-latency)

set -euo pipefail

ISO=""
APP="$HOME/Library/Caches/AVM-build/DerivedData/Build/Products/Debug/AVM.app"
MINUTES=150
KEEP=0
DISK=virtio   # the disk new machines get (2026-10-27); nvme as older ones
KEYBOARD=0
LATENCY=0
REUSE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --iso) ISO="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        --minutes) MINUTES="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --disk) DISK="$2"; shift 2 ;;
        --keyboard) KEYBOARD=1; shift ;;
        --latency) LATENCY=1; shift ;;
        --reuse) REUSE="$2"; shift 2 ;;
        -h|--help) sed -n 2,32p "$0"; exit 0 ;;
        *) echo "Unknown option $1. Run with --help."; exit 64 ;;
    esac
done

case "$DISK" in nvme) DISKDEV=nvme ;; *) DISKDEV=virtio-blk-pci ;; esac
step() { echo; echo "== $1"; }
info() { echo "   $1"; }
fail() {
    echo "FAILED: $1"
    if [ $# -ge 2 ]; then echo "Next: $2"; fi
    command -v say >/dev/null && say "The install test failed." || true
    exit 1
}

if [ -z "$ISO" ]; then
    ISO="$(ls -t "$HOME"/Downloads/*[Aa][Rr][Mm]64*.iso 2>/dev/null | sed -n 1p || true)"
fi
[ -n "$ISO" ] && [ -f "$ISO" ] || fail "No Windows 11 ARM64 ISO found." "Pass one with --iso, or download one with AVM's Download Windows 11 for ARM."
R="$APP/Contents/Resources"
[ -x "$APP/Contents/MacOS/AVM" ] && [ -x "$R/qemu-system-aarch64" ] || fail "No AVM build at $APP." "Build AVM first, or pass --app."
for f in qemu-img swtpm mtools edk2-aarch64-secure-code.fd edk2-arm-secure-vars.fd; do
    [ -e "$R/$f" ] || fail "$f is missing from $APP."
done

WORK="${REUSE:-$HOME/Library/Caches/AVM-build/install-test-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$WORK/tpm"
chmod 700 "$WORK"
QMP="$WORK/qmp.sock"
QEMU_PID=""
TPM_PID=""
RESULT=1

qmp() {
    # qmp <command> [json arguments]: one QMP command, reply on stdout.
    python3 -I - "$QMP" "$@" <<'PY'
import json, socket, sys
path, command = sys.argv[1], sys.argv[2]
arguments = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(path)
f = s.makefile("rw")
f.readline()
f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n"); f.flush(); f.readline()
request = {"execute": command}
if arguments is not None: request["arguments"] = arguments
f.write(json.dumps(request) + "\n"); f.flush()
while True:
    line = f.readline()
    if not line or "return" in line or "error" in line:
        print(line.strip()); break
PY
}

screenshot() {
    # This QEMU has no PNG support: take QEMU's PPM and write a PNG.
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

status() {
    MTOOLS_SKIP_CHECK=1 env -u DYLD_LIBRARY_PATH "$R/mtools" -c mtype -i "$WORK/autounattend.img" ::AVMSTATUS.TXT 2>/dev/null | tr -d '\r' || true
}

cleanup() {
    # A machine that's kept is shut down properly first (2026-10-26: two
    # power cuts in a row left one that Windows couldn't repair).
    if [ "$KEEP" = "1" ] || [ "$RESULT" != "0" ]; then
        if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null && [ -S "$WORK/qga.sock" ]; then
            python3 -I - "$WORK/qga.sock" <<'PY' >/dev/null 2>&1 || true
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-shutdown","arguments":{"mode":"powerdown"}}\n')
PY
            for _ in $(seq 1 24); do kill -0 "$QEMU_PID" 2>/dev/null || break; sleep 5; done
        fi
    fi
    [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2>/dev/null && { qmp quit >/dev/null 2>&1 || kill "$QEMU_PID" 2>/dev/null || true; }
    [ -n "$TPM_PID" ] && kill "$TPM_PID" 2>/dev/null || true
    if [ "$RESULT" = "0" ] && [ "$KEEP" = "0" ]; then
        rm -rf "$WORK"
    else
        echo "   The test machine is kept in $WORK"
    fi
}
trap cleanup EXIT

if [ -z "$REUSE" ]; then
step "Building install media with AVM's pipeline"
info "ISO: $ISO"
# Setup answers for an unattended run: a local account, so Windows signs
# in by itself and the first sign-in's steps (NVDA) run too.
python3 -I - "$WORK/windows-setup.json" <<'PY'
import base64, json, secrets, sys
password = secrets.token_urlsafe(12)
encoded = base64.b64encode((password + "Password").encode("utf-16-le")).decode()
json.dump({
    "locale": "en-US", "inputLocale": "0409:00000409", "computerName": "AVM-TEST",
    "timeZone": "UTC", "privacy": "mostPrivate",
    "localAccount": {"userName": "avmtest", "displayName": "AVM Test", "encodedPassword": encoded},
}, open(sys.argv[1], "w"))
PY
chmod 600 "$WORK/windows-setup.json"
"$APP/Contents/MacOS/AVM" --build-install-media --disk "$DISK" --iso "$ISO" --out "$WORK" --screen-readers nvda,jaws \
    || fail "AVM couldn't build the install media." "See the line above, and AVM's diagnostic log."
[ -f "$WORK/install-avm.iso" ] && [ -f "$WORK/autounattend.img" ] || fail "AVM said it built the media, but the files aren't there."

step "Making the test machine"
"$R/qemu-img" create -q -f qcow2 "$WORK/disk.qcow2" 64G
"$R/qemu-img" convert -O raw "$R/edk2-arm-secure-vars.fd" "$WORK/nvram.fd"
fi
rm -f "$QMP" "$WORK/qga.sock" "$WORK/spice.sock" "$WORK/tpm.sock"
"$R/swtpm" socket --tpmstate "dir=$WORK/tpm" --ctrl "type=unixio,path=$WORK/tpm.sock" --tpm2 --log level=0 &
TPM_PID=$!
sleep 1
info "64 GB disk, Secure Boot, TPM 2.0, 4 cores, 8 GB of memory"

# Sound: none, unless timing it; then as VMManager plays it (2026-10-27).
AUDIODEV="none,id=snd"
HDA="hda-duplex,audiodev=snd"
if [ "$LATENCY" = "1" ]; then
    AUDIODEV="coreaudio,id=snd,out.frequency=48000,out.buffer-length=2500,out.buffer-count=2,timer-period=1250"
    HDA="hda-duplex,audiodev=snd,use-timer=off"
fi

step "Starting Windows Setup (no window)"
"$R/qemu-system-aarch64" -L "$R" \
    -machine virt,accel=hvf -cpu host -smp 4 -m 8192M \
    -smbios "type=1,manufacturer=AVM,product=AVM Virtual Machine,serial=avm-install-test" \
    -drive "if=pflash,format=raw,file=$R/edk2-aarch64-secure-code.fd,readonly=on" \
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
    -audiodev "$AUDIODEV" -device intel-hda -device "$HDA" \
    -device virtio-serial-pci \
    -chardev spicevmc,id=vdagent,name=vdagent \
    -device virtserialport,chardev=vdagent,name=com.redhat.spice.0 \
    -chardev spiceport,id=webdav0,name=org.spice-space.webdav.0 \
    -device virtserialport,chardev=webdav0,name=org.spice-space.webdav.0 \
    -chardev "socket,id=qga0,path=$WORK/qga.sock,server=on,wait=off" \
    -device virtserialport,chardev=qga0,name=org.qemu.guest_agent.0 \
    -chardev "socket,id=char-qmp,path=$QMP,server=on,wait=off" -qmp chardev:char-qmp \
    -chardev "socket,id=chrtpm,path=$WORK/tpm.sock" -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis-device,tpmdev=tpm0 \
    -rtc base=localtime,clock=host \
    -serial "file:$WORK/firmware-serial.log" -display none -monitor none \
    > "$WORK/qemu.log" 2>&1 &
QEMU_PID=$!
for _ in $(seq 1 20); do [ -S "$QMP" ] && break; sleep 0.5; done
[ -S "$QMP" ] || fail "QEMU didn't start." "See $WORK/qemu.log."
if [ -z "$REUSE" ]; then
for _ in $(seq 1 60); do
    qmp send-key '{"keys":[{"type":"qcode","data":"ret"}]}' >/dev/null 2>&1 || true
    sleep 0.4
done
info "Pressed Enter to boot the installer."
fi

step "Waiting for Windows (checking every minute, up to $MINUTES minutes)"
START=$(date +%s)
LAST=""
while :; do
    kill -0 "$QEMU_PID" 2>/dev/null || fail "QEMU stopped during the install." "See $WORK/qemu.log."
    REPORT="$(status)"
    NOW="$(echo "$REPORT" | sed -n '$p')"
    ELAPSED=$(( ($(date +%s) - START) / 60 ))
    if [ "$NOW" != "$LAST" ]; then
        info "$ELAPSED min: ${NOW:-installing}"
        LAST="$NOW"
    fi
    echo "$REPORT" | grep -q "first-sign-in-done" && break
    # A fresh look every 10 minutes: an error dialog shows at once.
    [ $((ELAPSED % 10)) -eq 0 ] && [ "$ELAPSED" -gt 0 ] && screenshot
    if [ "$ELAPSED" -ge "$MINUTES" ]; then
        screenshot
        echo "$REPORT"
        if echo "$REPORT" | grep -q "specialize-done"; then
            fail "Windows finished setup's own steps but never reached the first sign-in." "It's probably waiting on a setup screen: see $WORK/screen.png."
        fi
        fail "Windows didn't finish setup in $MINUTES minutes." "See $WORK/screen.png and $WORK/firmware-serial.log."
    fi
    sleep 60
done

step "What setup installed"
REPORT="$(status)"
MISSING=0
for item in vdagent-installed webdavd-installed qemu-ga-installed jaws-installed nvda-staged nvda-installed nvda-starts-after-sign-in first-sign-in-done; do
    if echo "$REPORT" | grep -qx "$item"; then
        info "yes  $item"
    else
        info "NO   $item"
        MISSING=1
    fi
done
if [ -n "$REUSE" ]; then
    # A kept machine is still starting: give its agent up to 5 minutes.
    for _ in $(seq 1 60); do
        python3 -I - "$WORK/qga.sock" <<'PY' 2>/dev/null && break
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-ping"}\n'); sys.exit(0 if b"return" in s.recv(4096) else 1)
PY
        sleep 5
    done
fi
if python3 -I - "$WORK/qga.sock" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-ping"}\n')
sys.exit(0 if b"return" in s.recv(4096) else 1)
PY
then
    info "yes  the guest agent answers"
else
    info "NO   the guest agent answers"
    MISSING=1
fi

# KEYBOARD CHECK (2026-10-26): a key watcher (a low-level keyboard hook,
# in this test machine only) runs in the signed-in user's session through
# a scheduled task for the Interactive group, so no password is needed;
# AVM types through its own keyboard path; then the watcher's log is
# compared with what should have arrived. The watcher runs elevated
# (MEASURED 2026-10-26: unelevated, Windows hid from it every key that
# went to NVDA's welcome dialog, which runs with UI Access).
if [ "$KEYBOARD" = "1" ] && [ "$MISSING" = "0" ]; then
    step "Typing into Windows through AVM's keyboard path"
    QGA="$WORK/qga.sock"
    for _ in $(seq 1 60); do
        python3 -I - "$QGA" <<'PY' 2>/dev/null && break
import socket, sys
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1])
s.sendall(b'{"execute":"guest-ping"}\n'); sys.exit(0 if b"return" in s.recv(4096) else 1)
PY
        sleep 5
    done
    [ -n "$REUSE" ] && sleep 60   # the sign-in, after the agent
    cat > "$WORK/qga.py" <<'PY'
import base64, json, socket, sys, time
sock = sys.argv[1]
def call(cmd, args=None):
    s = socket.socket(socket.AF_UNIX); s.settimeout(30); s.connect(sock)
    msg = {"execute": cmd}
    if args is not None: msg["arguments"] = args
    s.sendall((json.dumps(msg) + "\n").encode())
    data = b""
    while not data.endswith(b"\n"): data += s.recv(65536)
    reply = json.loads(data)
    if "error" in reply: raise SystemExit(reply["error"].get("desc", "error"))
    return reply["return"]
def run(path, args):
    pid = call("guest-exec", {"path": path, "arg": args, "capture-output": True})["pid"]
    for _ in range(60):
        st = call("guest-exec-status", {"pid": pid})
        if st.get("exited"):
            return (base64.b64decode(st.get("out-data", "")) + base64.b64decode(st.get("err-data", ""))).decode(errors="replace")
        time.sleep(1)
    return ""
def write(path, text):
    h = call("guest-file-open", {"path": path, "mode": "wb"})
    data = text.encode("utf-16") if path.endswith(".xml") else text.encode("utf-8")   # schtasks wants UTF-16 XML
    call("guest-file-write", {"handle": h, "buf-b64": base64.b64encode(data).decode()})
    call("guest-file-close", {"handle": h})
def read(path):
    try: h = call("guest-file-open", {"path": path, "mode": "rb"})
    except SystemExit: return ""
    out = b""
    while True:
        r = call("guest-file-read", {"handle": h, "count": 65536})
        out += base64.b64decode(r.get("buf-b64", ""))
        if r.get("eof"): break
    call("guest-file-close", {"handle": h})
    return out.decode("utf-8", errors="replace")
action = sys.argv[2]
if action == "setup":
    # NVDA closed for the check (MEASURED 2026-10-26): its welcome dialog
    # runs with UI Access, and keys going to it are hidden from any key
    # watcher, elevated or not. NVDA isn't part of the key path checked.
    run("taskkill.exe", ["/im", "nvda.exe", "/f"])
    run("cmd.exe", ["/c", "mkdir C:\\avmkeys & del /q C:\\avmkeys\\keys.log C:\\avmkeys\\watcher-*.txt"])
    write("C:\\avmkeys\\hook.ps1", open(sys.argv[3]).read())
    write("C:\\avmkeys\\task.xml", open(sys.argv[4]).read())
    print(run("schtasks.exe", ["/create", "/xml", "C:\\avmkeys\\task.xml", "/tn", "AVMKeys", "/f"]))
    print(run("schtasks.exe", ["/run", "/tn", "AVMKeys"]))
elif action == "read":
    # Through type, which reads a file another program is still writing
    # (2026-10-26: the agent's own file open was refused while the watcher
    # held it, so "ready" was never seen).
    print(run("cmd.exe", ["/c", "type C:\\avmkeys\\keys.log"]))
elif action == "diagnose":
    print(run("schtasks.exe", ["/query", "/tn", "AVMKeys", "/v", "/fo", "list"]))
    print(run("cmd.exe", ["/c", "query user"]))
    # The watcher run here, as SYSTEM, only to see whether it compiles.
    print(run("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command",
              "try { $src = (Get-Content C:\\avmkeys\\hook.ps1 -Raw); $src = $src -replace '900\\)', '3)' -replace 'keys.log', 'compile-check.log'; Invoke-Expression $src; 'compiled and ran' } catch { 'ERROR: ' + $_ }"]))
    print(read("C:\\avmkeys\\compile-check.log"))
    print(run("cmd.exe", ["/c", "dir C:\\avmkeys & type C:\\avmkeys\\watcher-*.txt & icacls C:\\avmkeys"]))
PY
    cat > "$WORK/hook.ps1" <<'PS'
# AVM keyboard test only: logs which keys arrive, and the foreground app.
$diag = "C:\avmkeys\watcher-$env:USERNAME.txt"
"started as $env:USERNAME in session $([System.Diagnostics.Process]::GetCurrentProcess().SessionId)" | Out-File $diag
trap { "ERROR: $_" | Out-File $diag -Append; exit 1 }
$src = @"
using System; using System.Diagnostics; using System.IO; using System.Runtime.InteropServices; using System.Windows.Forms;
public static class AVMKeys {
  public delegate IntPtr Proc(int n, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, Proc p, IntPtr h, uint t);
  [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
  [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string n);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  static Proc keep; static StreamWriter log;
  static string Fore() { uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); try { return Process.GetProcessById((int)pid).ProcessName; } catch { return "unknown"; } }
  public static void Run(string path, int seconds) {
    // Shared for reading, so the test can read it while it's written.
    log = new StreamWriter(new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)); log.AutoFlush = true;
    keep = (n, w, l) => { if (n >= 0) { int vk = Marshal.ReadInt32(l); int flags = Marshal.ReadInt32(l, 8); log.WriteLine("key " + vk.ToString("X2") + " " + ((flags & 0x80) != 0 ? "up" : "down")); } return CallNextHookEx(IntPtr.Zero, n, w, l); };
    SetWindowsHookEx(13, keep, GetModuleHandle(null), 0);
    log.WriteLine("ready");
    var t = new Timer(); t.Interval = 400; t.Tick += (s, e) => log.WriteLine("fore " + Fore()); t.Start();
    var stop = new Timer(); stop.Interval = seconds * 1000; stop.Tick += (s, e) => Application.Exit(); stop.Start();
    Application.Run();
  }
}
"@
Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms
[AVMKeys]::Run("C:\avmkeys\keys.log", 900)
PS
    cat > "$WORK/task.xml" <<'XML'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Principals><Principal id="Author"><GroupId>S-1-5-4</GroupId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT20M</ExecutionTimeLimit><Enabled>true</Enabled></Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\avmkeys\hook.ps1</Arguments></Exec></Actions>
</Task>
XML
    python3 -I "$WORK/qga.py" "$QGA" setup "$WORK/hook.ps1" "$WORK/task.xml" | sed 's/^/   /' | grep -v '^   $' || true
    READY=0
    # MEASURED 2026-10-26: the watcher's first start in a new Windows
    # takes about three minutes (it compiles its C# on the way).
    for _ in $(seq 1 96); do
        python3 -I "$WORK/qga.py" "$QGA" read | grep -q "^ready" && { READY=1; break; }
        sleep 5
    done
    if [ "$READY" = "0" ]; then
        info "NO   the key watcher didn't start in Windows. What Windows says:"
        python3 -I "$WORK/qga.py" "$QGA" diagnose > "$WORK/diagnose.log" 2>&1 || true
        grep -v '^\s*$' "$WORK/diagnose.log" | sed 's/^/      /' | sed -n 1,60p || true
        MISSING=1
    else
        # Not in a pipe set -e can end silently (2026-10-26, code audit): an
        # AVM that couldn't connect is said as a failure.
        "$APP/Contents/MacOS/AVM" --test-keyboard --spice "$WORK/spice.sock" --qmp "$QMP" > "$WORK/typing.log" 2>&1 || true
        grep -v "^2026-" "$WORK/typing.log" | sed 's/^/   /' || true
        grep -q "^SENT" "$WORK/typing.log" || { info "NO   AVM couldn't type into Windows (see typing.log)"; MISSING=1; }
        sleep 2
        python3 -I "$WORK/qga.py" "$QGA" read > "$WORK/keys.log"
        if python3 -I - "$WORK/keys.log" <<'PY'
import sys
lines = [l.strip() for l in open(sys.argv[1]) if l.strip()]
keys = [l[4:] for l in lines if l.startswith("key ")]
ok = True
def check(name, cond):
    global ok
    print(("   yes  " if cond else "   NO   ") + name)
    ok = ok and cond
def contains(seq):
    i = 0
    for k in keys:
        if i < len(seq) and k == seq[i]: i += 1
    return i == len(seq)
check("a letter arrives, down and up", contains(["41 down", "41 up"]))
check("both Shifts go down and both come back up", contains(["A0 down", "A1 down", "A1 up", "A0 up"]))
check("Fn-Backspace arrives as Delete", contains(["2E down", "2E up"]))
check("Pause arrives", contains(["13 down", "13 up"]))
start = ("StartMenuExperienceHost", "SearchHost", "ShellExperienceHost")
# Control: Start opens after the Windows key alone.
first_win_up = next((i for i, l in enumerate(lines) if l == "key 5B up"), None)
esc = next((i for i, l in enumerate(lines) if l == "key 1B down"), None)
seen = first_win_up is not None and esc is not None and any(l.startswith("fore ") and l[5:] in start for l in lines[first_win_up:esc])
check("the Windows key alone opens Start (the control)", seen)
# The way back: Control and the Windows key down, then Start must stay shut.
back = next((i for i in range(len(lines) - 1, -1, -1) if lines[i] == "key 5B up"), None)
last_a = max((i for i, l in enumerate(lines) if l == "key 41 down"), default=None)
quiet = back is not None and last_a is not None and back > (esc or 0) and not any(
    l.startswith("fore ") and l[5:] in start for l in lines[back:last_a])
check("returning to the Mac doesn't open Start", quiet)
last = {}
for k in keys:
    code, state = k.split()
    last[code] = state
check("nothing is left down", all(state == "up" for state in last.values()))
sys.exit(0 if ok else 1)
PY
        then :; else MISSING=1; fi
    fi
fi

# LATENCY (2026-10-27): NVDA's "say the time", pressed through QMP, timed
# from the key to the first sound QEMU plays (a tap on QEMU's sound alone).
if [ "$LATENCY" = "1" ] && [ "$MISSING" = "0" ]; then
    step "Timing NVDA's speech"
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    TOOL="$HOME/Library/Caches/AVM-tools/audio-latency"
    if [ ! -x "$TOOL" ] || [ "$HERE/audio-latency/main.swift" -nt "$TOOL" ]; then
        mkdir -p "$(dirname "$TOOL")"
        xcrun swiftc -O -target arm64-apple-macos14.2 "$HERE/audio-latency/main.swift" -o "$TOOL"
    fi
    NVDA=0
    for _ in $(seq 1 60); do
        python3 -I - "$WORK/qga.sock" <<'PY' 2>/dev/null && { NVDA=1; break; }
import base64, json, socket, sys, time
def call(cmd, args=None):
    s = socket.socket(socket.AF_UNIX); s.settimeout(10); s.connect(sys.argv[1])
    m = {"execute": cmd}
    if args: m["arguments"] = args
    s.sendall((json.dumps(m) + "\n").encode()); d = b""
    while not d.endswith(b"\n"): d += s.recv(65536)
    return json.loads(d)["return"]
pid = call("guest-exec", {"path": "tasklist.exe", "arg": ["/fi", "imagename eq nvda.exe"], "capture-output": True})["pid"]
for _ in range(20):
    st = call("guest-exec-status", {"pid": pid})
    if st.get("exited"): break
    time.sleep(1)
sys.exit(0 if b"nvda.exe" in base64.b64decode(st.get("out-data", "")) else 1)
PY
        sleep 5
    done
    if [ "$NVDA" = "0" ]; then
        info "NO   NVDA isn't running, so there's nothing to time"
        MISSING=1
    else
        sleep 30   # NVDA's welcome speech, and the first sound opens the path
        "$TOOL" --qmp "$QMP" --pid "$QEMU_PID" --keys insert+f12 --label windows-nvda | sed 's/^/   /' || true
    fi
fi

ELAPSED=$(( ($(date +%s) - START) / 60 ))
if [ "$MISSING" = "0" ]; then
    RESULT=0
    echo; echo "PASSED in $ELAPSED minutes."
    command -v say >/dev/null && say "The install test passed." || true
else
    screenshot
    fail "Windows installed, but something above is missing." "See $WORK/screen.png."
fi
