#!/usr/bin/env python3
# test-sound-ear.py
# AVM — Accessible Virtual Machine
#
# One ear (2026-11-01, qemu-10.0.12-utm+hda-per-ear-levels.patch): a Linux test
# machine, with QEMU alone and changes thrown away (-snapshot), plays a tone with
# its sound going to a file: in both ears, then only the left, then only the
# right, changed by qom-set while it runs, as Settings does. The file then shows
# which ear each tone reached. QEMU alone because within AVM the file stayed
# silent for reasons not found (2026-11-01), though the machine played.
#
#   test-sound-ear.py --app AVM.app --vm FOLDER
import argparse, base64, json, os, shutil, socket, struct, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--app", required=True)
ap.add_argument("--vm", required=True)
opts = ap.parse_args()
res = os.path.join(opts.app, "Contents/Resources")
run_dir = tempfile.mkdtemp(prefix="avm-ear", dir="/tmp")
wav = os.path.join(run_dir, "sound.wav")
args = [f"{res}/qemu-system-aarch64", "-L", res, "-machine", "virt", "-accel", "hvf", "-cpu", "host", "-smp", "4", "-m", "4096M", "-snapshot",
        "-drive", f"if=pflash,format=raw,file={res}/edk2-aarch64-code.fd,readonly=on",
        "-drive", f"if=pflash,format=raw,file={opts.vm}/nvram.fd",
        "-device", "qemu-xhci,id=usb,p2=8,p3=8", "-device", "usb-kbd,bus=usb.0,port=1", "-device", "usb-tablet,bus=usb.0,port=2",
        "-drive", f"if=none,id=disk0,file={opts.vm}/disk.qcow2,format=qcow2", "-device", "virtio-blk-pci,drive=disk0,serial=avmdisk0,bootindex=1",
        "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0",
        "-spice", f"unix=on,addr={run_dir}/spice.sock,disable-ticketing=on,agent-mouse=on,gl=off",
        "-device", "virtio-serial-pci", "-chardev", "spicevmc,id=vdagent,name=vdagent", "-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0",
        "-chardev", f"socket,id=qga0,path={run_dir}/qga.sock,server=on,wait=off", "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0",
        "-chardev", f"socket,id=qmp,path={run_dir}/qmp.sock,server=on,wait=off", "-qmp", "chardev:qmp", "-rtc", "base=utc,clock=host",
        "-display", "none", "-monitor", "none", "-device", "ramfb", "-device", "virtio-gpu-pci,id=gpu0",
        "-audiodev", f"wav,id=snd,path={wav},out.frequency=48000,out.channels=2", "-device", "intel-hda", "-device", "hda-duplex,id=avmhda,audiodev=snd,use-timer=off"]
qemu = subprocess.Popen(args, stderr=subprocess.DEVNULL)
failed = False
def check(what, passed):
    global failed
    print(f"   {'yes' if passed else 'NO '}  {what}", flush=True)
    failed = failed or not passed
def finish():
    qemu.terminate()
    try: qemu.wait(20)
    except subprocess.TimeoutExpired: qemu.kill()
    shutil.rmtree(run_dir, ignore_errors=True)
    print("FAILED" if failed else "PASSED", flush=True)
    sys.exit(1 if failed else 0)

for _ in range(100):
    try:
        qmp = socket.socket(socket.AF_UNIX); qmp.connect(f"{run_dir}/qmp.sock"); break
    except OSError: time.sleep(.1)
qf = qmp.makefile("rw"); qf.readline()
def command(name, **arguments):
    qf.write(json.dumps({"execute": name, "arguments": arguments} if arguments else {"execute": name}) + "\n"); qf.flush()
    while True:
        reply = json.loads(qf.readline())
        if "event" not in reply: return reply
command("qmp_capabilities")
def agent(cmd, arguments=None, timeout=10):
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout)
    try:
        s.connect(f"{run_dir}/qga.sock"); f = s.makefile("rw")
        f.write(json.dumps({"execute": "guest-sync", "arguments": {"id": 4242}}) + "\n"); f.flush()
        while json.loads(f.readline()).get("return") != 4242: pass
        f.write(json.dumps({"execute": cmd, "arguments": arguments or {}}) + "\n"); f.flush()
        return json.loads(f.readline()).get("return")
    except Exception: return None
    finally: s.close()
def shell(script):
    started = agent("guest-exec", {"path": "/bin/sh", "arg": ["-c", script], "capture-output": True})
    if not started: return None
    for _ in range(120):
        status = agent("guest-exec-status", {"pid": started["pid"]})
        if status and status.get("exited"): return base64.b64decode(status.get("out-data", "")).decode(errors="replace")
        time.sleep(1)
    return None

for _ in range(300):
    if agent("guest-ping") is not None: break
    time.sleep(1)
else:
    check("the machine answers", False); finish()
time.sleep(45)   # the session's sound server, and Orca's first words
PLAY = """export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
U=$(getent passwd 1000 | cut -d: -f1)
command -v speaker-test >/dev/null || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q alsa-utils >/dev/null 2>&1 || dnf install -y -q alsa-utils >/dev/null 2>&1; }
runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/1000 timeout 12 speaker-test -t sine -f 440 -c 2 -l 1 >/dev/null 2>&1; echo played"""
marks = [os.path.getsize(wav)]
for name, left, right in (("both ears", 100, 100), ("the left ear", 100, 0), ("the right ear", 0, 100)):
    print(f"== A tone in {name}", flush=True)
    path = "/machine/peripheral/avmhda"
    command("qom-set", path=path, property="avm-left", value=left)
    command("qom-set", path=path, property="avm-right", value=right)
    shell(PLAY)
    time.sleep(1)
    marks.append(os.path.getsize(wav))
command("quit")
try: qemu.wait(20)
except subprocess.TimeoutExpired: pass
data = open(wav, "rb").read()
def peaks(start, end):
    start = 44 + (max(start, 44) - 44) // 4 * 4
    left = right = 0
    for at in range(start, min(end, len(data)) - 3, 4 * 3):
        l, r = struct.unpack_from("<hh", data, at)
        left, right = max(left, abs(l)), max(right, abs(r))
    return left, right
both, lonly, ronly = (peaks(marks[i], marks[i + 1]) for i in range(3))
print(f"   loudest samples: both {both}, left {lonly}, right {ronly}", flush=True)
check("with both ears, the tone is in both", both[0] > 500 and both[1] > 500)
check("with the left ear, it's only in the left", lonly[0] > 500 and lonly[1] == 0)
check("with the right ear, it's only in the right", ronly[1] > 500 and ronly[0] == 0)
finish()
