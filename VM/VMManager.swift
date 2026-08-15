// VMManager.swift
// AVM — Accessible Virtual Machine
// Launches QEMU as a child process (Process) and controls it via QMP.
// Optionally launches swtpm before QEMU to provide TPM 2.0 emulation for Windows 11.
// SPICE display is exposed on a Unix socket for CocoaSpice to connect to.
//
// BOOT + DISPLAY STATUS (confirmed working end-to-end IN THE APP):
// Windows 11 ARM64 Setup boots from the install ISO AND renders its graphical
// installer to the framebuffer (screendump shows the real Setup UI). The fixes:
//   - usb-kbd device present  (REQUIRED for the firmware "Press any key" prompt)
//   - boot keypress task      (sends Enter across the prompt window; needs usb-kbd)
//   - nvme install disk        (target disk; bootindex=1)
//   - INSTALL MEDIA = usb-storage,removable=on (NOT scsi-cd): WinPE in this 25H2
//       ISO has no in-box virtio-scsi driver, so a scsi-cd install medium made
//       Setup stop at "Install driver to show hardware — a media driver is
//       missing". Attaching the ISO as removable usb-storage (which WinPE always
//       has a driver for) makes Setup proceed normally. Removable media is ALSO
//       where Setup scans for autounattend.xml. bootindex=0.
//   - DISPLAY: ramfb + virtio-gpu-pci TOGETHER, ramfb FIRST, in ALL phases.
//     The run-phase single-head experiments of 2026-08-02 (runs 9 and 10)
//     BOTH FALSIFIED — the pair is the only configuration that boots AND
//     draws. The stochastic black-window bug (runs 5/7) was a HOST-SIDE
//     wrong-head binding; the fix shipped in VMView's display binding
//     (Handoffs 25–27) and is proven across thirteen runs. Full evidence
//     trail in the display block of buildQEMUArguments. DO NOT re-run the
//     single-head experiments.
//   - serialized QMP access    (keypress task + screendump were desyncing the socket)
//   - NVRAM from edk2-arm-vars.fd padded to 64MB (the code .fd is firmware, not vars)
//   - machine `virt` (no highmem), cpu `host`  (match UTM)
//   - UNIQUE HARDWARE IDENTITY per VM (-uuid + -smbios serial): REQUIRED — see
//     the identity block in buildQEMUArguments for the Autopilot story.
//   - firmware/ROM (edk2-aarch64-code.fd, edk2-arm-vars.fd, vgabios-ramfb.bin) now
//     staged from the sysroot by the Run Script, so a CLEAN build no longer wipes them.
//
// MOUSE MODE INVESTIGATION (issue #4 — mechanism narrowed 2026-08-09 by three
// controlled QMP readings on the diagnostic socket; DO NOT relitigate):
//   READING 1 (pair, ramfb-first, connected client): absolute tablet
//     registered AND current per query-mice; TWO SPICE display channels;
//     mouse-mode SERVER.
//   READING 2 (single head, ramfb removed, connected client): same tablet
//     status; ONE display channel; mouse-mode CLIENT. The two-display
//     mechanism (QEMU #723 family) is EXPERIMENT-CONFIRMED.
//   READING 3 (pair, ORDER SWAPPED — gpu0 first, connected client): TWO
//     display channels; mouse-mode SERVER. The console-0/order theory is
//     FALSIFIED — declaration order does not matter. Screendump also came
//     back placeholder-sized (921615), so the swapped order may additionally
//     disturb which head firmware draws through; the swap is disqualified.
//   LEADING THEORY (fits all three, untested directly): SPICE grants
//     client-mode mouse without a guest agent only for a SINGLE display
//     channel; with multiple displays it requires the vdagent in the guest —
//     and AVM historically launched with agent-mouse=off and bundles no
//     Windows SPICE agent. DECISION OF RECORD (2026-08-10): fix path A —
//     ship the SPICE guest agent — prototype-first. agent-mouse is now ON
//     (expected inert with no agent connected; control run to verify). Path B
//     (hide the second head from SPICE's channel count) was researched and
//     found to have no supported QEMU mechanism. Falsified and closed:
//     timing/retry, USB suspend, display=gpu0 binding alone, tablet handler
//     activation, declaration order.
//   The display=gpu0 / id=gpu0 tokens are KEPT (launch-proven, harmless,
//   possibly necessary-but-insufficient for whichever fix path ships).
//
// INSTALL MEDIA PIPELINE (wired in — the unattended-install integration):
//   When a configuration has an installISOPath and the VM runtime dir does NOT
//   yet contain the AVM-built media (install-avm.iso + autounattend.img),
//   startVM runs WindowsInstallPipeline FIRST — the six-stage build that
//   produces a modified bootable ISO (winpeshl.ini /legacy ConX bypass +
//   $WinPEDriver$ virtio drivers) and the FAT answer image. The pipeline's
//   output is BOOT-PROVEN (blank disk → silent install → OOBE with the
//   accessibility button). Progress is published via installProgress (spoken
//   text for VoiceOver) and mirrored to the console. Artifacts are REUSED on
//   subsequent starts (the build is ~12s on a fast machine, multi-minute on
//   slower ones). After a fresh media build, any stale nvram.fd is removed so
//   the first boot gets fresh NVRAM (stale boot order falls to the UEFI shell).
//   At launch, the AVM-BUILT ISO attaches as removable usb-storage bootindex=0
//   (NOT the user's original ISO — ConX would ignore the answer file), and the
//   answer image attaches as removable usb-storage (Setup scans removable media
//   for autounattend.xml; it was previously nvme, which Setup never scanned).
//   EDITION RESOLUTION (2026-08-09, issue #6): the pipeline resolves the
//   effective edition ONCE before validation and HARD-STOPS with a spoken
//   error when the defaulted edition is absent from the disc (the IoT
//   Enterprise LTSC silent-hang fix) — see WindowsInstallPipeline.swift.
//
//   ANNOUNCEMENTS (2026-07-12): pipeline failure, pipeline completion, and
//   unexpected QEMU death fire Announcer.shared.announce — sound + system
//   voice, unconditional, frontmost or not. Motivated by the wrong-ISO
//   incident: the validation gate failed in <1s with the right message, but
//   nothing ANNOUNCED it, and half an hour passed before the debug log was
//   read. The announcement is the non-visual glance.
//
//   INSTALL WATCHDOG (2026-07-12; DISK-ACTIVITY AMENDMENT 2026-07-19): while
//   an install is in flight (install media attached, marker not yet written),
//   a background task samples every 20s: the guest framebuffer (QMP
//   screendump to watchdog-screen.ppm — its own file, separate from
//   captureScreendump()'s guest-screen.ppm), QEMU's vCPU% (ps), AND the
//   qcow2 disk's mtime + size (FileManager). NINE consecutive samples (~3
//   minutes) of identical frame + CPU >= 90% + FLAT DISK is the wedge
//   signature: the stochastic firmware hang at the mid-install reboot (edk2
//   splash frozen, one core pegged at ~100%, serial console silent after
//   re-init, no marker; evidence in ~/Desktop/avm-evidence-firmwedge). The
//   disk probe was added after Handoff 14 §2 proved the frame+CPU signature
//   ALONE also matches a HEALTHY Windows repair/update pass (~1 hour of black
//   frozen screen and pegged CPU after a reset — discriminated only by the
//   qcow2's mtime moving and its eventual 1.7 GB growth; a reset at that
//   moment would likely have bricked the guest into WinRE). A true firmware
//   wedge spins pre-BDS and can never generate guest disk I/O, so ANY
//   mtime/size movement resets the streak; a wedge-looking sample with an
//   ACTIVE disk logs "likely repair/update, waiting" and stays deliberately
//   SILENT. On detection the watchdog announces recovery guidance: reset
//   first (Cmd-Shift-R / resetVM — the in-process un-wedge experiment;
//   whether system_reset clears the wedge is UNPROVEN, the next wild
//   occurrence tests it), then stop + restart as the PROVEN fallback (the
//   reinstall guard correctly allows a reinstall because the marker is absent
//   and the disk holds nothing worth protecting), once per run. The marker
//   appearing stands the watchdog down AND speaks the SETUP-UNDERWAY
//   MILESTONE (2026-07-24): the one mid-install moment we reliably detect,
//   announced as a .success so a fresh install is not silence-as-success.
//   Wording is forward-looking by design — it names what is happening,
//   pre-explains the reboots, and states that Windows will NOT speak on its
//   own (the user turns Narrator on with Ctrl-Cmd-Return), so the milestone
//   cannot be mistaken for completion and the completion signal is never
//   promised to be automatic (it isn't — the OOBE startup sound is
//   unreliable; docs cover it).
//   FAIL-SAFE: a false positive costs only a
//   restarted install; the threshold is conservative because normal install
//   phases either animate the screen, idle the CPU, or write the disk, while
//   the observed wedge held its full signature for 30+ minutes.
//
//   REINSTALL GUARD (IMPLEMENTED 2026-07-11 — closes the disk-wipe hazard):
//   the answer file's specialize pass writes AVMDONE.TAG to the writable
//   UNATTEND volume (autounattend.img) the moment Windows is on the disk (the
//   specialize pass only runs after the image is applied; guest-proven through
//   the app on a fresh install). At EVERY start, checkInstallCompleteMarker()
//   reads the image with bundled mdir (MTOOLS_SKIP_CHECK=1; DYLD_LIBRARY_PATH
//   deliberately stripped — it poisons mtools); if the marker is present,
//   startVM skips the media build, does NOT attach install-avm.iso, and does
//   NOT start the boot keypress task — so a fresh AVM start after a completed
//   install boots the installed disk instead of re-entering Setup and letting
//   the answer file WIPE it (which happened in anger on 2026-07-11 before this
//   guard existed). Mid-session guest reboots were already safe — the keypress
//   window is long closed, so the prompt times out and the installed disk
//   boots; proven by serial log. The check costs milliseconds and runs every
//   start, so nulling installISOPath in configurations.json is no longer
//   REQUIRED for safety (still harmless). The autounattend image itself stays
//   attached always — it is the marker's home and the guest→host file courier.
//
//   FIELD NOTE from the first true end-to-end run (2026-07-08): install reached
//   OOBE with Narrator working, but NetKVM did NOT bind during the first OOBE
//   session (network screen demanded a driver; manual install from the media
//   said "no driver found") — then bound successfully after a restart
//   ("installing updates" pass, network alive at the next screen). RESOLVED
//   (2026-07-11): root cause was $WinPEDriver$ being stored mangled
//   (_WINPEDRIVER_) in the plain ISO 9660 namespace of the Stage 5 rebuild;
//   fixed by adding Joliet (-J -joliet-long) to the rebuild — guest-proven
//   (fresh install passed OOBE networking with no driver prompt).
//
// DISPLAY BINDING (RESOLVED — chapter closed 2026-08-03): the deterministic
// display binding (bind VMView to the LIVE head, never the uninitialized
// ramfb impostor) SHIPPED in VMView and is proven across thirteen runs
// (Handoffs 25–27). The rendered framebuffer flows through CocoaSpice into
// VMView's MTKView with the CSMetalRenderer as the direct delegate.
//
// DIAGNOSTIC QMP SOCKET (PERMANENT — added 2026-08-09, issue #4): a SECOND
// QMP monitor socket (qmp2.sock) alongside the app's own. The app NEVER
// connects to it; it exists so Terminal-side diagnostics (nc/socat) can ask
// QEMU direct questions — query-mice, query-spice, screendump, and anything
// future support needs — against a LIVE VM without touching the app's
// serialized QMP socket (poking that one desyncs the protocol; proven
// failure class). It was decisive in the mouse-mode investigation the day it
// was added. Same precedent as the firmware serial log. Security posture
// unchanged: it lives in the VM's own /tmp socket dir next to the main QMP
// socket, which is equally unauthenticated.
//
// STAGE C (2026-08-03, this pass): logging overhaul. Removed the unsanitized
// ~/Desktop/qemu_stderr.log write (stderr lives in the sanitized diagnostic
// log); removed the DEBUG screendump timer (captureScreendump retained as an
// on-demand diagnostic); firmware serial log reclassified PERMANENT. Every
// decision keyed to user trust: no unsanitized files, no Desktop writes, no
// surprise clutter.

import Foundation
import Combine

// MARK: - Runtime State

enum VMRuntimeState: Equatable {
    case stopped
    case starting
    case running
    case paused
    case stopping
    case error(String)
}

// MARK: - QMP Response Types

private struct QMPGreeting: Decodable {
    struct QMP: Decodable {
        struct Version: Decodable {
            struct QEMU: Decodable {
                let major: Int
                let minor: Int
                let micro: Int
            }
            let qemu: QEMU
        }
        let version: Version
    }
    let QMP: QMP
}

private struct QMPReturn: Decodable {
    let returnValue: AnyCodable
    enum CodingKeys: String, CodingKey {
        case returnValue = "return"
    }
}

private struct QMPError: Decodable {
    struct ErrorDetail: Decodable {
        let `class`: String
        let desc: String
    }
    let error: ErrorDetail
}

private struct QMPEvent: Decodable {
    let event: String
    let timestamp: QMPTimestamp?
    struct QMPTimestamp: Decodable {
        let seconds: Int
        let microseconds: Int
    }
}

private struct AnyCodable: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodableLeaf].self) {
            value = dict
        } else if let arr = try? container.decode([AnyCodableLeaf].self) {
            value = arr
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = ()
        }
    }
}

private struct AnyCodableLeaf: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let b = try? c.decode(Bool.self) { value = b }
        else { value = () }
    }
}

// MARK: - Diagnostic Logging

/// Forwards to AVMLog, the single file logger (see AVMLog.swift).
///
/// CHANGED 2026-07-26: this function previously owned its own copy of the
/// open/seek/write/close code and its own path constant pointing at
/// ~/Desktop/avm_debug.log. WindowsInstallPipeline had a byte-identical second
/// copy writing to the SAME file, which during a VM create meant two writers
/// racing on the end-of-file offset from two different actors. That, plus UTC
/// timestamps, a file that was never truncated, and silent write failures, is
/// why AVMLog exists. The name and signature are unchanged so no call site in
/// this file moves.
///
/// PRIVACY: every line passes through AVMLog's sanitizer, which replaces the
/// Mac user's name with `~`. That matters especially here — this file logs the
/// full QEMU argument list, the runtime directory, the disk path, socket
/// paths, bundled-binary paths, AND QEMU's own stderr, all of which carry the
/// user's home path. Sanitizing at the call sites would have meant getting all
/// of those right individually and forever; the choke point gets them for free.
///
/// The OLD ~/Desktop/avm_debug.log is deliberately left in place, not deleted.
/// It is the user's file and it holds history; nothing writes to it any more.
private func avmLog(_ msg: String) {
    AVMLog.write(msg)
}

// MARK: - VMManager

@MainActor
final class VMManager: ObservableObject {

    // MARK: Published State

    @Published private(set) var state: VMRuntimeState = .stopped
    @Published private(set) var qemuVersion: String = ""
    @Published private(set) var consoleOutput: String = ""

    /// Install-media pipeline progress: the SPOKEN form of the current stage
    /// ("Extracting the Windows installer. Step 1 of 6."), published so the UI
    /// can show it and announce it via VoiceOver. Empty when no build is running.
    /// (Also mirrored to the console in visible form.)
    @Published private(set) var installProgress: String = ""

    // MARK: Public read-only properties

    private(set) var spiceSocketPath: String = ""

    /// Called when the install-media pipeline's validation gate returns a
    /// WARNING (e.g. the requested edition isn't on the ISO). Return true to
    /// proceed, false to abort the VM start. The UI can set this to present a
    /// VoiceOver alert. If unset, AVM notes the warning in the console and
    /// proceeds (matching the pipeline's own headless default).
    var installWarningHandler: ((String) async -> Bool)?

    // MARK: Private — swtpm process

    private var swtpmProcess: Process?

    // MARK: Private — QEMU process

    private var qemuProcess: Process?
    private var qemuStdErrPipe: Pipe?

    // MARK: Private — QMP

    private var qmpSocket: FileHandle?
    private var qmpConnected = false
    private var qmpReadSource: DispatchSourceRead?

    // Serializes QMP command/response pairs. The QMP socket carries one
    // request→response exchange at a time; if two callers (e.g. the boot keypress
    // task and a screendump) interleave sendQMPCommand, their responses
    // get mismatched and the protocol desyncs (commands then fail/hang). This
    // flag + waiter queue ensures only one sendQMPCommand runs at once.
    private var qmpBusy = false
    private var qmpWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Private — working directory

    private var vmRuntimeDir: URL?
    private var vmSocketDir: URL?

    // Boot keypress: an async Task (NOT a Timer) that sends Enter repeatedly
    // across the early boot window to satisfy Windows' "Press any key to boot
    // from CD or DVD..." prompt. REQUIRED (see startBootKeypressTask). A Timer was
    // torn down by the SwiftUI auto-lock view transition ~3s in; a Task is
    // view-independent and survives.
    private var bootKeypressTask: Task<Void, Never>?

    // INSTALL WATCHDOG (permanent feature — see header): detects the wedge
    // signature (frozen frame + pegged vCPU + FLAT DISK + no marker) during an
    // install and announces recovery guidance. View-independent Task, same
    // pattern as the boot keypress task.
    private var installWatchdogTask: Task<Void, Never>?

    // MARK: Private — configuration reference

    private var activeConfiguration: VMConfiguration?

    // MARK: - Binary Discovery

    private func bundledBinaryURL(named name: String) -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else {
            avmLog("bundledBinaryURL: no resourcePath")
            return nil
        }
        let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            avmLog("bundledBinaryURL: \(name) not found at \(url.path)")
            return nil
        }
        let needsExecutable = !name.hasSuffix(".fd") && !name.hasSuffix(".rom") && !name.hasSuffix(".dylib") && !name.hasSuffix(".bin")
        if needsExecutable {
            var isExec = false
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let perms = attrs[.posixPermissions] as? Int {
                isExec = (perms & 0o111) != 0
            }
            if !isExec {
                avmLog("bundledBinaryURL: \(name) not executable")
                return nil
            }
        }
        avmLog("bundledBinaryURL: found \(name) at \(url.path)")
        return url
    }

    private var swtpmBinaryURL: URL? {
        bundledBinaryURL(named: "swtpm")
    }

    private var qemuBinaryURL: URL? {
        bundledBinaryURL(named: "qemu-system-aarch64")
    }

    // MARK: - Orphan Reaper (QEMU)

    /// Kills any QEMU process orphaned from a prior run that is still holding
    /// THIS VM's disk image or sockets, so a stale process (e.g. after an Xcode
    /// SIGKILL or an AVM crash, where deinit/terminate never ran) cannot block a
    /// fresh launch with a "Failed to get write lock" / QMP timeout.
    ///
    /// Scoped strictly to this VM's UUID — every orphan's argv contains the UUID
    /// via its disk path and socket paths — so starting one VM never kills an
    /// unrelated VM that happens to be running.
    private func reapOrphanedQEMU(for vmID: UUID) {
        let uuid = vmID.uuidString

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "qemu-system-aarch64.*\(uuid)"]
        let outPipe = Pipe()
        pgrep.standardOutput = outPipe
        pgrep.standardError = FileHandle.nullDevice

        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            avmLog("reapOrphanedQEMU: pgrep failed to run: \(error)")
            return
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return }
        let pids = text
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int32($0) }
            .filter { $0 > 0 && $0 != ProcessInfo.processInfo.processIdentifier }

        guard !pids.isEmpty else {
            avmLog("reapOrphanedQEMU: no orphaned QEMU found for \(uuid)")
            return
        }

        for pid in pids {
            avmLog("reapOrphanedQEMU: killing orphaned QEMU pid \(pid) for \(uuid)")
            appendConsole("AVM: Found orphaned QEMU (pid \(pid)) from a previous run — terminating it.\n")
            kill(pid, SIGKILL)
        }

        usleep(500_000)
    }

    // MARK: - Orphan Reaper (swtpm)

    /// Kills any swtpm process orphaned from a prior run that is still bound to
    /// THIS VM's TPM control socket and holding the TPM-state lock.
    private func reapOrphanedSwtpm(for vmID: UUID) {
        let uuid = vmID.uuidString

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "swtpm.*\(uuid)"]
        let outPipe = Pipe()
        pgrep.standardOutput = outPipe
        pgrep.standardError = FileHandle.nullDevice

        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            avmLog("reapOrphanedSwtpm: pgrep failed to run: \(error)")
            return
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return }
        let pids = text
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { Int32($0) }
            .filter { $0 > 0 && $0 != ProcessInfo.processInfo.processIdentifier }

        if pids.isEmpty {
            avmLog("reapOrphanedSwtpm: no orphaned swtpm found for \(uuid)")
        } else {
            for pid in pids {
                avmLog("reapOrphanedSwtpm: killing orphaned swtpm pid \(pid) for \(uuid)")
                appendConsole("AVM: Found orphaned swtpm (pid \(pid)) from a previous run — terminating it.\n")
                kill(pid, SIGKILL)
            }
            usleep(300_000)
        }

        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let lockPath = appSupport
                .appendingPathComponent("AVM")
                .appendingPathComponent("vms")
                .appendingPathComponent(uuid)
                .appendingPathComponent("tpm-state")
                .appendingPathComponent(".lock")
            if FileManager.default.fileExists(atPath: lockPath.path) {
                try? FileManager.default.removeItem(at: lockPath)
                avmLog("reapOrphanedSwtpm: removed stale TPM-state lock at \(lockPath.path)")
            }
        }
    }

    // MARK: - Directory Setup

    private func prepareRuntimeDirectory(for vmID: UUID) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("AVM")
            .appendingPathComponent("vms")
            .appendingPathComponent(vmID.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        avmLog("prepareRuntimeDirectory: \(dir.path)")
        return dir
    }

    // MARK: - Install Media Pipeline

    /// REINSTALL GUARD: returns true if the answer file's specialize pass has
    /// written the install-complete marker (AVMDONE.TAG) to the UNATTEND volume
    /// (autounattend.img), which definitionally means Windows is installed on
    /// this VM's disk — the specialize pass only runs after the OS image is
    /// applied. Guest-proven end to end (marker landed on a fresh in-app
    /// install; verified with mdir on the host).
    ///
    /// Reads the FAT image with the bundled mdir symlink (mtools dispatches by
    /// argv[0], so the symlink must be invoked directly). MTOOLS_SKIP_CHECK=1
    /// suppresses the geometry warning; DYLD_LIBRARY_PATH is deliberately
    /// STRIPPED — it poisons mtools with wrong dylib versions (proven).
    ///
    /// Fail-open design: any inability to check (no installISOPath, no image
    /// yet — the normal fresh-VM case — mdir missing, mdir failing) returns
    /// false, meaning the normal install path proceeds. The marker can only
    /// exist if a prior install reached specialize, and a pipeline-built FAT
    /// image that mdir cannot read has never been observed; failures are logged
    /// loudly so an unexpected one is visible.
    ///
    /// Also used by the INSTALL WATCHDOG as its stand-down signal (marker
    /// appearing mid-run means the danger zone is past).
    private func checkInstallCompleteMarker(configuration: VMConfiguration, runtimeDir: URL) -> Bool {
        // No install ISO configured -> this VM never had the hazard; nothing to check.
        guard let iso = configuration.installISOPath, !iso.isEmpty else { return false }

        let imgPath = runtimeDir.appendingPathComponent("autounattend.img").path
        guard FileManager.default.fileExists(atPath: imgPath) else {
            avmLog("checkInstallCompleteMarker: no autounattend.img yet — fresh VM, normal install path")
            return false
        }

        guard let mdirURL = bundledBinaryURL(named: "mdir") else {
            avmLog("checkInstallCompleteMarker: WARNING — mdir not found in bundle; cannot check marker; treating as absent")
            appendConsole("AVM: WARNING — could not check whether Windows is already installed (mdir missing from the app bundle). Proceeding as a new install.\n")
            return false
        }

        let process = Process()
        process.executableURL = mdirURL
        process.arguments = ["-i", imgPath, "::"]

        // Inherit the environment but add MTOOLS_SKIP_CHECK and STRIP
        // DYLD_LIBRARY_PATH (it poisons mtools — proven; never set it for
        // pipeline child processes).
        var env = ProcessInfo.processInfo.environment
        env["MTOOLS_SKIP_CHECK"] = "1"
        env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            avmLog("checkInstallCompleteMarker: mdir failed to launch: \(error) — treating marker as absent")
            return false
        }
        process.waitUntilExit()

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        if process.terminationStatus != 0 {
            avmLog("checkInstallCompleteMarker: mdir exited \(process.terminationStatus); output: \(output) — treating marker as absent")
            return false
        }

        let found = output.uppercased().contains("AVMDONE")
        avmLog("checkInstallCompleteMarker: marker \(found ? "PRESENT" : "absent") on \(imgPath)")
        return found
    }

    /// Ensure the AVM-built install media (install-avm.iso + autounattend.img)
    /// exists in the runtime dir for a VM that has an install ISO configured.
    /// Runs the six-stage WindowsInstallPipeline (off the main actor — it's
    /// @concurrent internally; progress hops back here) on the FIRST start; on
    /// subsequent starts the artifacts are reused, so the multi-minute build cost
    /// is paid once. A VM with no installISOPath (already installed) is a no-op.
    ///
    /// After a FRESH build, any stale nvram.fd is removed so the first boot of
    /// the new media gets fresh NVRAM — a reused NVRAM has stale boot entries
    /// and can fall to the UEFI shell (proven).
    ///
    /// ANNOUNCEMENTS: completion and failure both announce via Announcer
    /// (sound + system voice, frontmost or not) — the multi-minute build is
    /// exactly when the user Cmd-Tabs away, and a silent failure here cost
    /// half an hour once (wrong-ISO incident, 2026-07-11).
    private func ensureInstallMedia(configuration: VMConfiguration, runtimeDir: URL) async throws {
        guard let iso = configuration.installISOPath, !iso.isEmpty else { return }

        let fm = FileManager.default
        let rebuiltISO = runtimeDir.appendingPathComponent("install-avm.iso")
        let answerImage = runtimeDir.appendingPathComponent("autounattend.img")
        if fm.fileExists(atPath: rebuiltISO.path), fm.fileExists(atPath: answerImage.path) {
            avmLog("ensureInstallMedia: reusing existing install media in \(runtimeDir.path)")
            appendConsole("AVM: Using previously built install media.\n")
            return
        }

        avmLog("ensureInstallMedia: building install media from \(iso)")
        appendConsole("AVM: Building unattended install media. This can take several minutes on some Macs.\n")
        installProgress = "Preparing the Windows install media."

        let pipeline = WindowsInstallPipeline()
        pipeline.onProgress = { [weak self] progress in
            // Delivered ON the main actor by the pipeline's emit().
            self?.installProgress = progress.spoken
            self?.appendConsole("AVM: \(progress.visible)\n")
        }

        let input = PipelineInput(
            vmID: configuration.id,
            sourceISOPath: iso,
            runtimeDir: runtimeDir,
            editionName: "",      // empty -> pipeline resolves + validates the default (issue #6)
            productKey: "",       // (edition-picker UI fills these later)
            confirmWarning: { [weak self] reason in
                // Invoked OFF the main actor (pipeline contract); hop to the
                // main-actor handler, which asks the UI or defaults to proceed.
                guard let self else { return true }
                return await self.handleInstallWarning(reason)
            }
        )

        do {
            let output = try await pipeline.run(input)
            avmLog("ensureInstallMedia: pipeline complete — \(output.rebuiltISOPath)")
            appendConsole("AVM: Install media ready.\n")
            installProgress = "Install media ready."
            Announcer.shared.announce(
                "Install media ready. Starting the virtual machine.",
                tone: .success
            )
        } catch {
            installProgress = ""
            avmLog("ensureInstallMedia: pipeline FAILED: \(error.localizedDescription)")
            appendConsole("AVM: Install media build failed: \(error.localizedDescription)\n")
            Announcer.shared.announce(
                "Install media build failed. \(error.localizedDescription)",
                tone: .failure
            )
            throw error
        }

        // Fresh NVRAM for the first boot of newly built media (stale boot order
        // falls to the UEFI shell — proven; buildQEMUArguments recreates it from
        // the padded edk2-arm-vars.fd template).
        let nvram = runtimeDir.appendingPathComponent("nvram.fd")
        if fm.fileExists(atPath: nvram.path) {
            try? fm.removeItem(at: nvram)
            avmLog("ensureInstallMedia: removed stale nvram.fd for a fresh first boot")
        }
    }

    /// Main-actor warning gate for the pipeline's validation WARN tier. Asks the
    /// UI via installWarningHandler if one is set; otherwise notes the warning in
    /// the console and proceeds (the pipeline's own headless default).
    private func handleInstallWarning(_ reason: String) async -> Bool {
        if let handler = installWarningHandler {
            return await handler(reason)
        }
        appendConsole("AVM: WARNING — \(reason) Proceeding.\n")
        avmLog("handleInstallWarning: no UI handler set; proceeding past: \(reason)")
        return true
    }

    // MARK: - Public API

    func startVM(configuration: VMConfiguration) async throws {
        avmLog("startVM: called for \(configuration.name)")

        guard case .stopped = state else {
            avmLog("startVM: not stopped, aborting")
            throw AVMError.vmAlreadyRunning
        }

        guard let qemuURL = qemuBinaryURL else {
            let msg = "qemu-system-aarch64 was not found in AVM.app/Contents/Resources."
            avmLog("startVM: \(msg)")
            state = .error(msg)
            throw AVMError.binaryNotFound("qemu-system-aarch64")
        }
        avmLog("startVM: found QEMU executable at \(qemuURL.path)")

        reapOrphanedQEMU(for: configuration.id)
        reapOrphanedSwtpm(for: configuration.id)

        activeConfiguration = configuration
        state = .starting
        appendConsole("AVM: Starting VM \"\(configuration.name)\"…\n")

        let runtimeDir = try prepareRuntimeDirectory(for: configuration.id)
        vmRuntimeDir = runtimeDir

        // REINSTALL GUARD: check for the install-complete marker BEFORE any
        // install-media work. If the answer file's specialize pass has written
        // AVMDONE.TAG to the UNATTEND volume, Windows is on this VM's disk —
        // skip the media build, do not attach install media, and do not start
        // the boot keypress task, so this start cannot re-enter Setup and let
        // the answer file wipe the installed disk.
        let installComplete = checkInstallCompleteMarker(configuration: configuration, runtimeDir: runtimeDir)

        if installComplete {
            avmLog("startVM: install-complete marker PRESENT — skipping media build/attach and boot keypress")
            appendConsole("AVM: Windows is already installed on this VM. Booting from the installed disk; install media will not be attached.\n")
        } else {
            // Build the unattended install media FIRST if this VM has an install ISO
            // and the media doesn't exist yet (six-stage pipeline; reused thereafter).
            // A failure surfaces as .error with the pipeline's actionable message
            // (and an interrupting announcement from ensureInstallMedia).
            do {
                try await ensureInstallMedia(configuration: configuration, runtimeDir: runtimeDir)
            } catch {
                state = .error(error.localizedDescription)
                throw error
            }
        }

        let socketDir = URL(fileURLWithPath: "/tmp/avm/\(configuration.id.uuidString)")
        try FileManager.default.createDirectory(at: socketDir, withIntermediateDirectories: true)
        vmSocketDir = socketDir

        let spicePath = socketDir.appendingPathComponent("spice.sock").path
        let qmpPath   = socketDir.appendingPathComponent("qmp.sock").path
        let qmp2Path  = socketDir.appendingPathComponent("qmp2.sock").path
        let tpmPath   = socketDir.appendingPathComponent("tpm.sock").path
        spiceSocketPath = spicePath
        avmLog("startVM: QMP socket path: \(qmpPath)")
        avmLog("startVM: diagnostic QMP socket path: \(qmp2Path)")
        avmLog("startVM: SPICE socket path: \(spicePath)")

        for path in [spicePath, qmpPath, qmp2Path, tpmPath] {
            try? FileManager.default.removeItem(atPath: path)
        }

        var tpmArgs: [String] = []
        if let swtpmURL = swtpmBinaryURL {
            avmLog("startVM: launching swtpm")
            try await launchSwtpm(binaryURL: swtpmURL, socketPath: tpmPath, runtimeDir: runtimeDir)
            tpmArgs = buildTPMArguments(socketPath: tpmPath)
            appendConsole("AVM: swtpm started for TPM 2.0 emulation.\n")
        } else {
            avmLog("startVM: swtpm not found, skipping TPM")
            appendConsole("AVM: swtpm not found in bundle — TPM emulation disabled.\n")
        }

        let args = buildQEMUArguments(
            configuration: configuration,
            spiceSocketPath: spicePath,
            qmpSocketPath: qmpPath,
            diagnosticQMPSocketPath: qmp2Path,
            tpmArguments: tpmArgs,
            runtimeDir: runtimeDir,
            attachInstallMedia: !installComplete
        )
        avmLog("startVM: built QEMU args: \(args.joined(separator: " "))")
        // STAGE C (2026-08-03): the full argument list no longer floods the
        // in-app console — it is unsanitized (home paths) and noisy for
        // testers. The sanitized copy lives in the diagnostic log (line above).
        appendConsole("AVM: QEMU arguments recorded in the diagnostic log.\n")

        avmLog("startVM: launching QEMU child process")
        try launchQEMU(executableURL: qemuURL, arguments: args)
        avmLog("startVM: QEMU launched, connecting to QMP")

        try await connectToQMP(socketPath: qmpPath)
        avmLog("startVM: QMP connected, performing handshake")

        try await performQMPHandshake()
        avmLog("startVM: handshake complete, VM is running")

        state = .running
        appendConsole("AVM: VM is running.\n")
        beginQMPEventMonitoring()

        // Tap Enter across the boot window to satisfy Windows' "Press any key to
        // boot from CD or DVD..." prompt (REQUIRED — see startBootKeypressTask).
        // REINSTALL GUARD: suppressed when the install-complete marker is
        // present — no install media is attached, and answering a phantom
        // prompt is the other half of the reinstall hazard.
        if installComplete {
            avmLog("startVM: boot keypress task NOT started (install-complete marker present)")
        } else {
            startBootKeypressTask()
            // INSTALL WATCHDOG: an install is in flight — watch for the wedge
            // signature until the marker appears or the VM stops.
            startInstallWatchdog(configuration: configuration, runtimeDir: runtimeDir)
        }
    }

    func stopVM() async throws {
        guard case .running = state else { return }
        state = .stopping
        try await sendQMPCommand("system_powerdown", arguments: nil)
    }

    func forceStopVM() {
        stopBootKeypressTask()
        stopInstallWatchdog()
        qemuProcess?.terminate()
        swtpmProcess?.terminate()
        cleanUp()
        state = .stopped
        appendConsole("AVM: VM force-stopped.\n")
    }

    func pauseVM() async throws {
        guard case .running = state else { return }
        try await sendQMPCommand("stop", arguments: nil)
        state = .paused
        appendConsole("AVM: VM paused.\n")
    }

    func resumeVM() async throws {
        guard case .paused = state else { return }
        try await sendQMPCommand("cont", arguments: nil)
        state = .running
        appendConsole("AVM: VM resumed.\n")
    }

    /// Sends a hardware reset to the guest via QMP `system_reset` — the
    /// virtual reset button. UPGRADED 2026-07-12 from bare plumbing to a menu
    /// feature (Virtual Machine menu, Cmd-Shift-R), second member of that
    /// family after sendCtrlAltDel. Two jobs:
    /// 1. RECOVERY EXPERIMENT for the stochastic firmware reboot wedge (an
    ///    upstream QEMU/edk2 bug — UTM issue #7648; AVM's serial-level
    ///    evidence posted there 2026-07-12). Force-stop + restart is PROVEN
    ///    to recover; whether an in-process reset also recovers is UNPROVEN —
    ///    the next wild occurrence is the experiment. If it works, the
    ///    watchdog can eventually automate it.
    /// 2. General escape hatch for any hard-hung guest: a reset is
    ///    deliverable even when the guest is too wedged to honor the ACPI
    ///    powerdown that stopVM sends.
    /// Unlike stopVM this does NOT shut the guest down cleanly — unsaved
    /// guest state is lost, exactly as with a physical reset button.
    @discardableResult
    func resetVM() async -> Bool {
        guard case .running = state else {
            appendConsole("AVM: Can't reset — the VM isn't running.\n")
            return false
        }
        do {
            try await sendQMPCommand("system_reset", arguments: nil)
            avmLog("resetVM: system_reset sent")
            appendConsole("AVM: Reset the virtual machine. It is restarting now.\n")
            return true
        } catch {
            avmLog("resetVM: failed: \(error)")
            appendConsole("AVM: Resetting the virtual machine failed: \(error.localizedDescription)\n")
            return false
        }
    }

    // MARK: - Guest Screen Capture (screendump)

    /// Captures the current guest framebuffer to a PPM using QMP `screendump`.
    /// QEMU writes its OWN framebuffer to disk, independent of the SPICE display
    /// path / CocoaSpice — works regardless of GL state. Writes guest-screen.ppm
    /// in the VM runtime dir (AVM-owned, no TCC prompt). Our QEMU was built WITHOUT
    /// libpng so PNG is unavailable; PPM is the dependency-free fallback (convert
    /// with `sips` on the host if needed).
    ///
    /// STAGE C (2026-08-03): the auto-firing DEBUG timer that drove this every
    /// 4 seconds is REMOVED (display investigation closed). The method itself
    /// is RETAINED as an on-demand diagnostic — the ability to answer "what is
    /// the guest actually showing" without sight is core to AVM's support
    /// story, and the install watchdog's captureWatchdogFrame uses the same
    /// QMP mechanism with its own file.
    ///
    /// DISPLAY NOTE (2026-08-02): the VM has TWO heads (ramfb + virtio-gpu-pci).
    /// Runs 9/10 established which is which by size: virtio-gpu is the 800x600
    /// head that firmware/Windows actually draw through; ramfb is the 640x480
    /// head that never initializes ("Guest has not initialized the display").
    /// screendump dumps the head QEMU considers the active console, which in
    /// practice has been the live virtio-gpu head. A placeholder dump means
    /// EITHER very early boot OR the dump landed on the dead head — correlate
    /// with other evidence before concluding the guest is not drawing.
    /// (Size discrimination: 921615 bytes = 640x480 placeholder; 1440015 =
    /// real 800x600 content.)
    @discardableResult
    func captureScreendump() async -> String? {
        guard case .running = state else { return nil }
        guard let runtimeDir = vmRuntimeDir else { return nil }
        let ppmPath = runtimeDir.appendingPathComponent("guest-screen.ppm").path
        do {
            try await sendQMPCommand("screendump", arguments: [
                "filename": ppmPath,
                "format": "ppm"
            ])
            avmLog("captureScreendump: wrote \(ppmPath)")
            return ppmPath
        } catch {
            avmLog("captureScreendump: failed: \(error)")
            return nil
        }
    }

    // MARK: - Install Watchdog

    /// INSTALL WATCHDOG (permanent feature): while an install is in flight,
    /// samples every 20s — guest framebuffer (QMP screendump to
    /// watchdog-screen.ppm, its own file, separate from captureScreendump()'s
    /// guest-screen.ppm; QMP access is serialized either way), QEMU's total
    /// CPU%% (ps), and the qcow2 disk's mtime + size (FileManager). NINE
    /// consecutive samples (~3 min) of byte-identical frame + CPU >= 90%% +
    /// FLAT DISK is the wedge signature observed live 2026-07-12 (stochastic
    /// firmware hang at the mid-install reboot: frozen edk2 splash, one core
    /// pegged, serial silent, no marker — evidence in
    /// ~/Desktop/avm-evidence-firmwedge). On detection: failure announcement
    /// with recovery guidance, ONCE per run (further detections log only).
    ///
    /// DISK-ACTIVITY AMENDMENT (2026-07-19, from Handoff 14 §2): the
    /// frame+CPU signature ALONE also matches a HEALTHY Windows repair/update
    /// pass — observed live: ~50 minutes of pure-black frozen frame and
    /// 105–210%% CPU after a reset, resolving on its own into Narrator at the
    /// sign-in screen, discriminated ONLY by the qcow2's mtime moving across
    /// a 20s window (size alone is insufficient: in-place rewrites move mtime
    /// without growth). A true firmware wedge spins pre-BDS and can never
    /// generate guest disk I/O. So: a sample counts toward the wedge streak
    /// ONLY when the disk is ALSO flat (mtime AND size unchanged since the
    /// previous tick); ANY disk movement resets the streak exactly as a
    /// changing frame does, and a wedge-looking sample with an active disk
    /// logs "likely repair/update, waiting" and stays deliberately SILENT —
    /// announcing a reset during a healthy repair pass is how a guest gets
    /// bricked into WinRE.
    ///
    /// Stand-down conditions: the marker appears (specialize ran — the danger
    /// zone is past), the VM leaves .running, or the task is cancelled.
    /// SETUP-UNDERWAY MILESTONE (2026-07-24): the marker stand-down also
    /// ANNOUNCES (.success) — the one mid-install moment we reliably detect,
    /// so a fresh install is not silence-as-success. The wording is
    /// forward-looking: names what is happening, pre-explains the reboots,
    /// and states Windows will NOT speak on its own (user turns Narrator on
    /// with Ctrl-Cmd-Return) — so it cannot be mistaken for completion and
    /// never promises an automatic completion signal (the OOBE startup sound
    /// is unreliable; the docs cover it as a sometimes-hint).
    ///
    /// FAIL-SAFE: a false positive tells the user to restart an unfinished
    /// install — the marker is absent, so the reinstall guard correctly allows
    /// the reinstall, and the half-installed disk holds nothing worth
    /// protecting. Cost is time, never data. The threshold is conservative:
    /// normal install phases either animate the screen (spinners, progress
    /// text), idle the CPU, or write the disk; the observed wedge held its
    /// full signature 30+ min. An unreadable disk sample fails toward silence
    /// (streak reset), same rule as the frame and CPU probes.
    private func startInstallWatchdog(configuration: VMConfiguration, runtimeDir: URL) {
        stopInstallWatchdog()
        installWatchdogTask = Task { [weak self] in
            let sampleNanoseconds: UInt64 = 20_000_000_000  // 20s
            let requiredConsecutive = 9                     // 9 × 20s ≈ 3 min
            var previousFrame: Data? = nil
            var previousDiskMTime: Date? = nil
            var previousDiskSize: UInt64? = nil
            var consecutiveWedgeSamples = 0
            var announcedThisRun = false

            avmLog("installWatchdog: started (20s samples; \(requiredConsecutive) consecutive frozen-frame + >=90% CPU + flat-disk samples = wedge)")

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sampleNanoseconds)
                if Task.isCancelled { return }
                guard let self else { return }

                let stillRunning = await MainActor.run { () -> Bool in
                    if case .running = self.state { return true }
                    return false
                }
                if !stillRunning {
                    avmLog("installWatchdog: VM no longer running — standing down")
                    return
                }

                // Stand down the moment the marker appears: specialize has run,
                // Windows is on the disk, the wedge window is behind us.
                // SETUP-UNDERWAY MILESTONE: this is also the one mid-install
                // moment we reliably detect, so announce it (see doc comment).
                let markerPresent = await MainActor.run {
                    self.checkInstallCompleteMarker(configuration: configuration, runtimeDir: runtimeDir)
                }
                if markerPresent {
                    avmLog("installWatchdog: install-complete marker PRESENT — standing down; announcing Setup-underway milestone")
                    await MainActor.run {
                        self.appendConsole("AVM: Windows Setup is underway and will restart the virtual machine a few times. This takes a while. Windows will not speak on its own — when Setup is done, enter Windows and press Control Command Return to turn on Narrator.\n")
                        Announcer.shared.announce(
                            "Windows Setup is underway and will restart the virtual machine a few times. This takes a while. Windows will not speak on its own. When Setup is done, enter Windows and press Control Command Return to turn on Narrator.",
                            tone: .success
                        )
                    }
                    return
                }

                // Sample the frame, the CPU, and the disk.
                let frame = await self.captureWatchdogFrame(runtimeDir: runtimeDir)
                let cpu = await MainActor.run { self.sampleQEMUCPUPercent() }
                let disk = await MainActor.run { self.sampleDiskActivity(path: configuration.diskImagePath) }

                guard let frame, let cpu, let disk else {
                    // Can't sample -> can't judge. Reset the streak (fail toward
                    // silence: an unjudgeable sample must not count toward an
                    // alarm) and try again next tick.
                    consecutiveWedgeSamples = 0
                    avmLog("installWatchdog: sample unavailable (frame: \(frame != nil), cpu: \(cpu != nil), disk: \(disk != nil)) — streak reset")
                    previousFrame = frame ?? previousFrame
                    if let disk {
                        previousDiskMTime = disk.mtime
                        previousDiskSize = disk.size
                    }
                    continue
                }

                let frameFrozen = (previousFrame != nil && frame == previousFrame)
                previousFrame = frame

                // DISK-ACTIVITY AMENDMENT: flat only when we HAVE a previous
                // sample and neither mtime nor size moved. mtime is the primary
                // probe (in-place rewrites move mtime without growing the
                // file); size corroborates. The first tick can never judge
                // flat — same rule as the frame comparison.
                let diskFlat = (previousDiskMTime != nil
                                && disk.mtime == previousDiskMTime
                                && disk.size == previousDiskSize)
                let diskMoved = (previousDiskMTime != nil && !diskFlat)
                previousDiskMTime = disk.mtime
                previousDiskSize = disk.size

                if frameFrozen && cpu >= 90.0 && diskFlat {
                    consecutiveWedgeSamples += 1
                    avmLog("installWatchdog: wedge-signature sample \(consecutiveWedgeSamples)/\(requiredConsecutive) (frame frozen, cpu \(cpu)%, disk flat)")
                } else if frameFrozen && cpu >= 90.0 && diskMoved {
                    // The Handoff 14 §2 shape: looks exactly like the wedge on
                    // frame+CPU, but the guest is doing real disk I/O — a
                    // repair/update pass. DELIBERATELY SILENT (log only): the
                    // right guidance is to wait, and silence IS the wait. A
                    // reset here is how a guest gets bricked into WinRE.
                    if consecutiveWedgeSamples > 0 {
                        avmLog("installWatchdog: streak reset by disk activity")
                    }
                    consecutiveWedgeSamples = 0
                    avmLog("installWatchdog: wedge-like (frame frozen, cpu \(cpu)%) but disk ACTIVE (mtime moved) — likely repair/update; waiting")
                } else {
                    if consecutiveWedgeSamples > 0 {
                        avmLog("installWatchdog: signature broken (frame frozen: \(frameFrozen), cpu \(cpu)%, disk flat: \(diskFlat)) — streak reset")
                    }
                    consecutiveWedgeSamples = 0
                }

                if consecutiveWedgeSamples >= requiredConsecutive && !announcedThisRun {
                    announcedThisRun = true
                    avmLog("installWatchdog: WEDGE DETECTED — announcing recovery guidance")
                    await MainActor.run {
                        self.appendConsole("AVM: The Windows installation appears to be stuck (screen frozen with high CPU for about 3 minutes). To recover: choose Reset Virtual Machine from the Virtual Machine menu, or press Command Shift R. If it is still stuck a few minutes after the reset, stop the virtual machine and start it again — Setup will then start over from the beginning.\n")
                        Announcer.shared.announce(
                            "The Windows installation appears to be stuck. To recover, press Command Shift R to reset the virtual machine. If it is still stuck a few minutes later, stop the virtual machine and start it again. Setup will then start over from the beginning.",
                            tone: .failure
                        )
                    }
                    // Keep sampling (log-only) so the debug log records whether
                    // the wedge persists or the guest recovers on its own.
                }
            }
        }
    }

    /// Cancel the install watchdog.
    private func stopInstallWatchdog() {
        installWatchdogTask?.cancel()
        installWatchdogTask = nil
    }

    /// Watchdog frame sample: QMP screendump to watchdog-screen.ppm (its own
    /// file, separate from captureScreendump()'s guest-screen.ppm), read back
    /// as Data for a byte-identical comparison against the previous sample.
    private func captureWatchdogFrame(runtimeDir: URL) async -> Data? {
        guard case .running = state else { return nil }
        let path = runtimeDir.appendingPathComponent("watchdog-screen.ppm").path
        do {
            try await sendQMPCommand("screendump", arguments: [
                "filename": path,
                "format": "ppm"
            ])
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            avmLog("captureWatchdogFrame: screendump failed: \(error)")
            return nil
        }
    }

    /// Watchdog CPU sample: QEMU's current CPU%% via ps (same host-tool pattern
    /// as the orphan reapers). Returns nil if the process is gone or ps fails.
    private func sampleQEMUCPUPercent() -> Double? {
        guard let proc = qemuProcess, proc.isRunning else { return nil }
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "pcpu=", "-p", "\(proc.processIdentifier)"]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
        } catch {
            avmLog("sampleQEMUCPUPercent: ps failed to launch: \(error)")
            return nil
        }
        ps.waitUntilExit()
        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Watchdog disk sample (DISK-ACTIVITY AMENDMENT, 2026-07-19): the qcow2's
    /// modification time and byte size via FileManager. mtime movement across
    /// a sample window means live guest I/O — the single fact that
    /// discriminated the Handoff 14 §2 healthy repair pass from the true
    /// firmware wedge (which spins pre-BDS and can never touch the disk).
    /// Returns nil if the path is empty or attributes are unreadable, which
    /// the caller treats as unjudgeable (streak reset — fail toward silence).
    private func sampleDiskActivity(path: String) -> (mtime: Date, size: UInt64)? {
        guard !path.isEmpty else {
            avmLog("sampleDiskActivity: empty disk path — cannot sample")
            return nil
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            avmLog("sampleDiskActivity: attributes unreadable at \(path)")
            return nil
        }
        return (mtime: mtime, size: size)
    }

    // MARK: - Boot Keypress ("Press any key to boot from CD")

    /// Sends a single Enter keypress into the guest via QMP `send-key`. The
    /// firmware reads it from the VM's usb-kbd device, so it works during
    /// firmware/boot before any guest input stack is up. REQUIRED to get past
    /// Windows' "Press any key to boot from CD or DVD..." prompt (the optical boot
    /// loader times out and fails to boot otherwise).
    @discardableResult
    func sendBootKeypress() async -> Bool {
        guard case .running = state else { return false }
        do {
            try await sendQMPCommand("send-key", arguments: [
                "keys": [["type": "qcode", "data": "ret"]]
            ])
            return true
        } catch {
            avmLog("sendBootKeypress: failed: \(error)")
            return false
        }
    }

    /// Sends Ctrl+Alt+Delete to the guest via QMP send-key — the Windows secure
    /// attention sequence (lock screen, sign-out, Task Manager, password
    /// changes). PERMANENT FEATURE, first member of the "send system key"
    /// family, exposed as a menu command. This chord CANNOT be typed from the
    /// host: Alt is Option on a Mac keyboard, so the chord is Control+Option+
    /// Forward Delete — and Control+Option is the VoiceOver modifier, so
    /// VoiceOver consumes it before AVM ever sees a keydown (verified by test
    /// 2026-07-11: VO pings and nothing transits, even with the VO pass-through
    /// command). QMP injects at the virtual-hardware level via the usb-kbd
    /// device (same path as the boot keypress), bypassing macOS keyboard
    /// forwarding entirely. send-key presses the listed keys together and
    /// releases them as a chord, so no stuck keys are possible.
    @discardableResult
    func sendCtrlAltDel() async -> Bool {
        guard case .running = state else {
            appendConsole("AVM: Can't send Ctrl Alt Delete — the VM isn't running.\n")
            return false
        }
        do {
            try await sendQMPCommand("send-key", arguments: [
                "keys": [
                    ["type": "qcode", "data": "ctrl"],
                    ["type": "qcode", "data": "alt"],
                    ["type": "qcode", "data": "delete"]
                ]
            ])
            avmLog("sendCtrlAltDel: sent")
            appendConsole("AVM: Sent Ctrl Alt Delete to the VM.\n")
            return true
        } catch {
            avmLog("sendCtrlAltDel: failed: \(error)")
            appendConsole("AVM: Sending Ctrl Alt Delete failed: \(error.localizedDescription)\n")
            return false
        }
    }

    /// Send Enter every 0.4s for ~24 seconds after the VM reaches running, to
    /// land densely inside the brief "press any key" window. View-independent
    /// async Task (a RunLoop Timer was torn down by the SwiftUI auto-lock view
    /// transition); QMP access serialized in sendQMPCommand so these sends cannot
    /// collide with any screendump capture. Relies on a usb-kbd device.
    private func startBootKeypressTask() {
        stopBootKeypressTask()
        bootKeypressTask = Task { [weak self] in
            for i in 1 ... 60 {
                if Task.isCancelled { return }
                guard let self else { return }
                let stillRunning = await MainActor.run { () -> Bool in
                    if case .running = self.state { return true }
                    return false
                }
                if !stillRunning { return }
                let ok = await self.sendBootKeypress()
                if i == 1 || i % 10 == 0 {
                    avmLog("startBootKeypressTask: sent Enter (#\(i), ok=\(ok)).")
                }
                try? await Task.sleep(nanoseconds: 400_000_000) // 0.4s
            }
            avmLog("startBootKeypressTask: boot keypress window ended (60 taps over ~24s).")
        }
        avmLog("startBootKeypressTask: started (Enter every 0.4s for ~24s, view-independent Task).")
    }

    /// Cancel the boot keypress task.
    private func stopBootKeypressTask() {
        bootKeypressTask?.cancel()
        bootKeypressTask = nil
    }

    // MARK: - swtpm Launch

    private func launchSwtpm(binaryURL: URL, socketPath: String, runtimeDir: URL) async throws {
        let tpmStateDir = runtimeDir.appendingPathComponent("tpm-state")
        try FileManager.default.createDirectory(at: tpmStateDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "socket",
            "--tpmstate", "dir=\(tpmStateDir.path)",
            "--ctrl", "type=unixio,path=\(socketPath)",
            "--tpm2",
            "--log", "level=0"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = FileHandle.nullDevice

        try process.run()
        swtpmProcess = process

        for _ in 0 ..< 20 {
            if FileManager.default.fileExists(atPath: socketPath) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw AVMError.swtpmDidNotStart
    }

    // MARK: - QEMU Argument Builder

    private func buildQEMUArguments(
        configuration: VMConfiguration,
        spiceSocketPath: String,
        qmpSocketPath: String,
        diagnosticQMPSocketPath: String,
        tpmArguments: [String],
        runtimeDir: URL,
        attachInstallMedia: Bool
    ) -> [String] {

        var args: [String] = []

        if let resourcePath = Bundle.main.resourcePath {
            args += ["-L", resourcePath]
        }

        // Machine: plain `virt` with NO highmem flag, matching UTM's working
        // Windows ARM command line.
        args += ["-machine", "virt,accel=hvf"]

        // CPU: `host`, matching UTM's working Windows ARM command line.
        args += ["-cpu", "host"]

        // UNIQUE HARDWARE IDENTITY (-uuid + -smbios) — REQUIRED. DO NOT REMOVE.
        // Without these, every AVM VM presents QEMU's DEFAULT identity (including
        // the all-zeros system UUID shared by every default-configured QEMU VM in
        // the world). During OOBE's "Please keep your PC on" phase, Windows sends
        // a hardware hash derived from SMBIOS to Microsoft's Autopilot service —
        // and an organization's Intune tenant has REGISTERED the default QEMU
        // identity, so any default-identity VM gets THEIR Autopilot profile
        // (isForcedEnrollmentEnabled=1) and OOBE forces "work or school" sign-in
        // with NO personal-account path. Root-caused 2026-07-11: the tenant
        // profile (TenantId, MDM ID, LAPTOP-%SERIAL% naming) was read out of the
        // guest's own registry at HKLM\SOFTWARE\Microsoft\Provisioning\
        // Diagnostics\AutoPilot. A unique per-VM identity produces a unique
        // hardware hash that matches no tenant, so OOBE behaves like a genuinely
        // new PC (stock consumer flow — AVM's deliberate OOBE policy).
        // The identity derives from the VM's existing UUID: deterministic (same
        // VM presents the same hardware every boot — Windows licensing/activation
        // cares), unique per VM, and no new state to store. The manufacturer/
        // product strings are honest and make AVM VMs identifiable in the guest's
        // System Information.
        let vmUUID = configuration.id.uuidString
        args += ["-uuid", vmUUID]
        args += ["-smbios", "type=1,manufacturer=AVM,product=AVM Virtual Machine,serial=\(vmUUID)"]

        args += ["-smp", "\(max(1, configuration.cpuCount))"]
        args += ["-m", "\(configuration.ramSizeGB * 1024)M"]

        if let firmware = bundledBinaryURL(named: "edk2-aarch64-code.fd") {
            let nvramPath = runtimeDir.appendingPathComponent("nvram.fd").path

            // Build the writable NVRAM from the PROPER vars template (edk2-arm-vars.fd,
            // note "arm", shared across arm/aarch64 per the 60-edk2-aarch64.json
            // firmware descriptor), padded to the 64MB pflash size. The code .fd is
            // the firmware executable, NOT a variable store.
            if !FileManager.default.fileExists(atPath: nvramPath) {
                let pflashSize = 67108864 // 64 MiB, the aarch64 virt pflash size
                if let varsTemplate = bundledBinaryURL(named: "edk2-arm-vars.fd"),
                   let templateData = try? Data(contentsOf: URL(fileURLWithPath: varsTemplate.path)) {
                    var nvramData = templateData
                    if nvramData.count < pflashSize {
                        nvramData.append(Data(count: pflashSize - nvramData.count))
                    }
                    do {
                        try nvramData.write(to: URL(fileURLWithPath: nvramPath))
                        avmLog("buildQEMUArguments: created padded NVRAM (\(nvramData.count) bytes) from edk2-arm-vars.fd")
                    } catch {
                        avmLog("buildQEMUArguments: FAILED to write NVRAM: \(error)")
                    }
                } else {
                    let blank = Data(count: pflashSize)
                    try? blank.write(to: URL(fileURLWithPath: nvramPath))
                    avmLog("buildQEMUArguments: WARNING — edk2-arm-vars.fd not bundled; wrote blank 64MB NVRAM")
                    appendConsole("AVM: WARNING — edk2-arm-vars.fd missing; using blank NVRAM.\n")
                }
            }

            args += [
                "-drive", "if=pflash,format=raw,file=\(firmware.path),readonly=on",
                "-drive", "if=pflash,format=raw,file=\(nvramPath)"
            ]
        } else {
            appendConsole("AVM: WARNING — edk2-aarch64-code.fd not found in bundle.\n")
        }

        // USB controller + INPUT DEVICES. usb-kbd is REQUIRED: without it the
        // firmware's "Press any key to boot from CD or DVD..." prompt can never
        // receive the keypress that boots the Windows installer (QMP send-key has
        // nothing to deliver the key to), and the optical boot loader times out
        // and fails to boot. usb-tablet is for pointer input. Declared BEFORE the
        // drives so bus=usb.0 resolves.
        // MOUSE MODE (issue #4 — mechanism narrowed 2026-08-09; full three-run
        // record in the file header): SPICE holds server-mode cursor whenever
        // TWO display channels exist and grants client mode with ONE — the
        // multi-display/no-agent theory is the leading explanation (AVM
        // bundles no Windows SPICE agent; agent-mouse=on as of the Path A
        // prototype, 2026-08-10 — see the -spice line). display=gpu0
        // is KEPT: launch-proven, harmless, possibly required by whichever
        // fix path ships (guest agent, or single-display-channel operation).
        args += ["-device", "qemu-xhci,id=usb"]
        args += ["-device", "usb-kbd,bus=usb.0"]
        args += ["-device", "usb-tablet,bus=usb.0,display=gpu0"]

        // INSTALL DISK: nvme (target disk Windows installs onto). bootindex=1 so
        // the install media (bootindex=0) boots first.
        if !configuration.diskImagePath.isEmpty {
            args += [
                "-drive",
                "if=none,id=disk0,file=\(configuration.diskImagePath),format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap",
                "-device", "nvme,drive=disk0,serial=avmdisk0,bootindex=1"
            ]
        }

        // REINSTALL GUARD: attachInstallMedia is false when the install-complete
        // marker (AVMDONE.TAG) was found on the UNATTEND volume — Windows is on
        // the disk, so attaching bootindex=0 install media would re-enter Setup
        // and the answer file would WIPE it. With no install media attached, the
        // nvme disk (bootindex=1) boots the installed Windows.
        if !attachInstallMedia {
            avmLog("buildQEMUArguments: install media attach suppressed (install-complete marker present)")
        } else if let iso = configuration.installISOPath, !iso.isEmpty {
            // INSTALL MEDIA: the AVM-BUILT install ISO (install-avm.iso in the
            // runtime dir — the winpeshl /legacy + $WinPEDriver$ + rebuilt image
            // produced by WindowsInstallPipeline), NOT the user's original ISO:
            // 25H2's ConX setup on the original media silently ignores the answer
            // file, so attaching the original would run an interactive install a
            // blind user can't see. ensureInstallMedia guarantees the rebuilt ISO
            // exists before launch. Attached as REMOVABLE usb-storage bootindex=0
            // (boot-proven attach): WinPE always has a usb-storage driver, and
            // removable media is where Setup scans for autounattend.xml. The
            // "press any key" prompt is handled by the boot keypress task.
            let rebuiltISOPath = runtimeDir.appendingPathComponent("install-avm.iso").path
            if FileManager.default.fileExists(atPath: rebuiltISOPath) {
                args += [
                    "-drive", "if=none,id=cdrom0,file=\(rebuiltISOPath),media=cdrom,readonly=on",
                    "-device", "usb-storage,drive=cdrom0,bootindex=0,removable=on"
                ]
                avmLog("buildQEMUArguments: attached AVM-built install ISO at \(rebuiltISOPath)")
            } else {
                // Should be unreachable (ensureInstallMedia runs first and throws
                // on failure). Deliberately attach NOTHING rather than fall back
                // to the original ISO — the original boots ConX, ignores the
                // answer file, and strands a blind user in an interactive Setup.
                avmLog("buildQEMUArguments: ERROR — install-avm.iso missing at \(rebuiltISOPath); attaching no install media")
                appendConsole("AVM: ERROR — built install media is missing; not attaching install media.\n")
            }
        }

        // AUTOUNATTEND: FAT image with autounattend.xml, built by the pipeline
        // into the runtime dir. Attached as REMOVABLE usb-storage (boot-proven
        // attach) — Windows Setup scans REMOVABLE media for autounattend.xml, so
        // the previous fixed-nvme attachment was outside its search path and the
        // answer file was never applied. NOTE: attach is keyed on the FILE
        // existing (not installISOPath, and NOT gated by the reinstall guard), so
        // the writable UNATTEND volume stays available after install — it is the
        // install-complete marker's home and the guest→host file courier.
        let autounattendImagePath = runtimeDir.appendingPathComponent("autounattend.img").path
        if FileManager.default.fileExists(atPath: autounattendImagePath) {
            args += [
                "-drive", "if=none,id=unattend,file=\(autounattendImagePath),format=raw,cache=writeback",
                "-device", "usb-storage,drive=unattend,removable=on"
            ]
            avmLog("buildQEMUArguments: attached autounattend image at \(autounattendImagePath)")
            appendConsole("AVM: Attached autounattend.xml image for unattended install.\n")
        } else {
            avmLog("buildQEMUArguments: no autounattend image at \(autounattendImagePath) — normal (attended) install")
        }

        // NETWORK: explicit user-mode netdev + virtio-net-pci (the NetKVM driver
        // the pipeline injects binds to this device). Because the network config
        // is EXPLICIT, QEMU adds no implicit default NIC — so the unbundled
        // efi-virtio.rom default-NIC failure seen in bare `-nodefaults`-less
        // Terminal runs does not apply here; this exact line has booted VMs
        // in-app across sessions.
        args += ["-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0"]

        // agent-mouse=on (Path A prototype, 2026-08-10; was off): lets the
        // SPICE vdagent drive client-mode (absolute) mouse once an agent is
        // installed and running in the guest. With NO agent connected this
        // flag is EXPECTED to be inert (control run to verify — do not treat
        // as proven until it has). The virtio-serial/vdagent port wiring the
        // agent rides on already exists below (com.redhat.spice.0).
        args += [
            "-spice",
            "unix=on,addr=\(spiceSocketPath),disable-ticketing=on,agent-mouse=on"
        ]

        // DISPLAY: ramfb + virtio-gpu-pci TOGETHER, ramfb FIRST, ALL PHASES.
        // REVERTED to this pair 2026-08-02 after the run-phase single-head
        // matrix completed with BOTH cells falsified; RE-CONFIRMED as the
        // shipping order 2026-08-09 after the order-swap experiment (gpu0
        // first) was run once for mouse-mode and DISQUALIFIED (mouse-mode
        // still server AND placeholder-sized screendump — see the MOUSE MODE
        // record in the file header). FULL RECORD — do not re-run:
        //   - PAIR (this config): boots AND draws in every phase. Install:
        //     ramfb-first satisfies the optical boot loader's GOP setup
        //     (virtio-gpu-pci alone STALLS the CD loader before "Press any
        //     key"; bisection-proven, not fixable via romfile=), and
        //     virtio-gpu-pci is what firmware/Windows actually draw through.
        //     Mirrors UTM's "virtio-ramfb" device.
        //   - virtio-gpu-pci ALONE, run phase (RUN 9, 2026-08-02): FALSIFIED
        //     for real use. Installed Windows booted fully (JAWS up, guest
        //     healthy), firmware fills flowed, then fills stopped dead at the
        //     Windows display-stack handoff; screendump = "Display output is
        //     not active." Driverless Windows (no viogpudo bundled — payload
        //     is Balloon + NetKVM only) never activates a virtio-gpu scanout.
        //     (2026-08-09 addendum: the same single-head config read SPICE
        //     mouse-mode CLIENT with a connected client — the key mouse-mode
        //     mechanism finding; see the file header.)
        //   - ramfb ALONE, run phase (RUN 10, 2026-08-02): FALSIFIED. Nothing
        //     ever drew — not even firmware. One initial 640x480 fill at
        //     attach, then silence; screendump = "Guest has not initialized
        //     the display (yet)." Matches the install-phase bisection's
        //     "ramfb alone: placeholder forever", now known to be a firmware
        //     property, not a Setup property.
        //   - ORDER SWAP (gpu0 first, ramfb second; RUN 2026-08-09): tested
        //     ONCE for mouse-mode; mouse-mode stayed server (order theory
        //     falsified) and the screendump came back placeholder-sized —
        //     DISQUALIFIED as a candidate. ramfb-FIRST is the order.
        //   - HEAD IDENTIFICATION (by size, runs 9+10): virtio-gpu is the
        //     800x600 head that carries all real fills; ramfb is the 640x480
        //     head that never initializes. In the pair, ramfb is a permanent
        //     black passenger that still LOOKS like a display to the host
        //     (one blank fill, texture set, isVisible=1).
        //   - THE STOCHASTIC BLACK (runs 5/7, Handoffs 22–24A) was therefore a
        //     HOST-SIDE wrong-head binding: with two heads and unstable
        //     enumeration/slot order (slot inversion observed), the view
        //     sometimes bound to the ramfb impostor. Matches UTM issues
        //     #6332/#6883 ("render to an inactive display target", reported
        //     on Build 26200). THE FIX SHIPPED in VMView's display binding
        //     (bind deterministically to the LIVE head; Handoffs 25–27,
        //     proven across thirteen runs). Fallback path if it ever regresses:
        //     bundle viogpudo (upstream caveat: recent Windows builds
        //     black-screen on viogpudo install — virtio-win issue #1102).
        //   - Run 9 also proved the "second display generation" is host-side
        //     lifecycle (Enter Windows recreating the SPICE view) — it occurs
        //     with a single device and no guest reboot.
        // MOUSE MODE (2026-08-08/09, issue #4): virtio-gpu-pci carries id=gpu0
        // so the usb-tablet above binds its absolute coordinates to this head
        // (display=gpu0) — see the USB block and file header for the mechanism.
        // A harmless "vgabios-ramfb.bin not found" warning prints unless that
        // ROM is bundled into Resources (staged by the Run Script). The
        // "Setting device address ... Not a PCI device" note is ramfb (not a
        // PCI device) and is harmless. Do NOT drop ramfb and do NOT drop
        // virtio-gpu-pci — both single-head configurations are proven dead
        // for real use in both phases, and the swapped order is disqualified.
        args += ["-device", "ramfb"]
        args += ["-device", "virtio-gpu-pci,id=gpu0"]
        avmLog("buildQEMUArguments: display = ramfb + virtio-gpu-pci id=gpu0 (bisected pair, ramfb first — proven order; issue #4 mechanism record in header)")

        args += ["-audiodev", "spice,id=spiceaudio"]
        args += ["-device", "intel-hda"]
        args += ["-device", "hda-duplex,audiodev=spiceaudio"]

        args += [
            "-device", "virtio-serial-pci",
            "-chardev", "spicevmc,id=vdagent,name=vdagent",
            "-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
        ]

        args += ["-chardev", "socket,id=char-qmp,path=\(qmpSocketPath),server=on,wait=off"]
        args += ["-qmp", "chardev:char-qmp"]

        // DIAGNOSTIC QMP SOCKET (PERMANENT — 2026-08-09, issue #4; see file
        // header). A second, independent monitor socket the APP NEVER TOUCHES,
        // for Terminal-side ground truth (query-mice, query-spice, screendump,
        // future support diagnostics) against a live VM. The app's own QMP
        // socket is serialized against its own traffic — poking it externally
        // desyncs the protocol (proven failure class) — so external questions
        // get their own socket. server=on,wait=off exactly like the main
        // socket: QEMU listens, nothing blocks when no client connects.
        args += ["-chardev", "socket,id=char-qmp2,path=\(diagnosticQMPSocketPath),server=on,wait=off"]
        args += ["-qmp", "chardev:char-qmp2"]
        avmLog("buildQEMUArguments: diagnostic QMP socket -> \(diagnosticQMPSocketPath)")

        args += tpmArguments
        args += ["-rtc", "base=localtime,clock=host"]

        // FIRMWARE SERIAL LOG (PERMANENT — reclassified Stage C 2026-08-03,
        // previously marked "DEBUG remove before ship"): captures edk2's serial
        // output to a file inside the VM runtime dir. Kept because: it was the
        // decisive evidence in the firmware-wedge diagnosis (the only
        // instrument that sees pre-BDS state); it writes only inside the
        // AVM-owned runtime dir (no Desktop, no home-path exposure to the
        // user's visible file space); and it is the natural firmware-level
        // feed for the Stage D diagnostic bundle. Cost: one small file per VM.
        let firmwareSerialLog = runtimeDir.appendingPathComponent("firmware-serial.log").path
        args += ["-serial", "file:\(firmwareSerialLog)"]
        avmLog("buildQEMUArguments: firmware serial log -> \(firmwareSerialLog)")

        args += ["-display", "none"]
        args += ["-monitor", "none"]

        return args
    }

    private func buildTPMArguments(socketPath: String) -> [String] {
        return [
            "-chardev", "socket,id=chrtpm,path=\(socketPath)",
            "-tpmdev",  "emulator,id=tpm0,chardev=chrtpm",
            "-device",  "tpm-tis-device,tpmdev=tpm0"
        ]
    }

    // MARK: - QEMU Launch via child process

    private func launchQEMU(executableURL: URL, arguments: [String]) throws {
        avmLog("launchQEMU: executable=\(executableURL.path) argc=\(arguments.count)")
        appendConsole("AVM: Launching QEMU…\n")

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError  = errPipe
        qemuStdErrPipe = errPipe

        // QEMU's stderr flows into the SANITIZED diagnostic log (avmLog below)
        // and the in-app console — and nowhere else. STAGE C DECISION
        // (2026-08-03): the old unsanitized, never-truncated
        // ~/Desktop/qemu_stderr.log write is REMOVED. It was redundant (same
        // bytes reach the file log through the username-sanitizing choke
        // point) and it violated the trust story: AVM writes no loose files
        // to the user's Desktop.
        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let text = String(data: data, encoding: .utf8) {
                avmLog("QEMU stderr: \(text)")
                Task { @MainActor in
                    VMManager.shared?.appendConsole("QEMU: \(text)")
                }
            }
        }

        process.terminationHandler = { proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                VMManager.shared?.handleQEMUProcessExit(exitCode: code)
            }
        }

        do {
            try process.run()
        } catch {
            avmLog("launchQEMU: process.run() threw: \(error)")
            throw AVMError.qemuLaunchFailed
        }

        qemuProcess = process
        avmLog("launchQEMU: QEMU process started, pid=\(process.processIdentifier)")
        appendConsole("AVM: QEMU process started (pid \(process.processIdentifier)).\n")
    }

    func handleQEMUProcessExit(exitCode: Int32) {
        let wasRunning: Bool
        switch state {
        case .running, .paused, .starting: wasRunning = true
        default: wasRunning = false
        }

        stopBootKeypressTask()
        stopInstallWatchdog()
        cleanUp()
        qemuProcess = nil

        if exitCode == 0 {
            state = .stopped
            appendConsole("AVM: QEMU exited normally.\n")
        } else if wasRunning {
            let msg = "QEMU exited with code \(exitCode). Details are in AVM's diagnostic log."
            state = .error(msg)
            appendConsole("AVM: \(msg)\n")
            // ANNOUNCE: the VM dying mid-session is the worst silent failure
            // for a blind user — the machine just vanishes. Interrupt with
            // sound + system voice regardless of which app is frontmost.
            Announcer.shared.announce(
                "The virtual machine stopped unexpectedly.",
                tone: .failure
            )
        } else {
            state = .stopped
        }
    }

    // MARK: - Shared instance (needed for handlers)

    static weak var shared: VMManager?

    // MARK: - QMP Connection

    private func connectToQMP(socketPath: String) async throws {
        for attempt in 1 ... 50 {
            avmLog("connectToQMP: attempt \(attempt)")
            if let proc = qemuProcess, !proc.isRunning {
                avmLog("connectToQMP: QEMU process is no longer running")
                throw AVMError.qemuLaunchFailed
            }
            if connectQMPSocket(path: socketPath) { return }
            if attempt == 50 { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw AVMError.qmpConnectionFailed
    }

    private func connectQMPSocket(path: String) -> Bool {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            pathBytes.withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            Darwin.close(fd)
            return false
        }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        qmpSocket = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        qmpConnected = true
        return true
    }

    // MARK: - QMP Handshake

    private func performQMPHandshake() async throws {
        let greetingData = try await readQMPLine()
        if let json = try? JSONDecoder().decode(QMPGreeting.self, from: greetingData) {
            let v = json.QMP.version.qemu
            qemuVersion = "\(v.major).\(v.minor).\(v.micro)"
            appendConsole("AVM: Connected to QEMU \(qemuVersion) via QMP.\n")
        }
        try await sendRawQMPCommand(#"{"execute":"qmp_capabilities"}"#)
        _ = try await readQMPLine()
    }

    // MARK: - QMP Command Sending (serialized)

    /// Acquire exclusive QMP access. If another sendQMPCommand is in flight, wait
    /// until it finishes. Prevents two callers (e.g. the boot keypress task + a
    /// screendump) interleaving request/response on the single socket, which
    /// desynced the protocol and silently broke the keypress sends.
    private func qmpAcquire() async {
        while qmpBusy {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                qmpWaiters.append(c)
            }
        }
        qmpBusy = true
    }

    /// Release QMP access and wake the next waiter, if any.
    private func qmpRelease() {
        qmpBusy = false
        if !qmpWaiters.isEmpty {
            let next = qmpWaiters.removeFirst()
            next.resume()
        }
    }

    @discardableResult
    func sendQMPCommand(
        _ execute: String,
        arguments: [String: Any]?
    ) async throws -> Any? {
        guard qmpConnected, let _ = qmpSocket else {
            throw AVMError.qmpNotConnected
        }

        await qmpAcquire()
        defer { qmpRelease() }

        var commandDict: [String: Any] = ["execute": execute]
        if let args = arguments { commandDict["arguments"] = args }

        let commandData = try JSONSerialization.data(withJSONObject: commandDict)
        guard let commandString = String(data: commandData, encoding: .utf8) else {
            throw AVMError.qmpEncodingFailed
        }

        try await sendRawQMPCommand(commandString)
        let responseData = try await readQMPLine()

        if let errorResponse = try? JSONDecoder().decode(QMPError.self, from: responseData) {
            throw AVMError.qmpCommandFailed(errorResponse.error.desc)
        }

        if let returnResponse = try? JSONDecoder().decode(QMPReturn.self, from: responseData) {
            return returnResponse.returnValue.value
        }

        return nil
    }

    private func sendRawQMPCommand(_ command: String) async throws {
        guard let socket = qmpSocket else { throw AVMError.qmpNotConnected }
        let data = (command + "\n").data(using: .utf8)!
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) throws -> Void in
            guard let ptr = bytes.baseAddress else { return }
            let written = Darwin.write(socket.fileDescriptor, ptr, data.count)
            if written < 0 { throw AVMError.qmpWriteFailed }
        }
    }

    // MARK: - QMP Reading

    private func readQMPLine() async throws -> Data {
        guard let socket = qmpSocket else { throw AVMError.qmpNotConnected }
        var result = Data()
        var buf = [UInt8](repeating: 0, count: 1)
        var timeoutIterations = 0

        while true {
            let n = Darwin.read(socket.fileDescriptor, &buf, 1)
            if n > 0 {
                result.append(buf[0])
                if buf[0] == UInt8(ascii: "\n") { return result }
                timeoutIterations = 0
            } else if n == 0 {
                throw AVMError.qmpSocketClosed
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    timeoutIterations += 1
                    if timeoutIterations > 500 { throw AVMError.qmpTimeout }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } else {
                    throw AVMError.qmpReadFailed
                }
            }
        }
    }

    // MARK: - QMP Event Monitoring

    private func beginQMPEventMonitoring() {
        // Intentionally a no-op: a separate background reader on the same QMP fd
        // would race readQMPLine in sendQMPCommand and steal command responses
        // (which desynced the protocol and broke the boot keypress sends). The
        // single-reader model lives in sendQMPCommand. Async events (RESET etc.)
        // are not surfaced live; install progress is detected via disk growth.
        // (Next phase: a single dedicated QMP reader that demuxes events vs.
        // command responses would restore live event handling safely.)
        //
        // CONSEQUENCE (noted 2026-07-26): handleQMPLine below therefore has NO
        // CALLERS. It reads like live event handling and is not. Left in place
        // deliberately as the shape the future demuxing reader will use, but do
        // not mistake it for running code — same trap as KeyboardInterceptor
        // (Handoff 18 §1), caught here before it could mislead anyone.
    }

    @MainActor
    private func handleQMPLine(_ data: Data) {
        guard let event = try? JSONDecoder().decode(QMPEvent.self, from: data) else { return }
        avmLog("QMP event: \(event.event)")
        appendConsole("AVM: QMP event: \(event.event)\n")
        switch event.event {
        case "SHUTDOWN":
            appendConsole("AVM: Guest issued a shutdown.\n")
        case "RESET":
            appendConsole("AVM: VM reset (rebooting).\n")
        case "POWERDOWN":
            appendConsole("AVM: Guest requested power-down.\n")
        case "SUSPEND":
            if case .running = state { state = .paused }
        case "RESUME":
            if case .paused = state { state = .running }
        case "GUEST_PANICKED":
            state = .error("The guest OS encountered a fatal error (GUEST_PANICKED).")
        default:
            break
        }
    }

    // MARK: - Disk Image Creation

    func createDiskImage(at path: String, sizeGB: Int) async throws {
        guard let imgURL = bundledBinaryURL(named: "qemu-img") else {
            throw AVMError.binaryNotFound("qemu-img")
        }
        let process = Process()
        process.executableURL = imgURL
        process.arguments = ["create", "-f", "qcow2", path, "\(sizeGB)G"]

        if let resourcePath = Bundle.main.resourcePath {
            process.environment = ProcessInfo.processInfo.environment.merging([
                "DYLD_LIBRARY_PATH": resourcePath
            ]) { _, new in new }
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = pipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if process.terminationStatus != 0 {
            throw AVMError.diskCreationFailed(output)
        }
        appendConsole("AVM: Created disk image at \(path) (\(sizeGB) GB).\n")
    }

    // MARK: - Snapshots via QMP

    func listSnapshots() async throws -> [[String: Any]] {
        let result = try await sendQMPCommand("query-block-snapshots", arguments: nil)
        return (result as? [[String: Any]]) ?? []
    }

    func createSnapshot(name: String) async throws {
        try await sendQMPCommand(
            "blockdev-snapshot-internal-sync",
            arguments: ["device": "disk0", "name": name]
        )
        appendConsole("AVM: Snapshot \"\(name)\" created.\n")
    }

    func deleteSnapshot(name: String) async throws {
        try await sendQMPCommand(
            "blockdev-snapshot-delete-internal-sync",
            arguments: ["device": "disk0", "name": name]
        )
        appendConsole("AVM: Snapshot \"\(name)\" deleted.\n")
    }

    // MARK: - Cleanup

    private func cleanUp() {
        qmpConnected = false
        qmpReadSource?.cancel()
        qmpReadSource = nil
        try? qmpSocket?.close()
        qmpSocket = nil
        qemuStdErrPipe?.fileHandleForReading.readabilityHandler = nil
        qemuStdErrPipe = nil
        swtpmProcess?.terminate()
        swtpmProcess = nil
        // Wake any QMP waiters so they don't hang after teardown.
        qmpBusy = false
        let waiters = qmpWaiters
        qmpWaiters.removeAll()
        for w in waiters { w.resume() }
        if let dir = vmSocketDir {
            for name in ["spice.sock", "qmp.sock", "qmp2.sock", "tpm.sock"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    deinit {
        qemuProcess?.terminate()
        swtpmProcess?.terminate()
    }

    // MARK: - Console Helpers

    fileprivate func appendConsole(_ text: String) {
        consoleOutput += text
        if consoleOutput.count > 50_000
        {
            consoleOutput = String(consoleOutput.suffix(50_000))
        }
    }
}

// MARK: - Error Types

enum AVMError: LocalizedError {
    case vmAlreadyRunning
    case binaryNotFound(String)
    case qemuLaunchFailed
    case swtpmDidNotStart
    case qmpConnectionFailed
    case qmpNotConnected
    case qmpSocketClosed
    case qmpTimeout
    case qmpReadFailed
    case qmpWriteFailed
    case qmpEncodingFailed
    case qmpCommandFailed(String)
    case diskCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .vmAlreadyRunning:
            return "A VM is already running. Stop it before starting a new one."
        case .binaryNotFound(let name):
            return "\(name) was not found in AVM.app/Contents/Resources."
        case .qemuLaunchFailed:
            return "QEMU failed to start as a child process."
        case .swtpmDidNotStart:
            return "swtpm failed to create its control socket within the timeout."
        case .qmpConnectionFailed:
            return "Could not connect to QEMU's QMP socket after 10 seconds."
        case .qmpNotConnected:
            return "QMP is not connected."
        case .qmpTimeout:
            return "Timed out waiting for a QMP response."
        case .qmpSocketClosed:
            return "The QMP socket was closed unexpectedly."
        case .qmpReadFailed:
            return "A read error occurred on the QMP socket."
        case .qmpWriteFailed:
            return "A write error occurred on the QMP socket."
        case .qmpEncodingFailed:
            return "Failed to encode a QMP command as UTF-8 JSON."
        case .qmpCommandFailed(let desc):
            return "QMP command failed: \(desc)"
        case .diskCreationFailed(let output):
            return "QEMU disk image creation failed: \(output)"
        }
    }
}
