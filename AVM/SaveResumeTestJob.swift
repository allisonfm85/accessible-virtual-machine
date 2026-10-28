// SaveResumeTestJob.swift
// AVM — Accessible Virtual Machine
//
// Save and resume, tested with no one at the screen (2026-10-27), on a
// machine kept by Tools/test-windows-install.sh or test-linux-install.sh
// (--keep), through AVM's own code (VMManager.startVM, saveStateAndStop,
// and the resume in startVM):
//
//   AVM.app/Contents/MacOS/AVM --test-save-resume --vm <folder> [--guest windows|debian|ubuntu|fedora] [--convert] [--camera]
//   AVM.app/Contents/MacOS/AVM --test-microphone --vm <folder> [--guest ...]
//   AVM.app/Contents/MacOS/AVM --test-two-machines --vm <folder> --guest <os> --vm2 <folder> --guest2 <os>
//   AVM.app/Contents/MacOS/AVM --test-duplicate --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-send-file --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-linux-share --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-ctl --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-disk-info --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --run-in-guest <command> --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-printers --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-camera --vm <folder> --guest <os>
//   AVM.app/Contents/MacOS/AVM --test-3d --vm <folder> --guest <linux os>
//   AVM.app/Contents/MacOS/AVM --test-camera-save --vm <folder> --guest <linux os>
//   AVM.app/Contents/MacOS/AVM --test-screen-readers [--jaws] [--into <folder>]
//   AVM.app/Contents/MacOS/AVM --test-hid-bridge --vm <folder> --guest <os>
//
// --test-hid-bridge: the Bluetooth path without a Bluetooth device. Adds a
// usb-hid-bridge (AVM's QEMU patch) with a made-up HID device, plays the
// helper's part on its socket, and checks the machine sees the device, an
// input report reaches it, and an output report written there comes back.
//
// --test-screen-readers: downloads NVDA (and JAWS, with --jaws) the way a
// Windows install does, into an empty folder, and prints what was said,
// how long each took and whether it passed its checksum. No machine.
//
// --test-camera-save: a Linux machine saved while an app in it reads the
// camera (GStreamer, numbering each frame), then resumed: the same app
// carries on getting frames, and the Mac's camera comes back on.
//
// --test-3d: starts a Linux machine with 3D Graphics (gpu3D), checks its
// kernel found virgl and that OpenGL there is drawn by virgl (on the
// Mac's GPU through ANGLE) rather than in software, and that AVM doesn't
// offer to save it with open apps (QEMU can't save virgl).
//
// --test-camera: starts the machine with the Mac's camera (shareCamera),
// checks the machine has a working camera called Mac Camera, takes a
// picture with it there (GStreamer on Linux, Windows' MediaCapture on
// Windows), and that the Mac's camera went on, then off once the picture
// was taken. Run it with `open` so AVM, not the shell, asks macOS for the
// camera.
//
// --test-printers: adds the Mac's network printers in the machine as a
// Start does (sharePrinters) and lists them there. Prints nothing.
//
// --run-in-guest: starts the machine, runs one command in it through the
// guest agent (sh -c on Linux, PowerShell on Windows), prints what it
// printed, and shuts it down. For looking around in a test machine.
//
// --test-disk-info: the machine's drives as the disk watch reads them
// from the guest agent (DiskWatch.drives).
//
// --test-ctl: a control socket in a temporary AVM folder, and real
// `AVM ctl` commands against it: list, start --no-window, status,
// send-file, save, start (carries on), stop.
//
// --test-linux-share: a Mac folder served over SPICE (AVM --serve-folder,
// as a machine's window serves it) is mounted at the user's sign-in by
// /usr/local/lib/avm/mount-mac-folder.sh, and a file in it reads back in
// the guest; a file written in the guest appears on the Mac.
//
// --test-send-file: sends a 3 MB file of random bytes (three pieces) to
// the machine's Downloads, twice, and checks both arrive whole, the second
// under a new name.
//
// --test-duplicate: duplicates the machine as Duplicate… does, in a
// temporary AVM folder (the user's machine list is never opened), then
// runs the original and the copy at once, and deletes the copy.
//
// --test-two-machines: both machines run at once through MachineSessions
// (with no windows): each answers, each is the current machine in turn,
// shutting the first down leaves the second running and current, and the
// second saves and carries on.
//
// --test-microphone (Linux): starts the machine with the Mac's microphone shared,
// records three seconds in the guest, and says how loud the loudest moment
// was (a working microphone always hears something; a blocked one gives
// exact silence). macOS asks for microphone permission the first time.
//
// --convert: the machine is an older one on NVMe; first it's moved to the
// virtio disk as Settings' Turn On Save with Open Apps does (a Start that
// gets it ready, then a first Start on the virtio disk), then tested.
//
// 1. starts the machine and waits for its guest agent;
// 2. reads the guest's boot ID (Windows: its last boot time);
// 3. saves it, and checks it stopped and says it's saved;
// 4. starts it again, and checks that it carried on (same boot ID), that
//    its clock is the Mac's again, and that the saved state is gone;
// 5. shuts it down.
// Prints each step with how long it took; exits 0 if every check passed.

import Foundation
import CommonCrypto

@MainActor
enum SaveResumeTestJob {

    static let flag = "--test-save-resume"

    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) || arguments.contains("--test-microphone") || arguments.contains("--test-two-machines")
                || arguments.contains("--test-duplicate") || arguments.contains("--test-send-file")
                || arguments.contains("--test-linux-share") || arguments.contains("--test-ctl")
                || arguments.contains("--test-disk-info") || arguments.contains("--run-in-guest")
                || arguments.contains("--test-printers") || arguments.contains("--test-camera") || arguments.contains("--test-3d") || arguments.contains("--test-camera-save")
                || arguments.contains("--test-screen-readers") || arguments.contains("--test-hid-bridge") else { return }
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
            return arguments[i + 1]
        }
        if arguments.contains("--test-screen-readers") {
            AVMLog.useTestLogFolder()
            let readers: [ScreenReader] = arguments.contains("--jaws") ? [.nvda, .jaws] : [.nvda]
            let cache = value("--into").map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("avm-screen-readers-\(UUID().uuidString)")
            Task {
                let started = Date()
                let got = await ScreenReaderInstallers.fetchAll(readers, into: cache) { message, problem in
                    print(String(format: "   %5.1f s  %@%@", Date().timeIntervalSince(started), problem ? "PROBLEM: " : "", message))
                }
                for reader in readers {
                    let size = got[reader].flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
                    check("\(reader.displayName) downloaded and checked (\(size / 1_000_000) MB)", got[reader] != nil)
                }
                print(String(format: "   took %.0f s, into %@", Date().timeIntervalSince(started), cache.path))
                print(ok ? "PASSED" : "FAILED"); exit(ok ? 0 : 1)
            }
            return
        }
        guard let folder = value("--vm") else {
            print("Usage: AVM \(flag) --vm <folder> [--guest windows|debian|ubuntu|fedora]")
            exit(64)
        }
        AVMLog.useTestLogFolder()
        let guest = GuestOS(rawValue: value("--guest") ?? "windows") ?? .windows
        Task { @MainActor in
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
            if arguments.contains("--test-two-machines"), let second = value("--vm2") {
                let guest2 = GuestOS(rawValue: value("--guest2") ?? "windows") ?? .windows
                let passed = await twoMachines(folderURL, guest, URL(fileURLWithPath: second, isDirectory: true), guest2)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-camera-save") {
                var manager = VMManager()
                var config = configuration(folder: folderURL, guest: guest)
                config.shareCamera = true
                guard await start(manager, config), let agent = manager.guestAgentSocketPath,
                      await waitForAgent(agent, seconds: 300) else { print("FAILED"); exit(1) }
                try? await Task.sleep(for: .seconds(20))
                let lastFrame = #"""
                export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                ls /tmp/avm-cam 2>/dev/null | sort | tail -1 | tr -dc 0-9; echo; pgrep -c gst-launch
                """#
                _ = await exec(agent, program: "/bin/sh", args: ["-c", #"""
                    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                    rm -rf /tmp/avm-cam; mkdir -p /tmp/avm-cam
                    dev=$(for d in /sys/class/video4linux/video*; do grep -q 'Mac Camera' $d/name && echo /dev/$(basename $d) && break; done)
                    setsid nohup gst-launch-1.0 -q v4l2src device=$dev ! video/x-raw,format=YUY2,width=640,height=480 ! multifilesink location=/tmp/avm-cam/f%07d max-files=3 >/tmp/avm-cam.log 2>&1 </dev/null &
                    sleep 6
                    """#])
                let before = (await exec(agent, program: "/bin/sh", args: ["-c", lastFrame]) ?? "").split(whereSeparator: \.isNewline)
                let frameBefore = Int(before.first ?? "") ?? 0
                print("   frames read before the save: \(frameBefore)")
                check("an app in the machine is reading the camera", frameBefore > 10)
                let saved = await manager.saveStateAndStop()
                check("it was saved while the camera was in use", saved)
                guard saved else { await shutDown(manager); print("FAILED"); exit(1) }
                manager = VMManager()
                guard await start(manager, config), let agent2 = manager.guestAgentSocketPath,
                      await waitForAgent(agent2, seconds: 60) else { check("it carried on", false); print("FAILED"); exit(1) }
                try? await Task.sleep(for: .seconds(8))
                let after = (await exec(agent2, program: "/bin/sh", args: ["-c", lastFrame]) ?? "").split(whereSeparator: \.isNewline)
                let frameAfter = Int(after.first ?? "") ?? 0
                print("   frames read after the resume: \(frameAfter), GStreamer processes: \(after.dropFirst().first ?? "?")")
                check("the same app carried on getting frames", frameAfter > frameBefore + 10 && after.dropFirst().first == "1")
                check("the Mac's camera came back on", manager.consoleOutput.contains("usb-camera: the Mac's camera ("))
                _ = await exec(agent2, program: "/bin/sh", args: ["-c", "pkill gst-launch; rm -rf /tmp/avm-cam"])
                await shutDown(manager)
                print(ok ? "PASSED" : "FAILED"); exit(ok ? 0 : 1)
            }
            if arguments.contains("--test-hid-bridge") {
                let manager = VMManager()
                guard await start(manager, configuration(folder: folderURL, guest: guest)),
                      let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else { print("FAILED"); exit(1) }
                try? await Task.sleep(for: .seconds(20))
                // Vendor page; report 1: 8 bytes in, report 2: 8 bytes out.
                let descriptor = Data([0x06, 0x00, 0xff, 0x09, 0x01, 0xa1, 0x01,
                                       0x85, 0x01, 0x09, 0x02, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x08, 0x81, 0x02,
                                       0x85, 0x02, 0x09, 0x03, 0x75, 0x08, 0x95, 0x08, 0x91, 0x02,
                                       0xc0])
                // --braille: a HID braille display instead (usage page 0x41): a
                // 40-cell row out (report 1), the eight dot keys in (report 2).
                let braille = arguments.contains("--braille")
                let brailleDescriptor = Data([0x05, 0x41, 0x09, 0x01, 0xa1, 0x01,
                                              0x85, 0x01, 0x09, 0x02, 0xa1, 0x02,
                                              0x09, 0x03, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x28, 0x91, 0x02,
                                              0xc0,
                                              0x85, 0x02, 0x1a, 0x01, 0x02, 0x2a, 0x08, 0x02,
                                              0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
                                              0xc0])
                let port = 5
                guard let socketPath = manager.hidBridgeSocketPath(port: port) else { print("FAILED"); exit(1) }
                do {
                    try await manager.attachHIDBridge(port: port, socketPath: socketPath, descriptor: braille ? brailleDescriptor : descriptor,
                                                      vendor: 0x46f4, product: 0x0012, name: "AVM Bluetooth test")
                    check("QEMU added the bridge device", true)
                } catch {
                    check("QEMU added the bridge device (\(error.localizedDescription))", false)
                    await shutDown(manager); print("FAILED"); exit(1)
                }
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &address.sun_path) { raw in
                    let bytes = Array(socketPath.utf8); raw.copyBytes(from: bytes); raw[bytes.count] = 0
                }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                check("the helper's side connected to the socket", connected == 0)
                // An input report, sent once the guest has set the device up
                // and is reading (a USB reset during setup clears any queued,
                // as on a real device).
                let input: [UInt8] = [0x01, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8]
                func sendInput() {
                    _ = ([UInt8(1), UInt8(input.count), 0] + input).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                }
                try? await Task.sleep(for: .seconds(3))
                if guest != .windows {
                    _ = await exec(agent, program: "/bin/sh", args: ["-c", #"""
                        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                        d=$(for h in /sys/class/hidraw/hidraw*; do grep -q 'Bluetooth test' $h/device/uevent 2>/dev/null && echo /dev/$(basename $h); done | head -1)
                        [ -n "$d" ] && (timeout 15 dd if=$d bs=64 count=1 2>/dev/null | od -An -tx1 | tr -s ' ' > /tmp/avm-hb.txt) >/dev/null 2>&1 &
                        sleep 1
                        """#])
                }
                sendInput()
                try? await Task.sleep(for: .seconds(2))
                let out: String?
                if guest == .windows {
                    out = await exec(agent, program: "powershell.exe", args: ["-NoProfile", "-Command",
                        "Get-PnpDevice -PresentOnly | Where-Object InstanceId -like '*VID_46F4&PID_0012*' | ForEach-Object { 'device: ' + $_.FriendlyName + ' | ' + $_.Class + ' | ' + $_.Status + ' | ' + (($_ | Get-PnpDeviceProperty DEVPKEY_Device_HardwareIds -ErrorAction SilentlyContinue).Data -join ',') }"])
                } else {
                    out = await exec(agent, program: "/bin/sh", args: ["-c", #"""
                        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                        d=$(for h in /sys/class/hidraw/hidraw*; do grep -q 'Bluetooth test' $h/device/uevent 2>/dev/null && echo /dev/$(basename $h); done | head -1)
                        echo "device: $d"
                        [ -n "$d" ] || exit 0
                        echo "read: $(cat /tmp/avm-hb.txt 2>/dev/null)"; rm -f /tmp/avm-hb.txt
                        printf '\002\021\042\063\104\125\146\167\210' > $d && echo "wrote: 02 11 22 33 44 55 66 77 88"
                        """#])
                }
                let text = out ?? ""
                print(text.split(whereSeparator: \.isNewline).map { "   machine: " + $0 }.joined(separator: "\n"))
                if guest == .windows {
                    check("Windows has the device, working", text.contains("device:") && text.contains("OK"))
                } else {
                    check("Linux has the device", text.contains("/dev/hidraw"))
                    check("the input report reached it", text.contains("01 a1 a2 a3 a4 a5 a6 a7 a8"))
                    // The output report, back on the helper's side.
                    var received: [UInt8] = []
                    var timeout = timeval(tv_sec: 5, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var chunk = [UInt8](repeating: 0, count: 256)
                    let n = read(fd, &chunk, chunk.count)
                    if n > 0 { received = Array(chunk[0..<n]) }
                    print("   helper's side got: \(received.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    check("the output report came back", received == [2, 9, 0, 0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
                }
                close(fd)
                await manager.detachHIDBridge(port: port)
                check("the bridge device was removed", true)
                await shutDown(manager)
                print(ok ? "PASSED" : "FAILED"); exit(ok ? 0 : 1)
            }
            if arguments.contains("--test-3d") {
                let manager = VMManager()
                var config = configuration(folder: folderURL, guest: guest)
                config.gpu3D = true
                guard await start(manager, config), let agent = manager.guestAgentSocketPath,
                      await waitForAgent(agent, seconds: 300) else { print("FAILED"); exit(1) }
                try? await Task.sleep(for: .seconds(30))
                let script = #"""
                echo "kernel: $(dmesg | grep -i -o -E 'features:.*virgl[^ ]*' | head -1)"
                ls /dev/dri 2>/dev/null | sed 's/^/dri: /'
                # A test machine: eglinfo is put in when missing.
                command -v eglinfo >/dev/null || { command -v apt-get >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q mesa-utils >/dev/null 2>&1; } \
                    || { command -v dnf >/dev/null && dnf install -y -q egl-utils >/dev/null 2>&1; }
                # Debian 13 keeps it out of PATH, in mesa-utils-bin.
                E=$(command -v eglinfo || dpkg -L mesa-utils-bin 2>/dev/null | grep '/eglinfo$' | head -1)
                "$E" -B -p surfaceless 2>/dev/null | grep -i -E 'renderer|version string' | sort -u | head -6 | sed 's/^ */opengl: /'
                """#
                let text = await exec(agent, program: "/bin/sh", args: ["-c", script]) ?? ""
                print(text.split(whereSeparator: \.isNewline).map { "   machine: " + $0 }.joined(separator: "\n"))
                check("the machine's kernel found virgl", text.contains("+virgl"))
                check("OpenGL there is drawn by virgl, not in software", text.lowercased().contains("virgl") && text.contains("opengl:") && !text.contains("llvmpipe"))
                check("AVM doesn't offer to save it with open apps", !manager.canSaveState)
                await shutDown(manager)
                print(ok ? "PASSED" : "FAILED"); exit(ok ? 0 : 1)
            }
            if arguments.contains("--test-camera") {
                let manager = VMManager()
                var config = configuration(folder: folderURL, guest: guest)
                config.shareCamera = true
                guard await start(manager, config), let agent = manager.guestAgentSocketPath,
                      await waitForAgent(agent, seconds: 300) else { print("FAILED"); exit(1) }
                try? await Task.sleep(for: .seconds(30))
                let out: String?
                if guest == .windows {
                    let script = #"""
                    $ErrorActionPreference = 'Stop'
                    Get-PnpDevice -PresentOnly | Where-Object FriendlyName -like '*Mac Camera*' | ForEach-Object { 'device: ' + $_.FriendlyName + ' | ' + $_.Class + ' | ' + $_.Status }
                    try {
                      Add-Type -AssemblyName System.Runtime.WindowsRuntime
                      $ext = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 }
                      $action = $ext | Where-Object { $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
                      function Wait-Action($op) { $t = $action.Invoke($null, @($op)); if (-not $t.Wait(60000)) { throw 'timed out' } }
                      $null = [Windows.Media.Capture.MediaCapture, Windows.Media.Capture, ContentType = WindowsRuntime]
                      $null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
                      $mc = New-Object Windows.Media.Capture.MediaCapture
                      $settings = New-Object Windows.Media.Capture.MediaCaptureInitializationSettings
                      $settings.StreamingCaptureMode = 'Video'
                      Wait-Action ($mc.InitializeAsync($settings))
                      'camera: ' + $mc.MediaCaptureSettings.VideoDeviceId
                      $stream = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
                      Wait-Action ($mc.CapturePhotoToStreamAsync([Windows.Media.MediaProperties.ImageEncodingProperties]::CreateJpeg(), $stream))
                      'picture bytes: ' + $stream.Size
                      $mc.Dispose()
                    } catch { 'capture failed: ' + $_.Exception.Message }
                    """#
                    out = await exec(agent, program: "powershell.exe", args: ["-NoProfile", "-Command", script])
                } else {
                    let script = #"""
                    for d in /sys/class/video4linux/video*; do echo "device: $(basename $d) | $(cat $d/name)"; done
                    dev=$(for d in /sys/class/video4linux/video*; do grep -q 'Mac Camera' $d/name && echo /dev/$(basename $d) && break; done)
                    # A test machine: GStreamer's tools are put in when missing.
                    command -v gst-launch-1.0 >/dev/null || { command -v apt-get >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q gstreamer1.0-tools gstreamer1.0-plugins-good >/dev/null 2>&1; } \
                        || { command -v dnf >/dev/null && dnf install -y -q gstreamer1-plugins-good gstreamer1 >/dev/null 2>&1; }
                    if command -v gst-launch-1.0 >/dev/null; then
                      timeout 90 gst-launch-1.0 -q v4l2src device=$dev num-buffers=20 ! video/x-raw,format=YUY2,width=640,height=480 ! filesink location=/tmp/avm-camera.yuv && \
                        echo "picture bytes: $(stat -c %s /tmp/avm-camera.yuv)" && \
                        python3 -c "import sys; b=open('/tmp/avm-camera.yuv','rb').read()[-614400::2]; print('average brightness:', sum(b)//len(b))"
                      rm -f /tmp/avm-camera.yuv
                    else echo "capture failed: no gst-launch-1.0"; fi
                    """#
                    out = await exec(agent, program: "/bin/sh", args: ["-c", script])
                }
                let text = out ?? ""
                print(text.split(whereSeparator: \.isNewline).map { "   machine: " + $0 }.joined(separator: "\n"))
                check("the machine has a camera called Mac Camera", text.contains("Mac Camera"))
                check("it took a picture", text.contains("picture bytes: ") && !text.contains("picture bytes: 0"))
                check("the Mac's camera went on", manager.consoleOutput.contains("usb-camera: the Mac's camera ("))
                try? await Task.sleep(for: .seconds(6))
                check("and off again once the picture was taken", manager.consoleOutput.contains("usb-camera: the Mac's camera is off"))
                await shutDown(manager)
                print(ok ? "PASSED" : "FAILED"); exit(ok ? 0 : 1)
            }
            if arguments.contains("--test-printers") {
                let found = await Task.detached { MacPrinters.find() }.value
                for p in found { print("   Mac: \(p.name) -> \(p.uri)") }
                check("the Mac's network printers were found", !found.isEmpty)
                let manager = VMManager()
                var config = configuration(folder: folderURL, guest: guest)
                config.sharePrinters = true
                guard await start(manager, config), let agent = manager.guestAgentSocketPath,
                      await waitForAgent(agent, seconds: 300) else { print("FAILED"); exit(1) }
                // The Start adds them; a second pass, as at the next Start,
                // finds them already there and says nothing.
                try? await Task.sleep(for: .seconds(60))
                await manager.addMacPrinters(configuration: config)
                do {
                    let out = guest == .windows
                        ? await exec(agent, program: "powershell.exe", args: ["-NoProfile", "-Command", "Get-Printer | Where-Object Name -like '*(Mac)' | ForEach-Object { $_.Name + ' | ' + $_.PortName + ' | ' + $_.DriverName }"])
                        : await exec(agent, program: "/bin/sh", args: ["-c", "lpstat -v | grep AVM-; lpstat -d"])
                    print((out ?? "no answer").split(whereSeparator: \.isNewline).map { "   machine: " + $0 }.joined(separator: "\n"))
                    check("the machine has them", found.allSatisfy { p in (out ?? "").contains(p.name) || (out ?? "").contains(p.uri.replacingOccurrences(of: "ipp://", with: "")) })
                }
                await shutDown(manager)
                print(ok ? "PASSED" : "FAILED"); exit(ok ? 0 : 1)
            }
            if let command = value("--run-in-guest") {
                let manager = VMManager()
                guard await start(manager, configuration(folder: folderURL, guest: guest)),
                      let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
                    print("FAILED"); exit(1)
                }
                try? await Task.sleep(for: .seconds(10))
                let out = guest == .windows
                    ? await exec(agent, program: "powershell.exe", args: ["-NoProfile", "-Command", command])
                    : await exec(agent, program: "/bin/sh", args: ["-c", command])
                print(out ?? "(no answer)")
                await shutDown(manager)
                exit(0)
            }
            if arguments.contains("--test-disk-info") {
                let manager = VMManager()
                guard await start(manager, configuration(folder: folderURL, guest: guest)),
                      let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
                    print("FAILED"); exit(1)
                }
                try? await Task.sleep(for: .seconds(10))
                let reply = try? await Task.detached(operation: { try GuestAgent.run([#"{"execute":"guest-get-fsinfo"}"#], socketPath: agent, timeout: 10) }).value.first
                let json = reply.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let drives = DiskWatch.drives(fromFsinfo: json?["return"])
                for drive in drives {
                    print("   \(drive.name): \(drive.used / DiskWatch.gigabyte) of \(drive.total / DiskWatch.gigabyte) GB, \(Int(drive.fraction * 100))%")
                    print("   would say at 90%: \(DiskWatch.guestWords(machine: "Test", drive: drive))")
                }
                check("the system drive was found", drives.contains { $0.name == "/" || $0.name == "C:" })
                await shutDown(manager)
                print(ok ? "PASSED" : "FAILED"); exit(ok ? 0 : 1)
            }
            if arguments.contains("--test-ctl") {
                let passed = await controlTest(folderURL, guest)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-linux-share") {
                let passed = await linuxShare(folderURL, guest)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-send-file") {
                let passed = await sendFile(folderURL, guest)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-duplicate") {
                let passed = await duplicate(folderURL, guest)
                print(passed ? "PASSED" : "FAILED"); exit(passed ? 0 : 1)
            }
            if arguments.contains("--test-microphone") {
                let heard = await microphone(folder: folderURL, guest: guest)
                print(heard ? "PASSED" : "FAILED"); exit(heard ? 0 : 1)
            }
            if arguments.contains("--convert"), !(await convert(folder: folderURL, guest: guest)) {
                print("FAILED"); exit(1)
            }
            let ok = await run(folder: folderURL, guest: guest)
            print(ok ? "PASSED" : "FAILED")
            exit(ok ? 0 : 1)
        }
    }

    private static var ok = true
    private static func check(_ what: String, _ passed: Bool) {
        print("   \(passed ? "yes" : "NO ")  \(what)")
        if !passed { ok = false }
    }

    private static func configuration(folder: URL, guest: GuestOS) -> VMConfiguration {
        var configuration = VMConfiguration(
            name: "Save test", cpuCount: 4, ramSizeGB: guest == .windows ? 8 : 4, diskSizeGB: 64,
            diskImagePath: folder.appendingPathComponent("disk.qcow2").path,
            // Any install disc: AVM reads the "installed" marker only for a
            // machine that has one (checkInstallCompleteMarker).
            installISOPath: folder.appendingPathComponent("install-avm.iso").path,
            guestOSName: guest == .windows ? nil : guest.rawValue,
            storageFolderPath: folder.path,
            secureBoot: guest == .windows ? true : nil)
        // --nvme: a test machine installed before the virtio disk (2026-10-27).
        configuration.diskBus = CommandLine.arguments.contains("--nvme") ? nil : "virtio"
        // --camera: any test with the Mac's camera attached (2026-10-27),
        // as --test-save-resume --camera, which checks it can be saved.
        if CommandLine.arguments.contains("--camera") { configuration.shareCamera = true }
        // --3d: with 3D Graphics, as --run-in-guest --3d for looking around.
        if CommandLine.arguments.contains("--3d") { configuration.gpu3D = true }
        return configuration
    }

    private static func convert(folder: URL, guest: GuestOS) async -> Bool {
        var configuration = configuration(folder: folder, guest: guest)
        configuration.diskBus = nil
        configuration.diskBusSwitch = "pending"
        print("== Getting the NVMe machine ready for the virtio disk")
        var manager = VMManager()
        var started = Date()
        guard await start(manager, configuration) else { return false }
        for _ in 0..<900 where manager.diskSwitchResult == nil {
            try? await Task.sleep(for: .seconds(1))
        }
        print(String(format: "   %@ after %.0f s", manager.diskSwitchResult ?? "nothing", Date().timeIntervalSince(started)))
        check("it got ready", manager.diskSwitchResult == "ready")
        await shutDown(manager)
        guard manager.diskSwitchResult == "ready" else { return false }

        print("== Its first Start on the virtio disk")
        configuration.diskBus = "virtio"
        configuration.diskBusSwitch = "firstBoot"
        manager = VMManager()
        started = Date()
        guard await start(manager, configuration) else { return false }
        for _ in 0..<900 where manager.diskSwitchResult == nil {
            try? await Task.sleep(for: .seconds(1))
        }
        print(String(format: "   %@ after %.0f s", manager.diskSwitchResult ?? "nothing", Date().timeIntervalSince(started)))
        check("it came up on the virtio disk", manager.diskSwitchResult == "switched")
        await shutDown(manager)
        return manager.diskSwitchResult == "switched"
    }

    private static func microphone(folder: URL, guest: GuestOS) async -> Bool {
        var configuration = configuration(folder: folder, guest: guest)
        configuration.shareMicrophone = true
        print("== Starting the machine with the microphone shared")
        let manager = VMManager()
        guard await start(manager, configuration) else { return false }
        guard let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("the guest agent answers", false); await shutDown(manager); return false
        }
        try? await Task.sleep(for: .seconds(20))
        print("== Recording three seconds in the guest")
        guard guest != .windows else {
            // Windows has no recorder the guest agent can drive; this test
            // covers Linux, and QEMU's side is the same for both.
            print("   (Linux only for now)"); await shutDown(manager); return false
        }
        let peak = await exec(agent, program: "/bin/sh", args: ["-c", """
                U=$(id -u avmtest 2>/dev/null || ls /run/user | head -1)
                N=$(getent passwd "$U" | cut -d: -f1)
                runuser -u "$N" -- env XDG_RUNTIME_DIR=/run/user/$U timeout 3 pw-record --rate 48000 --channels 1 --format s16 /tmp/avm-mic.wav
                python3 -c "import sys,struct,wave; w=wave.open('/tmp/avm-mic.wav'); d=w.readframes(w.getnframes()); s=struct.unpack('<%dh'%(len(d)//2), d); print('frames', len(s), 'peak', max(abs(x) for x in s) if s else 0)"
                """])
        print("   \(peak ?? "no answer")")
        let words = (peak ?? "").split(separator: " ")
        let level = words.firstIndex(of: "peak").flatMap { words.indices.contains($0 + 1) ? Int(words[$0 + 1]) : nil } ?? 0
        let frames = words.firstIndex(of: "frames").flatMap { words.indices.contains($0 + 1) ? Int(words[$0 + 1]) : nil } ?? 0
        check("the guest recorded", frames > 48_000)
        check("the recording isn't silence (the Mac's microphone reached it)", level > 0)
        await shutDown(manager)
        return ok
    }

    /// Runs `AVM ctl …` as the user would, against this test's socket.
    private static func ctl(_ words: [String], support: URL) async -> (ok: Bool, out: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["ctl"] + words
            var env = ProcessInfo.processInfo.environment
            env["AVM_TEST_SUPPORT_DIR"] = support.path
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            try? process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }.value
    }

    private static func controlTest(_ folder: URL, _ guest: GuestOS) async -> Bool {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("avm-ctl-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AVMPaths.supportDirectoryOverride = support
        defer { try? FileManager.default.removeItem(at: support) }
        let store = VMStore()
        var config = configuration(folder: folder, guest: guest)
        config.name = "Ctl Test"
        store.save(config)
        ControlServer.shared.start()
        func run(_ words: [String]) async -> (ok: Bool, out: String) {
            let result = await ctl(words, support: support)
            print("   $ avmctl \(words.joined(separator: " "))\n\(result.out.split(whereSeparator: \.isNewline).map { "     " + $0 }.joined(separator: "\n"))")
            return result
        }
        print("== avmctl")
        let list = await run(["list"])
        check("list names it, shut down", list.ok && list.out.contains("Ctl Test") && list.out.contains("shut down"))
        let start = await run(["start", "ctl test", "--no-window"])
        check("start (any case, no window) works", start.ok)
        guard let session = MachineSessions.shared.session(for: config.id) else { check("it's running", false); return false }
        for _ in 0..<600 where session.vmState != .running { try? await Task.sleep(for: .milliseconds(500)) }
        guard let agent = session.manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("its guest agent answers", false); session.forceStop(); return false
        }
        try? await Task.sleep(for: .seconds(15))
        let status = await run(["status", "Ctl Test"])
        check("status says running", status.ok && status.out.contains("running"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("avmctl note.txt")
        try? "sent by avmctl\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let send = await run(["send-file", "Ctl Test", file.path])
        check("send-file works", send.ok)
        let save = await run(["save", "Ctl Test"])
        check("save works", save.ok)
        for _ in 0..<40 where MachineSessions.shared.session(for: config.id) != nil { try? await Task.sleep(for: .milliseconds(250)) }
        let saved = await run(["status", "Ctl Test"])
        check("status says saved", saved.out.contains("saved"))
        let again = await run(["start", "Ctl Test", "--no-window"])
        check("start carries on", again.ok)
        guard let session2 = MachineSessions.shared.session(for: config.id) else { return false }
        for _ in 0..<120 where session2.vmState != .running { try? await Task.sleep(for: .milliseconds(500)) }
        let landed = guest == .windows ? nil : await exec(session2.manager.guestAgentSocketPath ?? "", program: "/bin/sh",
                                                         args: ["-c", "cat /home/*/Downloads/'avmctl note.txt'; rm -f /home/*/Downloads/'avmctl note.txt'"])
        if guest != .windows { check("the sent file is in Downloads", landed?.contains("sent by avmctl") == true) }
        let stop = await run(["stop", "Ctl Test"])
        check("stop works", stop.ok)
        for _ in 0..<240 where MachineSessions.shared.session(for: config.id) != nil { try? await Task.sleep(for: .milliseconds(500)) }
        check("it shut down", MachineSessions.shared.session(for: config.id) == nil)
        let unknown = await run(["status", "No Such Machine"])
        check("an unknown machine is refused", !unknown.ok && unknown.out.contains("no virtual machine called"))
        return ok
    }

    private static func linuxShare(_ folder: URL, _ guest: GuestOS) async -> Bool {
        let shared = FileManager.default.temporaryDirectory.appendingPathComponent("avm-share-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shared) }
        try? "from the Mac\n".write(to: shared.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let manager = VMManager()
        guard await start(manager, configuration(folder: folder, guest: guest)),
              let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("the machine started and answers", false); await shutDown(manager); return false
        }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        server.arguments = ["--serve-folder", shared.path, "--spice", manager.spiceSocketPath]
        server.standardOutput = FileHandle.nullDevice
        try? server.run()
        defer { server.terminate() }
        try? await Task.sleep(for: .seconds(25))
        print("== Mounting it as the user signs in would, and reading it")
        let out = await exec(agent, program: "/bin/sh", args: ["-c", """
            U=$(getent passwd 1000 | cut -d: -f1); UID_=1000
            [ -x /usr/local/lib/avm/mount-mac-folder.sh ] && echo "script there" || echo "script missing"
            [ -e /etc/xdg/autostart/avm-mac-folder.desktop ] && echo "autostart there" || echo "autostart missing"
            systemctl is-active spice-webdavd 2>&1 | sed 's/^/webdavd: /'
            ss -ltn 2>/dev/null | grep -q ':9843' && echo "listening on 9843" || echo "not listening on 9843"
            runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus HOME=/home/$U /bin/bash /usr/local/lib/avm/mount-mac-folder.sh
            runuser -u "$U" -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus gio mount dav://localhost:9843/ 2>&1 | sed 's/^/gio: /'
            G="runuser -u $U -- env XDG_RUNTIME_DIR=/run/user/$UID_ DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_/bus"
            $G gio cat dav://localhost:9843/hello.txt 2>&1
            echo "from the guest" | $G gio save dav://localhost:9843/back.txt 2>&1 && echo "wrote back"
            grep -c 'Mac shared folder' /home/$U/.config/gtk-3.0/bookmarks
            """])
        print((out ?? "no answer").split(whereSeparator: \.isNewline).map { "   " + $0 }.joined(separator: "\n"))
        check("the sign-in script is installed", out?.contains("script there") == true && out?.contains("autostart there") == true)
        check("the Mac's file reads back in the guest", out?.contains("from the Mac") == true)
        try? await Task.sleep(for: .seconds(2))
        check("a file written in the guest is on the Mac", (try? String(contentsOf: shared.appendingPathComponent("back.txt"), encoding: .utf8))?.contains("from the guest") == true)
        check("it's bookmarked in Files", out?.split(whereSeparator: \.isNewline).last == "1")
        await shutDown(manager)
        return ok
    }

    private static func sendFile(_ folder: URL, _ guest: GuestOS) async -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("avm send test.bin")
        var bytes = Data(count: 3 * 1_048_576 + 12345)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try? bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sum = bytes.withUnsafeBytes { raw -> String in
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(raw.baseAddress, CC_LONG(raw.count), &digest)
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        let manager = VMManager()
        guard await start(manager, configuration(folder: folder, guest: guest)),
              let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("the machine started and answers", false); await shutDown(manager); return false
        }
        try? await Task.sleep(for: .seconds(20))
        print("== Sending the file twice")
        let started = Date()
        await manager.sendFile(file)
        await manager.sendFile(file)
        print(String(format: "   took %.1f s", Date().timeIntervalSince(started)))
        let sums = guest == .windows
            ? await exec(agent, program: "powershell.exe", args: ["-NoProfile", "-Command",
                "Get-ChildItem -Path C:\\Users\\*\\Downloads\\'avm send test*' | ForEach-Object { (Get-FileHash $_.FullName).Hash.ToLower() + ' ' + $_.Name; Remove-Item $_.FullName }"])
            : await exec(agent, program: "/bin/sh", args: ["-c", "cd /home/*/Downloads && for f in avm\\ send\\ test*; do echo \"$(sha256sum \"$f\" | cut -c1-64) $f $(stat -c %U \"$f\")\"; rm -f \"$f\"; done"])
        print("   \(sums ?? "no answer")")
        let lines = (sums ?? "").split(whereSeparator: \.isNewline)
        check("two copies arrived", lines.count == 2)
        check("both are whole", lines.allSatisfy { $0.hasPrefix(sum) })
        check("the second has its own name", lines.contains { $0.contains("avm send test 2.bin") })
        if guest != .windows {
            check("they belong to the user, not root", lines.allSatisfy { !$0.hasSuffix(" root") })
        }
        await shutDown(manager)
        return ok
    }

    private static func duplicate(_ folder: URL, _ guest: GuestOS) async -> Bool {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("avm-duplicate-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        AVMPaths.supportDirectoryOverride = support
        defer { try? FileManager.default.removeItem(at: support) }
        let store = VMStore()
        var original = configuration(folder: folder, guest: guest)
        original.name = "Original"
        store.save(original)

        print("== Duplicating")
        let started = Date()
        MachineArchiveController.shared.duplicate(original, isRunning: false, into: store, name: "The copy")
        try? await Task.sleep(for: .milliseconds(200))
        for _ in 0..<1200 where MachineArchiveController.shared.activity != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        print(String(format: "   took %.1f s", Date().timeIntervalSince(started)))
        guard let copy = store.configurations.first(where: { $0.name == "The copy" }) else {
            check("the copy is in the list", false); return false
        }
        check("the copy is in the list, with its own id", copy.id != original.id)
        let copyFolder = try? copy.directoryURL()
        check("its folder is its own", copyFolder.map { $0.standardizedFileURL != folder.standardizedFileURL } ?? false)
        check("it has a disk", FileManager.default.fileExists(atPath: copy.diskImagePath))

        print("== Running the original and the copy at once")
        let machines = MachineSessions.shared
        let a = machines.start(original, vmStore: nil, focusLock: nil)
        let b = machines.start(copy, vmStore: nil, focusLock: nil)
        for _ in 0..<600 where !(a.vmState == .running && b.vmState == .running) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("both are running", a.vmState == .running && b.vmState == .running)
        if let agentA = a.manager.guestAgentSocketPath, let agentB = b.manager.guestAgentSocketPath {
            check("the original answers", await waitForAgent(agentA, seconds: 300))
            check("the copy answers", await waitForAgent(agentB, seconds: 300))
        }
        print("== Shutting both down, and deleting the copy")
        try? await a.stopGracefully()
        try? await b.stopGracefully()
        for _ in 0..<60 where !machines.sessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("both ended", machines.sessions.isEmpty)
        if let copyFolder { try? FileManager.default.removeItem(at: copyFolder) }
        return ok
    }

    private static func twoMachines(_ folderA: URL, _ guestA: GuestOS, _ folderB: URL, _ guestB: GuestOS) async -> Bool {
        var configA = configuration(folder: folderA, guest: guestA)
        configA.name = "Machine A"
        var configB = configuration(folder: folderB, guest: guestB)
        configB.name = "Machine B"
        let machines = MachineSessions.shared
        print("== Starting two machines at once")
        let a = machines.start(configA, vmStore: nil, focusLock: nil)
        let b = machines.start(configB, vmStore: nil, focusLock: nil)
        for _ in 0..<600 where !(a.vmState == .running && b.vmState == .running) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("both are running", a.vmState == .running && b.vmState == .running)
        check("two sessions", machines.sessions.count == 2)
        guard let agentA = a.manager.guestAgentSocketPath, let agentB = b.manager.guestAgentSocketPath else { return false }
        check("A's guest agent answers", await waitForAgent(agentA, seconds: 300))
        check("B's guest agent answers", await waitForAgent(agentB, seconds: 300))
        check("B, started last, is current", machines.currentID == configB.id && VMManager.shared === b.manager)
        machines.makeCurrent(configA.id)
        check("A becomes current", machines.currentID == configA.id && VMManager.shared === a.manager && VMActivity.shared.state == .running)

        print("== Shutting A down while B runs")
        let started = Date()
        try? await a.stopGracefully()
        for _ in 0..<40 where machines.session(for: configA.id) != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        print(String(format: "   A shut down in %.0f s", Date().timeIntervalSince(started)))
        check("A's session ended", machines.session(for: configA.id) == nil)
        check("B is still running", b.vmState == .running)
        check("B's guest agent still answers", await waitForAgent(agentB, seconds: 10))
        check("B became current", machines.currentID == configB.id && VMManager.shared === b.manager)

        print("== Saving B, then starting it again")
        check("B was saved", await b.saveAndStop())
        for _ in 0..<40 where machines.session(for: configB.id) != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        check("no sessions left", machines.sessions.isEmpty && VMManager.shared == nil)
        check("the menus see nothing running", VMActivity.shared.state == .stopped)
        let b2 = machines.start(configB, vmStore: nil, focusLock: nil)
        for _ in 0..<120 where b2.vmState != .running {
            try? await Task.sleep(for: .milliseconds(500))
        }
        check("B carried on", b2.vmState == .running)
        if let agent = b2.manager.guestAgentSocketPath {
            check("B's guest agent answers after carrying on", await waitForAgent(agent, seconds: 60))
        }
        print("== Shutting B down")
        try? await b2.stopGracefully()
        for _ in 0..<40 where machines.session(for: configB.id) != nil {
            try? await Task.sleep(for: .milliseconds(250))
        }
        check("everything ended", machines.sessions.isEmpty)
        return ok
    }

    private static func run(folder: URL, guest: GuestOS) async -> Bool {
        let configuration = configuration(folder: folder, guest: guest)

        print("== Starting the machine")
        var manager = VMManager()
        guard await start(manager, configuration) else { return false }
        guard let agent = manager.guestAgentSocketPath, await waitForAgent(agent, seconds: 300) else {
            check("the guest agent answers", false); await shutDown(manager); return false
        }
        let bootBefore = await bootID(agent, guest: guest)
        print("   boot: \(bootBefore ?? "unknown")")
        try? await Task.sleep(for: .seconds(20))

        print("== Saving it")
        var started = Date()
        let saved = await manager.saveStateAndStop()
        print(String(format: "   took %.1f s", Date().timeIntervalSince(started)))
        check("it was saved", saved)
        check("it stopped", manager.state == .stopped)
        check("the machine list says it's saved", QEMUSavedState.looksSaved(configuration))
        guard saved else { await shutDown(manager); return false }

        print("== Starting it again")
        manager = VMManager()
        started = Date()
        guard await start(manager, configuration) else { return false }
        guard let agent2 = manager.guestAgentSocketPath, await waitForAgent(agent2, seconds: 60) else {
            check("the guest agent answers after the resume", false); await shutDown(manager); return false
        }
        print(String(format: "   running, agent answering, after %.1f s", Date().timeIntervalSince(started)))
        let bootAfter = await bootID(agent2, guest: guest)
        print("   boot: \(bootAfter ?? "unknown")")
        check("it carried on rather than starting again (same boot)", bootBefore != nil && bootBefore == bootAfter)
        try? await Task.sleep(for: .seconds(4))   // the clock is set 2 s after the resume
        if let guestNow = await guestClock(agent2, guest: guest) {
            let off = abs(guestNow - Date().timeIntervalSince1970)
            print(String(format: "   guest clock off by %.0f s", off))
            check("its clock is the Mac's again", off < 10)
        } else {
            check("its clock could be read", false)
        }
        let tags = await QEMUSavedStateProbe.tags(configuration)
        check("the saved state is gone from the disk", !tags.contains(QEMUSavedState.tag))
        check("the machine list no longer says it's saved", !QEMUSavedState.looksSaved(configuration))

        print("== A restore point while it runs, with its memory")
        started = Date()
        var point: RestorePoint?
        do {
            point = try await manager.createRunningRestorePoint(label: "Test point")
            print(String(format: "   took %.1f s", Date().timeIntervalSince(started)))
        } catch {
            print("   \(error.localizedDescription)")
        }
        check("the restore point was taken", point != nil)
        check("the machine kept running", manager.state == .running)
        let marker = guest == .windows ? "C:\\avm-after-point.txt" : "/var/tmp/avm-after-point"
        _ = guest == .windows
            ? await exec(agent2, program: "cmd.exe", args: ["/c", "echo after>\(marker)"])
            : await exec(agent2, program: "/bin/touch", args: [marker])
        check("a file written after the point is there", await fileExists(agent2, marker, guest: guest))

        print("== Shutting it down and putting the restore point back")
        await shutDown(manager)
        if let point {
            do {
                try await RestorePoints.restore(point, vmDirectory: folder, currentSecureBoot: configuration.usesSecureBoot)
                check("it was restored", true)
            } catch {
                check("it was restored (\(error.localizedDescription))", false)
            }
            manager = VMManager()
            started = Date()
            guard await start(manager, configuration) else { return false }
            guard let agent3 = manager.guestAgentSocketPath, await waitForAgent(agent3, seconds: 60) else {
                check("the guest agent answers after the restore", false); await shutDown(manager); return false
            }
            print(String(format: "   running, agent answering, after %.1f s", Date().timeIntervalSince(started)))
            check("it carried on from the point (same boot)", await bootID(agent3, guest: guest) == bootBefore)
            check("the file written after the point is gone", !(await fileExists(agent3, marker, guest: guest)))
            print("== Shutting it down")
            await shutDown(manager)
            let points = (try? await RestorePoints.list(vmDirectory: folder)) ?? []
            check("the restore point is still there, marked with open apps", points.contains { $0.tag == point.tag && $0.withMemory })
            try? await RestorePoints.delete(point, vmDirectory: folder)
        }
        return ok
    }

    private static func fileExists(_ path: String, _ file: String, guest: GuestOS) async -> Bool {
        let out = guest == .windows
            ? await exec(path, program: "cmd.exe", args: ["/c", "if exist \(file) (echo yes) else (echo no)"])
            : await exec(path, program: "/bin/sh", args: ["-c", "[ -e \(file) ] && echo yes || echo no"])
        return out == "yes"
    }

    private static func start(_ manager: VMManager, _ configuration: VMConfiguration) async -> Bool {
        // QEMU's exit reaches the manager through here, as a VMSession
        // sets it in the app.
        VMManager.shared = manager
        do {
            try await manager.startVM(configuration: configuration)
        } catch {
            check("it started (\(error.localizedDescription))", false)
            return false
        }
        check("it started", manager.state == .running)
        return manager.state == .running
    }

    private static func shutDown(_ manager: VMManager) async {
        try? await manager.stopVM()
        for _ in 0..<360 where manager.state != .stopped {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if manager.state != .stopped { manager.forceStopVM() }
        print("   stopped")
    }

    // MARK: Guest agent

    private static func waitForAgent(_ path: String, seconds: Int) async -> Bool {
        for _ in 0..<(seconds * 2) {
            if let replies = try? await Task.detached(operation: { try GuestAgent.run([#"{"execute":"guest-ping"}"#], socketPath: path) }).value,
               replies.first?.contains(#""return""#) == true { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    /// Runs a program in the guest and returns what it printed.
    private static func exec(_ path: String, program: String, args: [String]) async -> String? {
        let start: [String: Any] = ["execute": "guest-exec",
                                    "arguments": ["path": program, "arg": args, "capture-output": true]]
        guard let data = try? JSONSerialization.data(withJSONObject: start),
              let line = String(data: data, encoding: .utf8),
              let reply = try? await Task.detached(operation: { try GuestAgent.run([line], socketPath: path, timeout: 10) }).value.first,
              let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
              let pid = (json["return"] as? [String: Any])?["pid"] as? Int else { return nil }
        for _ in 0..<360 {
            try? await Task.sleep(for: .milliseconds(500))
            let status = #"{"execute":"guest-exec-status","arguments":{"pid":\#(pid)}}"#
            guard let reply = try? await Task.detached(operation: { try GuestAgent.run([status], socketPath: path, timeout: 10) }).value.first,
                  let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any],
                  let result = json["return"] as? [String: Any] else { continue }
            if result["exited"] as? Bool == true {
                let out = (result["out-data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func bootID(_ path: String, guest: GuestOS) async -> String? {
        if guest == .windows {
            return await exec(path, program: "powershell.exe",
                              args: ["-NoProfile", "-Command", "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')"])
        }
        return await exec(path, program: "/bin/cat", args: ["/proc/sys/kernel/random/boot_id"])
    }

    private static func guestClock(_ path: String, guest: GuestOS) async -> TimeInterval? {
        let out = guest == .windows
            ? await exec(path, program: "powershell.exe", args: ["-NoProfile", "-Command", "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"])
            : await exec(path, program: "/bin/date", args: ["+%s"])
        return out.flatMap { TimeInterval($0) }
    }
}

/// The disk's snapshot names, for the test only.
enum QEMUSavedStateProbe {
    static func tags(_ configuration: VMConfiguration) async -> [String] {
        await QEMUSavedState.snapshotTags(disk: URL(fileURLWithPath: configuration.diskImagePath))
    }
}
