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
//   THEORY CONFIRMED (2026-08-14, two further controlled readings via qmp2,
//     in-app SPICE client connected, one variable each): SPICE grants
//     client-mode mouse without a guest agent only for a SINGLE display
//     channel; with multiple displays it requires the vdagent in the guest.
//     CONTROL (agent-mouse=on, NO agent in guest): 8 channels, two display
//       channels (type 2, ids 0+1), mouse-mode SERVER — the flag alone is
//       inert, as predicted.
//     DISCRIMINATING (vioserial ARM64 driver + vdagent 0.10.0 installed and
//       running in guest, same build): same two display channels, mouse-mode
//       CLIENT. Path A proven at mechanism level; absolute positioning then
//       verified corner-exact end-to-end (guest-sampled 0,0 to 799,599).
//     DECISION OF RECORD (2026-08-10): fix path A — ship the SPICE guest
//     agent — prototype-first. agent-mouse is ON. Path B (hide the second
//     head from SPICE's channel count) was researched and found to have no
//     supported QEMU mechanism. Falsified and closed: timing/retry, USB
//     suspend, display=gpu0 binding alone, tablet handler activation,
//     declaration order.
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
//   SILENT. On detection the watchdog announces recovery guidance: stop +
//   restart, the PROVEN recovery (the reinstall guard correctly allows a
//   reinstall because the marker is absent and the disk holds nothing worth
//   protecting), once per run. Reset (Cmd-Shift-R / resetVM) is deliberately
//   NOT in the guidance: its first wild data point (2026-08-15) FAILED to
//   recover — system_reset reached firmware (fresh screen-clear sequences on
//   serial) but no BdsDxe lines followed and the disk stayed flat 25 minutes;
//   the wedge re-formed pre-BDS. Future wild wedges can retest manually. The marker
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

// MARK: - App-wide VM activity (2026-10-25)

/// The running VM's state, for code that lives outside the window: the
/// menus, which dim what can't act right now (VoiceOver reads a dimmed
/// item as "dimmed"). VMManager is created per session and is gone between
/// sessions, so menus can't observe it; this one object outlives them.
/// VMManager writes it on every state change. .stopped when no VM has run.
@MainActor
final class VMActivity: ObservableObject {
    static let shared = VMActivity()
    @Published private(set) var state: VMRuntimeState = .stopped
    private init() {}

    /// The current machine's state (MachineSessions.makeCurrent): with
    /// several machines running, the menus act on the one in front.
    func follow(_ state: VMRuntimeState) {
        if self.state != state { self.state = state }
    }

    var isRunning: Bool { state == .running }
    var isRunningOrPaused: Bool { state == .running || state == .paused }
    /// Another machine can always start (2026-10-27, several machines at
    /// once); starting one that's already running brings it forward.
    var canStart: Bool { true }
}

// MARK: - VMManager

@MainActor
final class VMManager: ObservableObject {

    // MARK: Published State

    @Published private(set) var state: VMRuntimeState = .stopped {
        didSet {
            // Only the current machine's (MachineSessions); a manager with
            // no session (a test job) is current while nothing else is.
            if VMManager.shared === self || VMManager.shared == nil { VMActivity.shared.follow(state) }
            usbWatcherFollowState()
        }
    }

    /// True while AVM itself is starting an Ubuntu VM again after its
    /// install powered off (restartAfterInstall). SessionGate
    /// reads it so it doesn't end the session in that moment.
    @Published private(set) var restartingAfterInstall = false

    /// Set when Force Stop is pressed during that restart.
    private var restartStoppedByUser = false

    /// Whether Windows setup had finished when this VM last started
    /// (the install-complete marker). USB 2c: during setup, start-time
    /// devices wait for the SPICE agent, with no fallback.
    private(set) var installCompleteAtStart = false
    /// How a move to the virtio disk went this run (2026-10-27): "ready",
    /// "switched", "nvme" or "failed"; nil if none. For the test job.
    @Published var diskSwitchResult: String?

    /// Starts the USB hot-plug watcher when the VM reaches running and
    /// stops it at stopped or error. State is set in about a dozen places,
    /// and this one hook covers all of them. Starting, stopping, and paused
    /// leave the watcher as it is. A repeat start for the same VM, as after
    /// a pause, does nothing.
    private func usbWatcherFollowState() {
        // Every state change, for USB diagnosis (pause and resume showed
        // nothing in the log before, 2026-10-12).
        AVMLog.write("VMManager: state is now \(state)", category: "USBHotPlug")
        switch state {
        case .running:
            // Plug-ins are offered to the current machine (2026-10-27,
            // several at once); MachineSessions.makeCurrent moves the
            // watcher when another machine comes to the front.
            guard VMManager.shared === self || VMManager.shared == nil else { break }
            if let id = activeConfiguration?.id {
                USBHotPlugWatcher.shared.start(vmID: id)
                // Sends any device held while Windows was paused.
                USBPlugPrompt.shared.vmRunning()
            } else {
                AVMLog.write("VMManager: running with no active configuration; USB watcher not started", category: "USBHotPlug")
            }
        case .stopped, .error:
            // Only if it was watching for this machine.
            if let id = activeConfiguration?.id, USBHotPlugWatcher.shared.vmID != id { break }
            USBHotPlugWatcher.shared.stop(reason: state == .stopped ? "VM stopped" : "VM error")
        default:
            break
        }
    }
    @Published private(set) var qemuVersion: String = ""
    @Published private(set) var consoleOutput: String = ""

    /// Install-media pipeline progress: the SPOKEN form of the current stage
    /// ("Extracting the Windows installer. Step 1 of 6."), published so the UI
    /// can show it and announce it via VoiceOver. Empty when no build is running.
    /// (Also mirrored to the console in visible form.)
    @Published private(set) var installProgress: String = ""

    // MARK: Install status, for Speak Status (2026-10-25)

    /// When this run booted from install media; nil when the VM started an
    /// installed system. Windows Setup and Ubuntu's installer report no
    /// progress of their own, so Speak Status says what AVM does know:
    /// how long the install has run, whether Windows Setup has reached the
    /// stage the install watchdog detects, and how much the virtual disk
    /// holds so far.
    private(set) var installStartedAt: Date?

    /// When the install watchdog saw Windows Setup write its marker (Setup
    /// is underway, Windows is on the disk). nil before that.
    private(set) var setupUnderwaySince: Date?

    /// One or two sentences on the install, or nil when none is running.
    func spokenInstallStatus() -> String? {
        if case .starting = state, !installProgress.isEmpty {
            return installProgress
        }
        guard let started = installStartedAt, isRunningOrPausedState,
              let configuration = activeConfiguration else { return nil }
        let guest = configuration.guestOS.displayName
        let installer = configuration.guestOS == .windows ? "Windows Setup" : "The \(guest) installer"
        var sentences: [String] = []
        let minutes = Int(Date().timeIntervalSince(started) / 60)
        let howLong = minutes < 1 ? "less than a minute" : (minutes == 1 ? "1 minute" : "\(minutes) minutes")
        if setupUnderwaySince != nil {
            sentences.append("\(installer) is underway and has been running for \(howLong). It restarts the virtual machine a few times before it finishes.")
        } else {
            sentences.append("\(installer) has been running for \(howLong).")
        }
        if let disk = sampleDiskActivity(path: configuration.diskImagePath) {
            let gb = Double(disk.size) / 1_000_000_000
            if gb >= 1 {
                sentences.append("About \(Int(gb.rounded())) gigabytes have been written to the virtual disk so far.")
            }
        }
        return sentences.joined(separator: " ")
    }

    private var isRunningOrPausedState: Bool {
        state == .running || state == .paused
    }

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
    /// For QMP reply ids (sendQMPCommand).
    private var qmpCommandCounter = 0
    private var qmpWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: Private — working directory

    private var vmRuntimeDir: URL?
    private var vmSocketDir: URL?
    /// The QEMU guest agent's socket (GuestAgent.swift), in vmSocketDir.
    var guestAgentSocketPath: String? { vmSocketDir?.appendingPathComponent("qga.sock").path }

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
    /// Disk space, checked once a minute while running (DiskWatch.swift).
    private var diskWatchTask: Task<Void, Never>?

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
    private func reapOrphanedSwtpm(for configuration: VMConfiguration) {
        let uuid = configuration.id.uuidString

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

        if let vmDir = try? configuration.directoryURL() {
            let lockPath = vmDir
                .appendingPathComponent("tpm-state")
                .appendingPathComponent(".lock")
            if FileManager.default.fileExists(atPath: lockPath.path) {
                try? FileManager.default.removeItem(at: lockPath)
                avmLog("reapOrphanedSwtpm: removed stale TPM-state lock at \(lockPath.path)")
            }
        }
    }

    // MARK: - Directory Setup

    /// The VM's own folder (VMConfiguration.directoryURL). A folder the user
    /// chose must already exist; startVM has checked. Only the Application
    /// Support layout is created here.
    private func prepareRuntimeDirectory(for configuration: VMConfiguration) throws -> URL {
        let dir = try configuration.directoryURL()
        if !configuration.isStoredElsewhere {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        avmLog("prepareRuntimeDirectory: \(dir.path)")
        return dir
    }

    // MARK: - Secure Boot NVRAM (2026-10-25)

    /// For a Secure Boot VM with no variable store yet, makes one from UTM's
    /// edk2-arm-secure-vars.fd: Secure Boot on, Microsoft's KEK and db
    /// certificates enrolled. That template is qcow2 (64 MiB virtual), so
    /// qemu-img converts it to the raw 64 MiB store the pflash drive
    /// expects; padding it, as the plain template is padded, would keep
    /// neither the keys nor the format. Missing pieces throw, so a VM that
    /// asked for Secure Boot never boots without it unannounced.
    private func prepareSecureBootNVRAM(configuration: VMConfiguration, runtimeDir: URL) throws {
        guard configuration.usesSecureBoot else { return }
        let nvram = runtimeDir.appendingPathComponent("nvram.fd")
        guard !FileManager.default.fileExists(atPath: nvram.path) else { return }
        guard bundledBinaryURL(named: "edk2-aarch64-secure-code.fd") != nil,
              let template = bundledBinaryURL(named: "edk2-arm-secure-vars.fd") else {
            throw AVMError.binaryNotFound("Secure Boot firmware (edk2-aarch64-secure-code.fd and edk2-arm-secure-vars.fd)")
        }
        guard let qemuImg = bundledBinaryURL(named: "qemu-img") else {
            throw AVMError.binaryNotFound("qemu-img")
        }
        let convert = Process()
        convert.executableURL = qemuImg
        convert.arguments = ["convert", "-O", "raw", template.path, nvram.path]
        let errors = Pipe()
        convert.standardError = errors
        try convert.run()
        convert.waitUntilExit()
        let size = ((try? FileManager.default.attributesOfItem(atPath: nvram.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard convert.terminationStatus == 0, size == 67_108_864 else {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            try? FileManager.default.removeItem(at: nvram)
            avmLog("prepareSecureBootNVRAM: qemu-img convert failed (status \(convert.terminationStatus), size \(size)): \(detail)")
            throw AVMError.diskCreationFailed("The Secure Boot settings store could not be made. \(detail)")
        }
        avmLog("prepareSecureBootNVRAM: created Secure Boot NVRAM (Microsoft keys enrolled) from edk2-arm-secure-vars.fd")
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

        // FAILING SAFE (2026-10-26, code audit): a marker that can't be
        // read used to count as absent, which rebuilds the install media and
        // runs Setup again: on an installed machine, that erases the disk.
        // Now a disk with an installed system's worth of data on it counts
        // as installed (it boots from the disk; nothing is erased), and only
        // a near-empty one as new.
        guard let mdirURL = bundledBinaryURL(named: "mdir") else {
            let installed = diskLooksInstalled(runtimeDir: runtimeDir)
            avmLog("checkInstallCompleteMarker: WARNING — mdir not found in bundle; cannot check marker; disk \(installed ? "has data: treating as installed" : "is near empty: treating as new")")
            return installed
        }

        guard let listing = unattendListing(mdirURL: mdirURL, imgPath: imgPath), listing.status == 0 else {
            let installed = diskLooksInstalled(runtimeDir: runtimeDir)
            avmLog("checkInstallCompleteMarker: mdir failed — disk \(installed ? "has data: treating as installed" : "is near empty: treating as new")")
            return installed
        }

        let found = listing.output.uppercased().contains("AVMDONE")
        avmLog("checkInstallCompleteMarker: marker \(found ? "PRESENT" : "absent") on \(imgPath)")
        return found
    }

    /// After the marker: Windows' own steps run with no time limit, so a
    /// waiting installer would sit at "Getting ready" for good after AVM
    /// said Setup was underway (2026-10-26, code audit). The setup report
    /// is read every 5 minutes; with no first sign-in 60 minutes on, it's
    /// said once.
    private func watchForFirstSignIn(configuration: VMConfiguration, runtimeDir: URL) async {
        let since = Date()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard state == .running || state == .paused else { return }
            let report = mtools(["mtype", "-i", "IMG", "::AVMSTATUS.TXT"], runtimeDir: runtimeDir)?.output ?? ""
            if report.contains("first-sign-in-done") { return }
            if Date().timeIntervalSince(since) > 60 * 60 {
                avmLog("installWatchdog: no first sign-in 60 minutes after the marker")
                Announcer.shared.announce("Windows has been setting up for an hour without reaching its first sign-in; one of its steps may be waiting. Next: enter Windows and turn on Narrator with Control Command Return to hear where it is.", tone: .failure)
                return
            }
        }
    }

    /// More than 4 GB actually written to the disk: an installed system,
    /// not a fresh one (a new qcow2 is a few hundred kilobytes).
    private func diskLooksInstalled(runtimeDir: URL) -> Bool {
        let disk = runtimeDir.appendingPathComponent("disk.qcow2")
        let values = try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return (values?.totalFileAllocatedSize ?? 0) > 4 << 30
    }

    /// The UNATTEND volume's root listing, from the bundled mdir. nil when
    /// mdir can't be launched. Shared by the REINSTALL GUARD and the Ubuntu
    /// install-end check, so the mtools rules live in one place: inherit the
    /// environment but add MTOOLS_SKIP_CHECK and STRIP DYLD_LIBRARY_PATH (it
    /// poisons mtools — proven; never set it for pipeline child processes),
    /// and read the pipe before waiting, so a large listing can't fill the
    /// pipe and deadlock.
    /// nonisolated: the Ubuntu stall watch calls it once a minute from its
    /// background task, so the main thread never waits on mdir.
    nonisolated private func unattendListing(mdirURL: URL, imgPath: String) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = mdirURL
        process.arguments = ["-i", imgPath, "::"]
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
            AVMLog.write("unattendListing: mdir failed to launch: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// The UNATTEND volume's file names, upper-cased, for the Ubuntu
    /// marker checks (AVMDONE, AVMFAIL). nil when the volume or mdir is
    /// missing or mdir fails. nonisolated, like unattendListing; the mdir
    /// URL is passed in because bundledBinaryURL belongs to the main actor.
    nonisolated private func unattendNames(mdirURL: URL?, runtimeDir: URL) -> String? {
        let imgPath = runtimeDir.appendingPathComponent("autounattend.img").path
        guard let mdirURL, FileManager.default.fileExists(atPath: imgPath),
              let listing = unattendListing(mdirURL: mdirURL, imgPath: imgPath),
              listing.status == 0 else { return nil }
        return listing.output.uppercased()
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

        if configuration.guestOS.isLinux {
            try await ensureUbuntuInstallMedia(configuration: configuration, sourceISO: iso, runtimeDir: runtimeDir)
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

        // Screen readers first (2026-10-26), so Windows talks from its first
        // sign-in. A failed download is spoken and skipped: Narrator is
        // still there, and the install shouldn't wait on a vendor's server.
        var readerFiles: [String: URL] = [:]
        if !configuration.windowsScreenReaders.isEmpty,
           let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let cache = support
                .appendingPathComponent(AVMPaths.supportFolderName, isDirectory: true)
                .appendingPathComponent("screen-readers", isDirectory: true)
            let got = await ScreenReaderInstallers.fetchAll(configuration.windowsScreenReaders, into: cache) { [weak self] message, isProblem in
                await MainActor.run {
                    self?.installProgress = message
                    self?.appendConsole("AVM: \(message)\n")
                    Announcer.shared.announce(message, tone: isProblem ? .failure : .info)
                }
            }
            for (reader, file) in got {
                readerFiles[reader.mediaFileName] = file
            }
        }

        var input = PipelineInput(
            vmID: configuration.id,
            sourceISOPath: iso,
            runtimeDir: runtimeDir,
            // The setup wizard's edition (2026-10-25). nil (machines made
            // before the wizard asked) stays empty, so the pipeline resolves
            // and validates its default exactly as before (issue #6).
            editionName: configuration.windowsEdition?.imageName ?? "",
            productKey: configuration.windowsEdition?.genericProductKey ?? "",
            confirmWarning: { [weak self] reason in
                // Invoked OFF the main actor (pipeline contract); hop to the
                // main-actor handler, which asks the UI or defaults to proceed.
                guard let self else { return true }
                return await self.handleInstallWarning(reason)
            }
        )
        input.setupDiskID = configuration.usesVirtioDisk ? 1 : 0
        input.screenReaderInstallers = readerFiles
        // The wizard's answers (2026-10-26); a machine made before the wizard
        // asked gets the Mac's region, keyboard and time zone, and a
        // Microsoft account, as Windows would have asked for.
        let answers = WindowsSetupAnswers.load(fromVMDirectory: runtimeDir)
            ?? WindowsSetupAnswers.fromThisMac(computerName: nil)
        if let account = answers.localAccount, account.encodedPassword == nil {
            // Said here: this is thrown before the pipeline's own spoken
            // failures, and the dashboard only shows it (2026-10-26, code
            // audit).
            Announcer.shared.announce("\(configuration.name) can't install Windows: AVM no longer has the password for the account \(account.userName). Next: make a new virtual machine with the same installer.", tone: .failure)
            throw PipelineError.stageFailed(
                stage: .buildAnswerImage,
                reason: "AVM no longer has the password for the Windows account \(account.userName), which it forgets once the install media is built. Next: make a new virtual machine with the same installer."
            )
        }
        input.answers = answers
        avmLog("ensureInstallMedia: setup answers — locale \(answers.locale ?? "asked"), keyboard \(answers.inputLocale ?? "asked"), time zone \(answers.timeZone ?? "asked"), computer name \(answers.computerName == nil ? "Windows' own" : "set"), \(answers.localAccount == nil ? "Microsoft account" : "local account"), privacy \(answers.privacy.rawValue)")

        do {
            let output = try await pipeline.run(input)
            avmLog("ensureInstallMedia: pipeline complete — \(output.rebuiltISOPath)")
            WindowsSetupAnswers.forgetPassword(inVMDirectory: runtimeDir)
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

    /// Ubuntu's counterpart of the Windows build in ensureInstallMedia: the
    /// same two artifacts, the same announcements, and the same fresh NVRAM
    /// afterwards. See UbuntuInstallPipeline.swift.
    ///
    /// The completion line pre-explains the long silence that follows: the
    /// installer runs with no screen reader (there is nothing to answer), so
    /// the user is told how long it takes and that AVM will speak when it is
    /// done (UBUNTU INSTALL END, handleQEMUProcessExit).
    private func ensureUbuntuInstallMedia(configuration: VMConfiguration, sourceISO: String, runtimeDir: URL) async throws {
        avmLog("ensureUbuntuInstallMedia: building install media from \(sourceISO)")
        // The guest's own name in everything said (2026-10-26): Debian and
        // Fedora machines were told "Ubuntu".
        let guest = configuration.guestOS.displayName
        // Debian's and Fedora's netinstalls download the desktop.
        let duration = configuration.guestOS == .ubuntu ? "15 to 40" : "20 to 60"
        appendConsole("AVM: Building unattended \(guest) install media.\n")
        installProgress = "Preparing the \(guest) install media."

        let pipeline = UbuntuInstallPipeline()
        pipeline.onProgress = { [weak self] spoken, visible in
            self?.installProgress = spoken
            self?.appendConsole("AVM: \(visible)\n")
        }
        do {
            try await pipeline.run(UbuntuInstallPipeline.Input(
                vmID: configuration.id,
                vmName: configuration.name,
                sourceISOPath: sourceISO,
                runtimeDir: runtimeDir,
                diskName: configuration.usesVirtioDisk ? "vda" : "nvme0n1"
            ))
            appendConsole("AVM: Install media ready.\n")
            installProgress = "Install media ready."
            Announcer.shared.announce(
                "Install media ready. \(guest) is installing now, with no questions. This takes about \(duration) minutes, and nothing speaks until it's done. AVM will tell you when \(guest) is installed.",
                tone: .success
            )
        } catch {
            installProgress = ""
            avmLog("ensureUbuntuInstallMedia: pipeline FAILED: \(error.localizedDescription)")
            appendConsole("AVM: Install media build failed: \(error.localizedDescription)\n")
            Announcer.shared.announce(
                "Install media build failed. \(error.localizedDescription)",
                tone: .failure
            )
            throw error
        }

        let nvram = runtimeDir.appendingPathComponent("nvram.fd")
        if FileManager.default.fileExists(atPath: nvram.path) {
            try? FileManager.default.removeItem(at: nvram)
            avmLog("ensureUbuntuInstallMedia: removed stale nvram.fd for a fresh first boot")
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
            Announcer.shared.announce("The virtual machine can't start: part of AVM is missing (QEMU). Next: install AVM again.", tone: .failure)
            throw AVMError.binaryNotFound("qemu-system-aarch64")
        }
        avmLog("startVM: found QEMU executable at \(qemuURL.path)")

        // A VM stored on a drive that isn't connected (2026-10-25). Checked
        // before anything is created: the folder-making below would
        // otherwise quietly make /Volumes/<drive>/... on the Mac's own disk
        // and install a fresh Windows there.
        if configuration.storageIsMissing {
            let message = configuration.storageMissingMessage
            avmLog("startVM: storage folder missing at \(configuration.storageFolderPath ?? "?") — refusing")
            Announcer.shared.announce(message, tone: .failure)
            state = .error(message)
            throw AVMError.storageMissing(message)
        }

        reapOrphanedQEMU(for: configuration.id)
        reapOrphanedSwtpm(for: configuration)

        activeConfiguration = configuration
        state = .starting
        appendConsole("AVM: Starting VM \"\(configuration.name)\"…\n")

        // FAILED-START CLEANUP (2026-10-25, code audit): every step from
        // here can throw, and used to leave the state at .starting with
        // QEMU or swtpm possibly still running and holding the disk: the
        // menus stayed dimmed, Quit warned about a VM that wasn't there, and
        // nothing was said for swtpm or QMP failures. One catch now ends
        // whatever was launched, sets an error state, and speaks the
        // failure unless the step that failed already did.
        do {
            try await continueStart(configuration: configuration, qemuURL: qemuURL)
        } catch {
            abandonFailedStart(configuration: configuration, error: error)
            throw error
        }
    }

    /// Everything startVM does once the state is .starting.
    private func continueStart(configuration: VMConfiguration, qemuURL: URL) async throws {
        let runtimeDir = try prepareRuntimeDirectory(for: configuration)
        vmRuntimeDir = runtimeDir

        // REINSTALL GUARD: check for the install-complete marker BEFORE any
        // install-media work. If the answer file's specialize pass has written
        // AVMDONE.TAG to the UNATTEND volume, Windows is on this VM's disk —
        // skip the media build, do not attach install media, and do not start
        // the boot keypress task, so this start cannot re-enter Setup and let
        // the answer file wipe the installed disk.
        let installComplete = checkInstallCompleteMarker(configuration: configuration, runtimeDir: runtimeDir)
        // USB 2c: start-time devices wait for setup to finish (2026-10-18).
        installCompleteAtStart = installComplete
        // SAVED STATE (2026-10-27): an installed machine on the virtio disk
        // that was saved carries on from there (QEMUSavedState). No
        // restore point is taken at such a Start: its disk is mid-session.
        let resumePlan = installComplete && configuration.usesVirtioDisk
            ? await QEMUSavedState.plan(configuration: configuration, runtimeDir: runtimeDir)
            : nil
        let resuming = resumePlan != nil
        if let resumePlan { avmLog("startVM: this Start carries on from \(resumePlan.tag)") }

        if installComplete {
            avmLog("startVM: install-complete marker PRESENT — skipping media build/attach and boot keypress")
            appendConsole("AVM: \(configuration.guestOS.displayName) is already installed on this VM. Booting from the installed disk; install media will not be attached.\n")
            if configuration.guestOS.isLinux {
                removeFinishedUbuntuMedia(runtimeDir: runtimeDir)
            } else {
                let signedIn = speakSetupReport(configuration: configuration, runtimeDir: runtimeDir)
                removeFinishedWindowsMedia(runtimeDir: runtimeDir)
                if resuming {
                    avmLog("startVM: no restore point at this Start (carrying on from a saved state)")
                } else if signedIn {
                    await saveFreshInstallRestorePoint(configuration: configuration, runtimeDir: runtimeDir)
                } else {
                    await saveWeeklyRestorePoint(configuration: configuration, runtimeDir: runtimeDir)
                }
            }
        } else {
            // Build the unattended install media FIRST if this VM has an install ISO
            // and the media doesn't exist yet (six-stage pipeline; reused thereafter).
            // A failure surfaces as .error with the pipeline's actionable message
            // (and an interrupting announcement from ensureInstallMedia).
            // A failure marker left by an earlier run (Force Stop, or the
            // stall watch stopping a failed install) must not count against
            // this one. Removed here, before QEMU opens the volume.
            if configuration.guestOS.isLinux {
                clearUbuntuFailureMarker(runtimeDir: runtimeDir)
            }
            do {
                try await ensureInstallMedia(configuration: configuration, runtimeDir: runtimeDir)
            } catch {
                state = .error(error.localizedDescription)
                throw error
            }
        }

        let socketDir = try Self.privateSocketDirectory(for: configuration.id)
        vmSocketDir = socketDir

        let spicePath = socketDir.appendingPathComponent("spice.sock").path
        let qmpPath   = socketDir.appendingPathComponent("qmp.sock").path
        let qmp2Path  = socketDir.appendingPathComponent("qmp2.sock").path
        let tpmPath   = socketDir.appendingPathComponent("tpm.sock").path
        spiceSocketPath = spicePath
        avmLog("startVM: QMP socket path: \(qmpPath)")
        avmLog("startVM: diagnostic QMP socket path: \(qmp2Path)")
        avmLog("startVM: SPICE socket path: \(spicePath)")

        for path in [spicePath, qmpPath, qmp2Path, tpmPath, socketDir.appendingPathComponent("qga.sock").path] {
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

        // Secure Boot's variable store, before the arguments that use it.
        // Throws, spoken, rather than quietly booting without Secure Boot.
        do {
            try prepareSecureBootNVRAM(configuration: configuration, runtimeDir: runtimeDir)
        } catch {
            let message = "\(configuration.name) could not start with Secure Boot. Reason: \(error.localizedDescription) Next: save the diagnostic log and report the problem, or turn off Secure Boot in Settings."
            Announcer.shared.announce(message, tone: .failure)
            state = .error(message)
            throw error
        }

        var args = buildQEMUArguments(
            configuration: configuration,
            spiceSocketPath: spicePath,
            qmpSocketPath: qmpPath,
            diagnosticQMPSocketPath: qmp2Path,
            tpmArguments: tpmArgs,
            runtimeDir: runtimeDir,
            attachInstallMedia: !installComplete
        )
        // Paused until the saved state is loaded into it.
        if resuming { args.append("-S") }
        // A pending move to the virtio disk (Settings, 2026-10-27).
        args += diskSwitchArguments(configuration: configuration, runtimeDir: runtimeDir)
        avmLog("startVM: built QEMU args: \(args.joined(separator: " "))")
        // STAGE C (2026-08-03): the full argument list no longer floods the
        // in-app console — it is unsanitized (home paths) and noisy for
        // testers. The sanitized copy lives in the diagnostic log (line above).
        appendConsole("AVM: QEMU arguments recorded in the diagnostic log.\n")

        // Local Network permission first (2026-10-26), so macOS asks while
        // the Mac has the keyboard, not in the middle of Windows Setup.
        _ = await LocalNetworkAccess.ensure(guest: configuration.guestOS.displayName)

        avmLog("startVM: launching QEMU child process")
        try launchQEMU(executableURL: qemuURL, arguments: args)
        avmLog("startVM: QEMU launched, connecting to QMP")

        try await connectToQMP(socketPath: qmpPath)
        avmLog("startVM: QMP connected, performing handshake")

        try await performQMPHandshake()
        avmLog("startVM: handshake complete, VM is running")

        if let resumePlan {
            await resumeSavedState(resumePlan, configuration: configuration, runtimeDir: runtimeDir)
        }

        state = .running
        appendConsole("AVM: VM is running.\n")
        beginQMPEventMonitoring()

        startDiskWatch(configuration: configuration, runtimeDir: runtimeDir, installed: installComplete)
        if installComplete, configuration.sharesPrinters {
            Task { [weak self] in await self?.addMacPrinters(configuration: configuration) }
        }
        if installComplete, configuration.diskBusSwitch != nil {
            Task { [weak self] in await self?.continueDiskSwitch(configuration: configuration) }
        }

        // Tap Enter across the boot window to satisfy Windows' "Press any key to
        // boot from CD or DVD..." prompt (REQUIRED — see startBootKeypressTask).
        // REINSTALL GUARD: suppressed when the install-complete marker is
        // present — no install media is attached, and answering a phantom
        // prompt is the other half of the reinstall hazard.
        if installComplete {
            avmLog("startVM: boot keypress task NOT started (install-complete marker present)")
            // An installed system (2026-10-25, code audit): after AVM's
            // restart following an Ubuntu install, this is the same manager,
            // so Speak Status would still describe the finished install.
            installStartedAt = nil
            setupUnderwaySince = nil
            installProgress = ""
        } else {
            installStartedAt = Date()
            setupUnderwaySince = nil
            if configuration.guestOS.isLinux {
                // Neither applies to Ubuntu. Its boot menu starts on its own
                // after one second (UbuntuInstallPipeline.editedBootMenu), so
                // there is no "press any key" prompt. And the watchdog's
                // wedge signature (frozen frame, busy CPU, flat disk) is the
                // firmware hang at Windows' mid-install reboot; Ubuntu's
                // install never reboots, and its installer shows a still
                // splash with a flat disk for minutes at a time while it
                // downloads, which would raise a false "stuck" alarm. Ubuntu
                // reports its own end instead: a marker and a power-off,
                // for success and for failure (UBUNTU INSTALL END). What it
                // can't report is a stall, so the Ubuntu stall watch below
                // covers that.
                avmLog("startVM: Ubuntu install — no boot keypress task; Ubuntu stall watch instead of the install watchdog")
                startUbuntuStallWatch(configuration: configuration, runtimeDir: runtimeDir)
            } else {
                startBootKeypressTask()
                // INSTALL WATCHDOG: an install is in flight — watch for the wedge
                // signature until the marker appears or the VM stops.
                startInstallWatchdog(configuration: configuration, runtimeDir: runtimeDir)
            }
        }
    }

    /// Ends a start that failed part way: QEMU and swtpm, the boot and
    /// install watches, the QMP socket. A step that has already announced
    /// its failure has also set .error, so only a state still at .starting
    /// gets the generic spoken failure here.
    private func abandonFailedStart(configuration: VMConfiguration, error: Error) {
        avmLog("startVM: start failed (\(error.localizedDescription)); ending what was launched")
        stopBootKeypressTask()
        stopInstallWatchdog()
        endQEMUAndWait()
        cleanUp()
        if case .starting = state {
            let reason = error.localizedDescription
            Announcer.shared.announce(
                "\(configuration.name) could not start. Reason: \(reason) Next: try Start again. If it fails again, save the diagnostic log and report the problem.",
                tone: .failure
            )
            state = .error(reason)
        }
    }

    func stopVM() async throws {
        guard case .running = state else { return }
        state = .stopping
        do {
            try await sendQMPCommand("system_powerdown", arguments: nil)
        } catch {
            // The request never reached QEMU (2026-10-25, code audit): the
            // VM is still running, so say so, rather than sit in .stopping
            // with nothing that can leave it.
            avmLog("stopVM: system_powerdown failed (\(error.localizedDescription)); back to running")
            if case .stopping = state { state = .running }
            throw error
        }
    }

    func forceStopVM() {
        // A Force Stop while AVM restarts Ubuntu after its install is the
        // user's choice: the restart stands down (restartAfterInstall).
        if restartingAfterInstall { restartStoppedByUser = true }
        stopBootKeypressTask()
        stopInstallWatchdog()
        // DETACH + ESCALATE (2026-08-15): the VM is dead to AVM the moment a
        // force-stop is issued, so qemuProcess is nil'd IMMEDIATELY — the exit
        // handler's identity guard then ignores this generation's eventual
        // exit no matter when it fires (this pairing closes the reap-window
        // race in the logged incident). SIGTERM alone is NOT enough: a guest
        // spinning in HVF shrugged it off (avm-2026-08-15-121410.log), so a
        // detached task escalates to SIGKILL if the process survives 2s.
        let doomed = qemuProcess
        qemuProcess = nil
        doomed?.terminate()
        if let proc = doomed {
            let pid = proc.processIdentifier
            avmLog("forceStopVM: SIGTERM sent to QEMU pid \(pid); SIGKILL escalation armed (2s)")
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if proc.isRunning {
                    avmLog("forceStopVM: QEMU pid \(pid) survived SIGTERM for 2s — escalating to SIGKILL")
                    kill(pid, SIGKILL)
                } else {
                    avmLog("forceStopVM: QEMU pid \(pid) exited within the SIGTERM grace period")
                }
            }
        }
        swtpmProcess?.terminate()
        cleanUp()
        state = .stopped
        appendConsole("AVM: VM force-stopped.\n")
    }

    func pauseVM() async throws {
        guard case .running = state else { return }
        do {
            try await sendQMPCommand("stop", arguments: nil)
        } catch {
            // No answer in time (2026-10-26, code audit): QEMU may still
            // have paused, leaving AVM saying "running" over a frozen guest.
            // Asked what QEMU's state is, and it's let go again if paused.
            if let status = try? await sendQMPCommand("query-status", arguments: nil) as? [String: Any],
               (status["running"] as? Bool) == false {
                _ = try? await sendQMPCommand("cont", arguments: nil)
            }
            throw error
        }
        // Still running when the pause lands (2026-10-26, code audit): a
        // Stop chosen meanwhile set .stopping and sent the power button;
        // marking it paused over that left Stop waiting on a guest frozen
        // by the pause. The guest is let go again so it can shut down.
        guard case .running = state else {
            _ = try? await sendQMPCommand("cont", arguments: nil)
            return
        }
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
    ///    to recover. FIRST WILD DATA POINT (2026-08-15): system_reset did
    ///    NOT recover — firmware re-entered (fresh screen-clear sequences on
    ///    serial) but no BdsDxe lines followed and the disk stayed flat for
    ///    25 minutes; the wedge re-formed pre-BDS. The watchdog guidance
    ///    therefore names stop + restart only; future occurrences can retest.
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
            // A SETUP THAT JUST WAITS (2026-10-26, code audit): the wedge
            // test needs a busy CPU, so an error dialog in Windows' first
            // stage, at idle, was never said. Said once after 75 minutes
            // without the marker (the normal install reaches it in minutes).
            let watchStart = Date()
            var announcedSlow = false
            // The last frame sample is removed when the watchdog ends
            // (2026-10-25, privacy audit): it is a picture of the guest's
            // screen, and the tester guide promises frames aren't kept.
            let framePath = runtimeDir.appendingPathComponent("watchdog-screen.ppm").path
            defer { try? FileManager.default.removeItem(atPath: framePath) }

            avmLog("installWatchdog: started (20s samples; \(requiredConsecutive) consecutive frozen-frame + >=90% CPU + flat-disk samples = wedge)")

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sampleNanoseconds)
                if Task.isCancelled { return }
                guard let self else { return }

                // PAUSE (2026-10-25, code audit): a paused VM used to end the
                // watchdog for good, so after one pause and resume no wedge
                // was caught and the Setup-underway milestone never came.
                // Paused now waits, with the streak reset: a paused guest's
                // still frame and quiet disk are not a wedge.
                let vmState = await MainActor.run { self.state }
                if vmState == .paused {
                    consecutiveWedgeSamples = 0
                    previousFrame = nil
                    continue
                }
                if vmState != .running {
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
                        self.setupUnderwaySince = Date()
                        self.appendConsole("AVM: Windows Setup is underway and will restart the virtual machine a few times. This takes a while. Windows will not speak on its own — when Setup is done, enter Windows and press Control Command Return to turn on Narrator.\n")
                        Announcer.shared.announce(
                            "Windows Setup is underway and will restart the virtual machine a few times. This takes a while. Windows will not speak on its own. When Setup is done, enter Windows and press Control Command Return to turn on Narrator.",
                            tone: .success
                        )
                    }
                    await self.watchForFirstSignIn(configuration: configuration, runtimeDir: runtimeDir)
                    return
                }
                if !announcedSlow, Date().timeIntervalSince(watchStart) > 75 * 60 {
                    announcedSlow = true
                    avmLog("installWatchdog: no marker after 75 minutes")
                    await MainActor.run {
                        Announcer.shared.announce("Windows Setup hasn't reached its installing stage after 75 minutes; it's probably stopped on a screen with a question or an error. Next: enter Windows and turn on Narrator with Control Command Return to hear it, or report the problem from the Help menu.", tone: .failure)
                    }
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
                        self.appendConsole("AVM: The Windows installation appears to be stuck (screen frozen with high CPU for about 3 minutes). To recover: stop the virtual machine, then start it again — Setup will start over from the beginning.\n")
                        Announcer.shared.announce(
                            "The Windows installation appears to be stuck. To recover, stop the virtual machine, then start it again. Setup will start over from the beginning.",
                            tone: .failure
                        )
                    }
                    // Keep sampling (log-only) so the debug log records whether
                    // the wedge persists or the guest recovers on its own.
                }
            }
        }
    }

    /// UBUNTU STALL WATCH (code review, 2026-10-19). One of the first seven
    /// test installs stopped early in the live system's start-up and sat there with
    /// no disk writes and no serial output, and nothing would ever have said
    /// so: the user had been told nothing speaks until the install is done.
    /// Every minute this compares the qcow2 disk (size and modification
    /// time) and firmware-serial.log (size) with the last sample. Fifteen
    /// minutes with neither changing is announced once, with what to do. A
    /// healthy install writes the disk steadily once it is under way; its
    /// longest flat stretches (live start-up, downloads) are a few minutes.
    /// Shares installWatchdogTask, so every path that stops the watchdog
    /// (exit, Stop, Force Stop) stops this too.
    private func startUbuntuStallWatch(configuration: VMConfiguration, runtimeDir: URL) {
        stopInstallWatchdog()
        let serialLog = runtimeDir.appendingPathComponent("firmware-serial.log").path
        let mdirURL = bundledBinaryURL(named: "mdir")
        let guest = configuration.guestOS.displayName
        installWatchdogTask = Task { [weak self] in
            let sampleNanoseconds: UInt64 = 60_000_000_000   // 1 min
            let quietMinutesToAnnounce = 15
            var previous: String? = nil
            var quietMinutes = 0
            var minutesSinceFailureMarker: Int? = nil
            avmLog("ubuntuStallWatch: started (1 min samples; \(quietMinutesToAnnounce) quiet minutes = stalled)")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sampleNanoseconds)
                if Task.isCancelled { return }
                guard let self else { return }
                let current = await MainActor.run { self.state }
                switch current {
                case .running:
                    break
                case .paused:
                    // A paused VM is quiet by choice; start counting afresh.
                    quietMinutes = 0
                    previous = nil
                    continue
                default:
                    avmLog("ubuntuStallWatch: VM no longer running — standing down")
                    return
                }
                // A failed install writes AVMFAIL.TAG and powers off
                // (failureScript), and the exit announces it. If the
                // power-off doesn't happen, stop the VM here after three
                // minutes, so the failure is still announced and Start
                // works again.
                // AVMDONE wins: a marker written by a successful install is
                // never undone by an AVMFAIL written after it.
                // Off the main thread (2026-10-26, code audit): this task
                // runs on the main actor, so mdir ran there once a minute,
                // stalling VoiceOver while it did.
                let names = await Task.detached { [self] in
                    self.unattendNames(mdirURL: mdirURL, runtimeDir: runtimeDir) ?? ""
                }.value
                let failed = names.contains("AVMFAIL") && !names.contains("AVMDONE")
                if failed {
                    let minutes = (minutesSinceFailureMarker ?? -1) + 1
                    minutesSinceFailureMarker = minutes
                    if minutes == 0 { avmLog("ubuntuStallWatch: AVMFAIL.TAG appeared; waiting for the installer's power-off") }
                    if minutes >= 3 {
                        avmLog("ubuntuStallWatch: AVMFAIL.TAG present and still running after 3 minutes — stopping the VM")
                        await MainActor.run {
                            self.forceStopVM()
                            self.appendConsole("AVM: \(guest)'s installer stopped with an error. Its logs are on the virtual machine's UNATTEND disk.\n")
                            Announcer.shared.announce(
                                "\(guest)'s install stopped with an error, and AVM turned the virtual machine off. Next: press Start to try the install again. If it stops again, report it with the diagnostic log.",
                                tone: .failure
                            )
                            // AVMFAIL.TAG is NOT removed here: QEMU may still
                            // have the volume open while it exits. The next
                            // start removes it (startVM) before any install.
                        }
                        return
                    }
                    continue
                }

                let fm = FileManager.default
                let disk = try? fm.attributesOfItem(atPath: configuration.diskImagePath)
                let serial = try? fm.attributesOfItem(atPath: serialLog)
                let sample = "\((disk?[.size] as? NSNumber)?.int64Value ?? -1)/\((disk?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)/\((serial?[.size] as? NSNumber)?.int64Value ?? -1)"
                if sample == previous {
                    quietMinutes += 1
                } else {
                    if quietMinutes > 0 { avmLog("ubuntuStallWatch: activity after \(quietMinutes) quiet minutes") }
                    quietMinutes = 0
                }
                previous = sample
                if quietMinutes == quietMinutesToAnnounce {
                    avmLog("ubuntuStallWatch: STALL — no disk or serial activity for \(quietMinutes) minutes; announcing")
                    await MainActor.run {
                        self.appendConsole("AVM: \(guest)'s install seems to have stopped: nothing has changed for 15 minutes.\n")
                        Announcer.shared.announce(
                            "\(guest)'s install seems to have stopped. Nothing has changed for 15 minutes. Next: save the diagnostic log from the File menu, then stop the virtual machine and start it again.",
                            tone: .failure
                        )
                    }
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

        // swtpm splits its options on every comma and has no escape, so a
        // VM folder with a comma in its path (2026-10-25, code audit) gets
        // a comma-free link to its TPM state, in AVM's private socket
        // folder next to tpm.sock. Paths without commas are passed as is.
        var tpmStatePath = tpmStateDir.path
        if tpmStatePath.contains(",") {
            let link = URL(fileURLWithPath: socketPath).deletingLastPathComponent().appendingPathComponent("tpm-state")
            try? FileManager.default.removeItem(at: link)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tpmStateDir)
            tpmStatePath = link.path
            avmLog("launchSwtpm: TPM state path has a comma; using a link in the socket folder")
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "socket",
            "--tpmstate", "dir=\(tpmStatePath)",
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

        // SECURE BOOT (2026-10-25): UTM's Secure Boot build of the same
        // firmware. Its variable store was made by prepareSecureBootNVRAM,
        // so the padding below never runs for it.
        let firmwareName = configuration.usesSecureBoot ? "edk2-aarch64-secure-code.fd" : "edk2-aarch64-code.fd"
        if let firmware = bundledBinaryURL(named: firmwareName) {
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
                "-drive", "if=pflash,format=raw,file=\(Self.qemuOptionValue(firmware.path)),readonly=on",
                "-drive", "if=pflash,format=raw,file=\(Self.qemuOptionValue(nvramPath))"
            ]
        } else {
            appendConsole("AVM: WARNING — \(firmwareName) not found in bundle.\n")
        }

        // USB controller + INPUT DEVICES. usb-kbd is REQUIRED: without it the
        // firmware's "Press any key to boot from CD or DVD..." prompt can never
        // receive the keypress that boots the Windows installer (QMP send-key has
        // nothing to deliver the key to), and the optical boot loader times out
        // and fails to boot. usb-tablet is for pointer input. Declared BEFORE the
        // drives so bus=usb.0 resolves.
        // MOUSE MODE (issue #4 — mechanism CONFIRMED 2026-08-14; full run
        // record in the file header): SPICE holds server-mode cursor whenever
        // TWO display channels exist and no guest agent runs; with the SPICE
        // vdagent running in the guest, mouse-mode flips to CLIENT with both
        // display channels live (agent-mouse=on as of Path A, 2026-08-10 —
        // see the -spice line). display=gpu0 is KEPT: launch-proven,
        // harmless, possibly required by the shipping path (guest agent).
        // PORT MAP (explicit root ports, always): p2=8,p3=8 gives this
        // controller 8 all-speed root ports. Built-ins pin to ports 1-4:
        // kbd=1, tablet=2, install media=3, unattend=4. Ports 5-8 are the
        // reserve for hot-added passthrough devices. Why explicit: a
        // port-less device_add on a full controller makes QEMU auto-create
        // a USB 1.1 hub and coerce high-speed devices down to 12 Mb/s.
        // Root-caused 2026-09 against the ATR2100x. Never let a device
        // pick its own port.
        args += ["-device", "qemu-xhci,id=usb,p2=8,p3=8"]
        args += ["-device", "usb-kbd,bus=usb.0,port=1"]
        args += ["-device", "usb-tablet,bus=usb.0,port=2,display=gpu0"]

        // INSTALL DISK: the disk the guest installs onto. bootindex=1 so the
        // install media (bootindex=0) boots first. virtio-blk for machines
        // made since 2026-10-27, which QEMU can save while they run; NVMe
        // for older ones (QEMU 10's NVMe can't be saved). Windows carries
        // viostor from its install media for the virtio disk.
        if !configuration.diskImagePath.isEmpty {
            let disk = configuration.usesVirtioDisk
                ? "virtio-blk-pci,drive=disk0,serial=avmdisk0,bootindex=1"
                : "nvme,drive=disk0,serial=avmdisk0,bootindex=1"
            args += [
                "-drive",
                "if=none,id=disk0,file=\(Self.qemuOptionValue(configuration.diskImagePath)),format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap",
                "-device", disk
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
                    "-drive", "if=none,id=cdrom0,file=\(Self.qemuOptionValue(rebuiltISOPath)),media=cdrom,readonly=on",
                    "-device", "usb-storage,drive=cdrom0,bus=usb.0,port=3,bootindex=0,removable=on"
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
                "-drive", "if=none,id=unattend,file=\(Self.qemuOptionValue(autounattendImagePath)),format=raw,cache=writeback",
                "-device", "usb-storage,drive=unattend,bus=usb.0,port=4,removable=on"
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

        // agent-mouse=on (Path A, 2026-08-10; was off): lets the SPICE
        // vdagent drive client-mode (absolute) mouse once an agent is
        // installed and running in the guest. VERIFIED 2026-08-14: control
        // run (no agent) — mouse-mode stayed SERVER, flag inert as
        // predicted; discriminating run (vioserial + vdagent 0.10.0 running
        // in guest, same build) — mouse-mode CLIENT with both display
        // channels live. The virtio-serial/vdagent port wiring the agent
        // rides on already exists below (com.redhat.spice.0).
        // 3D GRAPHICS (2026-10-27): a Linux machine chosen for it, once
        // installed, draws with the Mac's GPU. SPICE hands CocoaSpice its
        // frames as OpenGL ES textures (ANGLE on Metal, which the QEMU
        // process is told to use), and virtio-gpu-gl-pci replaces
        // virtio-gpu-pci below, same id, so the tablet still follows it.
        let accelerated = configuration.uses3D && Self.supports3D && !attachInstallMedia
        args += [
            "-spice",
            // gl is ALWAYS given, off when not 3D: a QEMU built with OpenGL
            // (UTM's spice-display.c) reads it with no check for absence and
            // crashed at start without it (2026-10-27, AVM 0.3.0: exit 11 in
            // qemu_spice_display_early_init, every machine without 3D).
            "unix=on,addr=\(spiceSocketPath),disable-ticketing=on,agent-mouse=on,gl=\(accelerated ? "es" : "off")"
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
        args += ["-device", accelerated ? "virtio-gpu-gl-pci,id=gpu0" : "virtio-gpu-pci,id=gpu0"]
        avmLog("buildQEMUArguments: display = ramfb + \(accelerated ? "virtio-gpu-gl-pci (3D, the Mac's GPU)" : "virtio-gpu-pci") id=gpu0 (bisected pair, ramfb first — proven order; issue #4 mechanism record in header)")

        // SOUND (2026-10-27): QEMU plays the guest's sound to the Mac itself,
        // through the default output audio unit (AVM's QEMU patch
        // qemu-10.0.12-utm+coreaudio-output-unit-and-microphone.patch, which follows
        // the Mac's output and its rate, so AirPods switching to hands-free
        // mode at 24 kHz don't silence it). It used to go through SPICE and
        // spice-gtk's GStreamer pipeline. Measured key-to-speech with Orca
        // (Tools/measure-audio-latency.sh, median of 20, AirPods at 24 kHz):
        // SPICE 658 ms at best (its default pipeline lagged past 4 s); QEMU's
        // own output with 5 ms x 2 buffers 430 ms, with the sound card's
        // timer off as well 407 ms, and with 2.5 ms x 2 buffers 389 ms,
        // which is this (2.5 ms x 3 was 405). The timer paces the card's
        // transfers in 10 ms steps; off, the card moves sound as the output
        // asks for it. If speech crackles on a busy Mac, the buffers are the
        // first thing to grow. Sound no longer depends on the SPICE view, so
        // it also keeps playing while the machine's window is closed.
        // THE MICROPHONE (2026-10-27): AVM's QEMU patch gives coreaudio a
        // recording side (the Mac's default microphone, opened only while
        // the guest records). Off unless chosen in Settings: no recording
        // voice at all, so the guest's microphone is silent.
        // THE CAMERA (2026-10-27): AVM's QEMU patch adds usb-camera, a UVC
        // webcam fed by the Mac's camera, which Windows and Linux drive
        // with their own drivers. It opens the Mac's camera only while
        // something in the guest reads it. Root port 3 is the install
        // media's, free once installed; a camera is only offered then.
        if configuration.sharesCamera, !attachInstallMedia {
            args += ["-device", "usb-camera,id=camera0,bus=usb.0,port=3"]
            avmLog("buildQEMUArguments: the Mac's camera as a USB camera on port 3")
        }
        let microphone = configuration.sharesMicrophone
            ? "in.frequency=48000,in.buffer-length=10000,in.buffer-count=2"
            : "in.voices=0"
        args += ["-audiodev", "coreaudio,id=avmaudio,out.frequency=48000,out.buffer-length=2500,out.buffer-count=2,timer-period=1250,\(microphone)"]
        args += ["-device", "intel-hda"]
        args += ["-device", "hda-duplex,audiodev=avmaudio,use-timer=off"]

        args += [
            "-device", "virtio-serial-pci",
            "-chardev", "spicevmc,id=vdagent,name=vdagent",
            "-device", "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
        ]
        // QEMU guest agent (2026-10-26): its own port, for setting Windows'
        // clock after the Mac sleeps (GuestAgent.swift). Windows without the
        // agent just never opens it.
        if let qga = guestAgentSocketPath {
            args += [
                "-chardev", "socket,id=qga0,path=\(QEMUOption.value(qga)),server=on,wait=off",
                "-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"
            ]
        }
        // Shared folder (2026-10-26): the SPICE WebDAV channel, always. The
        // spice-webdavd service Windows Setup installs fails to start
        // without it, and its installer then rolls back (Error 1920, seen
        // in the install test). VMView always tells CocoaSpice the folder:
        // the chosen one, or an empty read-only one, never CocoaSpice's own
        // default of ~/Documents/Public.
        args += [
            "-chardev", "spiceport,id=webdav0,name=org.spice-space.webdav.0",
            "-device", "virtserialport,chardev=webdav0,name=org.spice-space.webdav.0"
        ]
        if let shared = configuration.sharedFolderURL {
            avmLog("buildQEMUArguments: sharing a folder (\(configuration.sharedFolderIsReadOnly ? "read only" : "read and write")): \(shared.path)")
        }

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
        // Windows keeps the hardware clock in local time; Linux keeps it in
        // UTC, and a local-time clock would put Ubuntu hours off until its
        // network time sync caught up.
        if configuration.guestOS.isLinux {
            args += ["-rtc", "base=utc,clock=host"]
        } else {
            args += ["-rtc", "base=localtime,clock=host"]
        }

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
        // ANGLE draws a 3D machine's OpenGL ES with Metal, as UTM does.
        // Without 3D nothing reads it.
        process.environment = ProcessInfo.processInfo.environment.merging(["ANGLE_DEFAULT_PLATFORM": "metal"]) { _, new in new }

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
            guard !data.isEmpty else {
                // End of file: QEMU has gone. Foundation keeps calling a
                // handler that is still set at EOF, so it clears itself
                // (2026-10-25, code audit) rather than spin until cleanUp(),
                // which may never come for a manager that was dropped.
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8) {
                avmLog("QEMU stderr: \(text)")
                Task { @MainActor [weak self] in
                    self?.appendConsole("QEMU: \(text)")
                    if text.contains("usb-camera:") { self?.announceCamera(text) }
                }
            }
        }

        // This manager's own QEMU (2026-10-27): with several machines, the
        // exit has to reach the manager that started it, not the current one.
        process.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleQEMUProcessExit(process: proc, exitCode: code)
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

    func handleQEMUProcessExit(process: Process, exitCode: Int32) {
        // IDENTITY GUARD (2026-08-15): only the CURRENT generation's exit may
        // drive state. Proven incident (avm-2026-08-15-121410.log): a wedged
        // QEMU shrugged off forceStop's SIGTERM, so its handler never fired
        // and AVM believed the VM stopped; on the NEXT start, reapOrphanedQEMU
        // SIGKILLed the leftover, which FINALLY fired the OLD handler — it saw
        // state .starting, falsely announced "stopped unexpectedly," and its
        // cleanUp() tore down the NEW start's freshly launched swtpm. This
        // guard, PAIRED with forceStopVM's detach (which nils qemuProcess the
        // moment a force-stop is issued), makes any stale generation's exit a
        // logged no-op regardless of when it arrives.
        guard process === qemuProcess else {
            avmLog("handleQEMUProcessExit: ignoring exit of STALE QEMU (pid \(process.processIdentifier), code \(exitCode)) — not the current generation; no state change")
            return
        }

        let wasRunning: Bool
        switch state {
        case .running, .paused, .starting: wasRunning = true
        default: wasRunning = false
        }
        let userStopped = (state == .stopping)
        avmLog("handleQEMUProcessExit: current QEMU (pid \(process.processIdentifier)) exited with code \(exitCode); state was \(state), wasRunning=\(wasRunning)")

        stopBootKeypressTask()
        stopInstallWatchdog()
        cleanUp()
        qemuProcess = nil

        if exitCode == 0 {
            // Decide about an Ubuntu install's end BEFORE publishing
            // .stopped: SessionGate reacts to .stopped synchronously and
            // ends the session unless restartingAfterInstall is already set
            // (seen in the in-app failure test, 2026-10-19).
            let ubuntuEnd = ubuntuInstallEnd(userStopped: userStopped)
            if case .installedRestart = ubuntuEnd {
                restartingAfterInstall = true
            }
            state = .stopped
            avmLog("handleQEMUProcessExit: clean exit — state -> stopped")
            appendConsole("AVM: QEMU exited normally.\n")
            handleUbuntuInstallEnd(ubuntuEnd)
        } else if wasRunning {
            let msg = "QEMU exited with code \(exitCode). Details are in AVM's diagnostic log."
            state = .error(msg)
            avmLog("handleQEMUProcessExit: UNEXPECTED death while running — state -> error, announcing")
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
            avmLog("handleQEMUProcessExit: nonzero exit while not running — state -> stopped, no announcement")
        }
    }

    /// How an Ubuntu VM's clean exit ends its install, if it does. The
    /// cases carry what acting on them needs, read once in
    /// ubuntuInstallEnd, so nothing can go missing between deciding and
    /// acting.
    private enum UbuntuInstallEnd {
        case notAnInstallEnd
        /// `guest`: the name to say, "Ubuntu", "Debian" or "Fedora".
        case failed(runtimeDir: URL, guest: String)
        case installedButUserStopped(guest: String)
        case installedRestart(VMConfiguration)
    }

    /// Reads the markers; changes nothing. Called before .stopped is
    /// published (see handleQEMUProcessExit).
    private func ubuntuInstallEnd(userStopped: Bool) -> UbuntuInstallEnd {
        guard let configuration = activeConfiguration,
              configuration.guestOS.isLinux,
              !installCompleteAtStart,
              let runtimeDir = vmRuntimeDir else {
            return .notAnInstallEnd
        }
        guard let names = unattendNames(mdirURL: bundledBinaryURL(named: "mdir"), runtimeDir: runtimeDir) else {
            avmLog("ubuntuInstallEnd: couldn't read the UNATTEND volume; nothing to do")
            return .notAnInstallEnd
        }
        let guest = configuration.guestOS.displayName
        if names.contains("AVMDONE") {
            return userStopped ? .installedButUserStopped(guest: guest) : .installedRestart(configuration)
        }
        return names.contains("AVMFAIL") ? .failed(runtimeDir: runtimeDir, guest: guest) : .notAnInstallEnd
    }

    /// UBUNTU INSTALL END (2026-10-19). Ubuntu's answer file ends with a
    /// power-off, never a reboot: its boot menu needs no key press, so a
    /// reboot with the install media attached could start the install
    /// again (UbuntuInstallPipeline.swift header). So when an Ubuntu VM
    /// that started mid-install exits cleanly AND the marker is now on the
    /// UNATTEND volume, the install has just finished: say so and start
    /// the VM again. That start finds the marker, attaches no install media
    /// and deletes it. A clean exit with no marker is an ordinary shutdown
    /// (or the user stopping the install), and nothing more happens.
    ///
    /// FAILURE: the answer file's error-commands write AVMFAIL.TAG and power
    /// off instead (UbuntuInstallPipeline.failureScript), because a failed
    /// installer otherwise sits on an error screen, silent, forever. That
    /// exit is announced with what to do next.
    ///
    /// A STOP THE USER ASKED FOR WINS (code review, 2026-10-19): if Stop was
    /// pressed as the install ended, the exit is the user's, so AVM says
    /// Ubuntu is installed and does not start it. Starting anyway would also
    /// leave stopGracefully, which waits to see .stopped, waiting forever.
    ///
    /// restartingAfterInstall is set before .stopped is published (see
    /// handleQEMUProcessExit) and stays set for the WHOLE restart, so no
    /// state the restart passes through (.stopped, .starting, an .error)
    /// ends the session early. SessionGate also watches the flag itself:
    /// when it clears, a session left .stopped or .error ends then, so a
    /// failed restart brings Start back however it failed (fourth review,
    /// 2026-10-19: clearing it earlier made the session depend on startVM
    /// publishing .starting before its first await).
    private func handleUbuntuInstallEnd(_ end: UbuntuInstallEnd) {
        switch end {
        case .notAnInstallEnd:
            return

        case .failed(let runtimeDir, let guest):
            avmLog("handleUbuntuInstallEnd: AVMFAIL.TAG present — \(guest)'s installer reported an error")
            appendConsole("AVM: \(guest)'s installer stopped with an error. Its logs are on the virtual machine's UNATTEND disk.\n")
            Announcer.shared.announce(
                "\(guest)'s install stopped with an error, and the virtual machine turned off. Next: press Start to try the install again. If it stops again, report it with the diagnostic log.",
                tone: .failure
            )
            clearUbuntuFailureMarker(runtimeDir: runtimeDir)

        case .installedButUserStopped(let guest):
            avmLog("handleUbuntuInstallEnd: install complete, but the user pressed Stop — not starting it")
            appendConsole("AVM: \(guest) is installed. It will start the next time you press Start.\n")
            Announcer.shared.announce(
                "\(guest) is installed. It will start the next time you press Start.",
                tone: .success
            )

        case .installedRestart(let configuration):
            restartAfterInstall(configuration: configuration)
        }
    }

    private func restartAfterInstall(configuration: VMConfiguration) {
        avmLog("restartAfterInstall: Ubuntu install complete — starting the VM again")
        let guest = configuration.guestOS.displayName
        appendConsole("AVM: \(guest) is installed. Starting it.\n")
        Announcer.shared.announce(
            "\(guest) is installed. Starting it now. Orca will speak when the desktop is ready, in about a minute. Orca's key is Caps Lock.",
            tone: .success
        )
        restartStoppedByUser = false
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startVM(configuration: configuration)
                if self.restartStoppedByUser {
                    // Force Stop landed while startVM was between steps and
                    // it carried on; honour the stop.
                    avmLog("restartAfterInstall: Force Stop during the restart — stopping the VM it started")
                    self.forceStopVM()
                }
                self.restartingAfterInstall = false
            } catch {
                if self.restartStoppedByUser {
                    // The user stopped it; the failure is theirs to have caused.
                    avmLog("restartAfterInstall: restart ended by Force Stop: \(error.localizedDescription)")
                    self.restartingAfterInstall = false
                    return
                }
                // startVM can fail at any point: before .starting, after it,
                // with swtpm or QEMU already launched. Tear down what it
                // started, then clear the flag, which lets SessionGate end
                // the session.
                if self.qemuProcess != nil || self.swtpmProcess != nil {
                    self.stopInstallWatchdog()
                    let doomed = self.qemuProcess
                    self.qemuProcess = nil
                    doomed?.terminate()
                    self.swtpmProcess?.terminate()
                    self.cleanUp()
                }
                // Keep an error already published (QEMU's exit handler sets a
                // more specific one). Announce regardless: some startVM
                // failures publish an error without speaking, and silence is
                // worse than a second announcement after a crash.
                if case .error = self.state {} else {
                    self.state = .error(error.localizedDescription)
                }
                self.restartingAfterInstall = false
                avmLog("restartAfterInstall: start FAILED: \(error.localizedDescription)")
                Announcer.shared.announce(
                    "\(guest) is installed, but AVM couldn't start it again. Reason: \(error.localizedDescription) Next: press Start.",
                    tone: .failure
                )
            }
        }
    }

    /// Remove AVMFAIL.TAG so the next start's install begins clean. The
    /// installer's logs stay on the volume beside it.
    private func clearUbuntuFailureMarker(runtimeDir: URL) {
        let imgPath = runtimeDir.appendingPathComponent("autounattend.img").path
        guard let mtoolsURL = bundledBinaryURL(named: "mtools") else { return }
        let process = Process()
        process.executableURL = mtoolsURL
        process.arguments = ["-c", "mdel", "-i", imgPath, "::AVMFAIL.TAG"]
        var env = ProcessInfo.processInfo.environment
        env["MTOOLS_SKIP_CHECK"] = "1"
        env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            avmLog("clearUbuntuFailureMarker: mtools mdel exited \(process.terminationStatus)")
        } catch {
            avmLog("clearUbuntuFailureMarker: couldn't run mtools: \(error)")
        }
    }

    /// Windows' rebuilt install DVD, about 8.5 GB per machine, is read only
    /// during setup, and once the install-complete marker exists it is never
    /// attached again (REINSTALL GUARD), so it is deleted (2026-10-26). The
    /// UNATTEND volume stays: it holds that marker. The user's own ISO is
    /// never touched.
    private func removeFinishedWindowsMedia(runtimeDir: URL) {
        removeAnswerFile(runtimeDir: runtimeDir)
        let iso = runtimeDir.appendingPathComponent("install-avm.iso")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: iso.path))?[.size] as? NSNumber else { return }
        do {
            try FileManager.default.removeItem(at: iso)
            let gb = String(format: "%.1f", size.doubleValue / 1_000_000_000)
            avmLog("removeFinishedWindowsMedia: deleted install-avm.iso (install complete), \(gb) GB freed")
            appendConsole("AVM: Windows is installed, so its \(gb) GB install disc copy was deleted.\n")
        } catch {
            avmLog("removeFinishedWindowsMedia: couldn't delete install-avm.iso: \(error.localizedDescription)")
        }
    }

    /// Runs the bundled mtools on the UNATTEND volume; nil if it couldn't.
    private func mtools(_ arguments: [String], runtimeDir: URL) -> (status: Int32, output: String)? {
        let imgPath = runtimeDir.appendingPathComponent("autounattend.img").path
        guard FileManager.default.fileExists(atPath: imgPath),
              let mtoolsURL = bundledBinaryURL(named: "mtools") else { return nil }
        let process = Process()
        process.executableURL = mtoolsURL
        process.arguments = ["-c"] + arguments.map { $0 == "IMG" ? imgPath : $0 }
        var env = ProcessInfo.processInfo.environment
        env["MTOOLS_SKIP_CHECK"] = "1"
        env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            avmLog("mtools: couldn't run: \(error)")
            return nil
        }
    }

    /// The first start after Windows is installed: say what setup installed
    /// (SetupReport.swift), then rename the report so it is said once.
    /// Returns true when the report says the first sign-in has finished.
    @discardableResult
    private func speakSetupReport(configuration: VMConfiguration, runtimeDir: URL) -> Bool {
        guard let read = mtools(["mtype", "-i", "IMG", "::AVMSTATUS.TXT"], runtimeDir: runtimeDir), read.status == 0,
              let summary = SetupReport.summary(
                reportText: read.output.replacingOccurrences(of: "\r", with: ""),
                expectsJAWS: configuration.windowsScreenReaders.contains(.jaws),
                expectsNVDA: configuration.windowsScreenReaders.contains(.nvda)) else { return false }
        avmLog("speakSetupReport: \(summary.complete ? "complete" : "incomplete"): \(read.output.split(whereSeparator: \.isNewline).joined(separator: ", "))")
        appendConsole("AVM: \(summary.message)\n")
        Announcer.shared.announce(summary.message, tone: summary.complete ? .success : .failure)
        // Retired only once the first sign-in has written its part
        // (2026-10-26, code audit): retired earlier (the user stopped
        // Windows during setup), the sign-in's lines went to a new report
        // with no specialize lines, which never parsed, so NVDA's result was
        // never said and no restore point was ever made.
        let signedIn = read.output.contains("first-sign-in-done")
        if signedIn {
            _ = mtools(["mdel", "-i", "IMG", "::AVMSTAT.OLD"], runtimeDir: runtimeDir)
            _ = mtools(["mren", "-i", "IMG", "::AVMSTATUS.TXT", "::AVMSTAT.OLD"], runtimeDir: runtimeDir)
        }
        return signedIn
    }

    /// A "Fresh install" restore point (2026-10-26): saved once, the first
    /// time the machine starts after Windows' first sign-in finished, if it
    /// has no restore points yet, so a clean Windows is minutes away rather
    /// than an hour's reinstall. The VM is stopped here, as restore points
    /// need; it is an internal disk snapshot, so it takes a moment.
    private func saveFreshInstallRestorePoint(configuration: VMConfiguration, runtimeDir: URL) async {
        guard let existing = try? await RestorePoints.list(vmDirectory: runtimeDir), existing.isEmpty else { return }
        do {
            _ = try await RestorePoints.create(vmDirectory: runtimeDir, label: "Fresh install", secureBoot: configuration.usesSecureBoot)
            appendConsole("AVM: Saved a restore point called Fresh install.\n")
            Announcer.shared.announce("AVM saved a restore point called Fresh install, so you can return to a new Windows from Settings at any time.", tone: .info)
        } catch {
            avmLog("saveFreshInstallRestorePoint: \(error.localizedDescription)")
            Announcer.shared.announce("AVM couldn't save the Fresh install restore point. Reason: \(error.localizedDescription)", tone: .failure)
        }
    }

    /// An automatic restore point, at most one a week (2026-10-26), saved
    /// as the machine starts, so a Windows update that breaks something
    /// (a screen reader, most often) is at most a week from undone. Why at
    /// Start and not "before each update": restore points need Windows
    /// stopped, and Windows installs updates while it runs and as it shuts
    /// down, so the moment before an update is never one where Windows is
    /// stopped. A point taken at Start is always from before the updates
    /// installed after it. The two newest automatic points are kept; the
    /// user's own are never touched.
    static let automaticLabelPrefix = "Automatic"

    private func saveWeeklyRestorePoint(configuration: VMConfiguration, runtimeDir: URL) async {
        guard let existing = try? await RestorePoints.list(vmDirectory: runtimeDir), !existing.isEmpty else { return }
        // Automatic points carry a marker file, not just a name (2026-10-26,
        // code audit): a user's own point named "Automatic updates test"
        // would otherwise be deleted by the weekly clean-up.
        let marker = { (point: RestorePoint) in
            runtimeDir.appendingPathComponent(RestorePoints.folderName).appendingPathComponent(point.tag).appendingPathComponent("automatic")
        }
        let automatic = existing.filter { FileManager.default.fileExists(atPath: marker($0).path) }
        if let newest = automatic.first, Date().timeIntervalSince(newest.date) < 7 * 24 * 3600 { return }
        let label = "\(Self.automaticLabelPrefix), \(Date().formatted(date: .abbreviated, time: .omitted))"
        do {
            let point = try await RestorePoints.create(vmDirectory: runtimeDir, label: label, secureBoot: configuration.usesSecureBoot)
            FileManager.default.createFile(atPath: marker(point).path, contents: nil)
            for old in automatic.dropFirst(1) {
                try? await RestorePoints.delete(old, vmDirectory: runtimeDir)
            }
            appendConsole("AVM: Saved this week's automatic restore point.\n")
            Announcer.shared.announce("AVM saved this week's automatic restore point, so this week's updates can be undone from Settings.", tone: .info)
        } catch {
            avmLog("saveWeeklyRestorePoint: \(error.localizedDescription)")
            Announcer.shared.announce("AVM couldn't save this week's automatic restore point. Reason: \(error.localizedDescription)", tone: .failure)
        }
    }

    /// The answer file on the UNATTEND volume holds the local account's
    /// password in Windows' scrambled form, and that volume stays attached,
    /// visible in Windows as a drive (2026-10-26). Windows reads it only
    /// during setup, and the REINSTALL GUARD reads AVMDONE.TAG, not it, so
    /// it is deleted once Windows is installed. Harmless when already gone.
    private func removeAnswerFile(runtimeDir: URL) {
        let imgPath = runtimeDir.appendingPathComponent("autounattend.img").path
        guard FileManager.default.fileExists(atPath: imgPath),
              let mtoolsURL = bundledBinaryURL(named: "mtools") else { return }
        let process = Process()
        process.executableURL = mtoolsURL
        process.arguments = ["-c", "mdel", "-i", imgPath, "::autounattend.xml"]
        var env = ProcessInfo.processInfo.environment
        env["MTOOLS_SKIP_CHECK"] = "1"
        env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                avmLog("removeAnswerFile: deleted autounattend.xml from the UNATTEND volume (install complete)")
            }
        } catch {
            avmLog("removeAnswerFile: couldn't run mtools: \(error)")
        }
        Self.scrubAnswerFileBytes(imagePath: imgPath)
    }

    /// A FAT delete only unlinks the file: its bytes, the encoded password
    /// among them, stayed in the image for good (2026-10-26, code audit).
    /// Every copy of the answer file's text left in the image (from
    /// "<?xml" to "</unattend>") is overwritten with zeros, in place; the
    /// rest of the volume, the marker included, is untouched.
    nonisolated static func scrubAnswerFileBytes(imagePath: String) {
        guard var data = FileManager.default.contents(atPath: imagePath) else { return }
        let start = Data("<?xml".utf8), end = Data("</unattend>".utf8)
        var scrubbed = 0
        var from = data.startIndex
        while let open = data.range(of: start, in: from..<data.endIndex) {
            let limit = min(data.endIndex, open.lowerBound + 1_048_576)
            guard let close = data.range(of: end, in: open.lowerBound..<limit) else { break }
            data.resetBytes(in: open.lowerBound..<close.upperBound)
            scrubbed += 1
            from = close.upperBound
        }
        guard scrubbed > 0 else { return }
        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: imagePath))
            try handle.write(contentsOf: data)
            try handle.close()
            AVMLog.write("AVM: removeAnswerFile — scrubbed \(scrubbed) copy(ies) of the answer file's text from the UNATTEND volume.")
        } catch {
            AVMLog.write("AVM: removeAnswerFile — couldn't scrub the UNATTEND volume: \(error.localizedDescription)")
        }
    }

    /// Ubuntu's install media is never needed once the install is complete,
    /// and install-avm.iso is the one place the account's password hash
    /// still lives (UbuntuInstallPipeline.swift header). Delete it, never
    /// the UNATTEND volume: that holds the marker the REINSTALL GUARD reads.
    private func removeFinishedUbuntuMedia(runtimeDir: URL) {
        let iso = runtimeDir.appendingPathComponent("install-avm.iso")
        guard FileManager.default.fileExists(atPath: iso.path) else { return }
        do {
            try FileManager.default.removeItem(at: iso)
            avmLog("removeFinishedUbuntuMedia: deleted install-avm.iso (install complete)")
        } catch {
            avmLog("removeFinishedUbuntuMedia: couldn't delete install-avm.iso: \(error.localizedDescription)")
        }
        UbuntuAccount.delete(fromVMDirectory: runtimeDir)
    }

    // MARK: - Shared instance (needed for handlers)

    static weak var shared: VMManager?

    /// The guest's name ("Windows" or "Ubuntu") for words spoken and shown
    /// by code that has no configuration at hand: focus lock, USB, menus.
    /// Windows when no VM has started, as before Ubuntu support.
    /// This machine's name, for announcements (2026-10-27).
    var machineName: String { activeConfiguration?.name ?? GuestOS.windows.displayName }

    static var currentGuestName: String {
        shared?.activeConfiguration?.name ?? GuestOS.windows.displayName
    }

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
    /// `timeout`: how long QEMU's answer may take. A few seconds for most
    /// commands; snapshot-save answers only once the machine's memory is
    /// written (2026-10-27: 6 s for a Windows machine timed out at 5).
    func sendQMPCommand(
        _ execute: String,
        arguments: [String: Any]?,
        timeout: TimeInterval = 5
    ) async throws -> Any? {
        guard qmpConnected, let _ = qmpSocket else {
            throw AVMError.qmpNotConnected
        }

        await qmpAcquire()
        defer { qmpRelease() }

        // REPLY IDS (2026-10-25, code audit): QEMU echoes a command's "id"
        // in its reply. Before ids, one timed-out reply stayed in the socket
        // and every later command read the previous command's reply as its
        // own, for the rest of the session (a failed USB device_add could
        // look like success). Now a line that isn't this command's reply,
        // late, half read after a timeout, or an event, is skipped.
        qmpCommandCounter += 1
        let commandID = "avm-\(qmpCommandCounter)"
        var commandDict: [String: Any] = ["execute": execute, "id": commandID]
        if let args = arguments { commandDict["arguments"] = args }

        let commandData = try JSONSerialization.data(withJSONObject: commandDict)
        guard let commandString = String(data: commandData, encoding: .utf8) else {
            throw AVMError.qmpEncodingFailed
        }

        try await sendRawQMPCommand(commandString)
        // Asynchronous events share this socket and can arrive ahead of
        // the reply: RESET after system_reset, DEVICE_DELETED after a
        // USB device_del. There is no event reader (see
        // beginQMPEventMonitoring), so skip event lines here, or the
        // next command would read the wrong line as its reply.
        // (2026-09-12, USB helper increment 1b.)
        var responseData = try await readQMPLine(timeout: timeout)
        while true {
            let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
            if let eventName = object?["event"] as? String {
                avmLog("sendQMPCommand(\(execute)): skipped event \(eventName)")
            } else if let id = object?["id"] as? String, id == commandID {
                break
            } else {
                avmLog("sendQMPCommand(\(execute)): skipped a reply that isn't for \(commandID) (\(object?["id"] as? String ?? "no id"))")
            }
            responseData = try await readQMPLine(timeout: timeout)
        }

        if let errorResponse = try? JSONDecoder().decode(QMPError.self, from: responseData) {
            throw AVMError.qmpCommandFailed(errorResponse.error.desc)
        }

        // The whole reply, nested as QEMU sent it (2026-10-27): the decoder
        // used before read one level only, so query-status's "running",
        // query-block's devices and query-jobs' jobs all came back as empty
        // placeholders, and nothing reading them could work.
        if let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let value = object["return"] {
            return value
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

    private func readQMPLine(timeout: TimeInterval = 5) async throws -> Data {
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
                    if timeoutIterations > Int(timeout * 100) { throw AVMError.qmpTimeout }
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

    // MARK: - Disk Image Growth (2026-09-26)

    /// Grows a qcow2 disk image to newSizeGB gigabytes (qemu-img's G, which
    /// is 1024^3 bytes, the same unit createDiskImage uses).
    ///
    /// GROW ONLY. qemu-img refuses to shrink an image unless --shrink is
    /// passed, and AVM never passes it. The caller also checks. Shrinking a
    /// disk under Windows destroys data.
    ///
    /// STOPPED VMS ONLY. Settings offers growth only while no VM is running.
    /// QEMU also holds a lock on the image while it runs, so qemu-img fails
    /// with a lock error instead of touching a disk in use. The lock is the
    /// backstop, not the plan.
    ///
    /// VERIFIED, NOT ASSUMED. After the resize, qemu-img info must report the
    /// new virtual size, or this throws. The caller saves the new size to the
    /// configuration only after this returns.
    ///
    /// Windows still sees the old drive C until the user extends it into the
    /// new space. AVM's answer file puts drive C last, with no recovery
    /// partition after it, so that is one PowerShell command inside Windows.
    /// AVM cannot run it from the Mac.
    func growDiskImage(at path: String, toGB newSizeGB: Int) async throws {
        guard let imgURL = bundledBinaryURL(named: "qemu-img") else {
            throw AVMError.binaryNotFound("qemu-img")
        }

        func runQemuImg(_ arguments: [String]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = imgURL
            process.arguments = arguments
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
            return (process.terminationStatus, output)
        }

        func failure(_ message: String) -> NSError {
            NSError(domain: "AVM.DiskGrowth", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }

        AVMLog.write("AVM: growDiskImage - resizing to \(newSizeGB) GB.")
        let resize = try runQemuImg(["resize", "-f", "qcow2", path, "\(newSizeGB)G"])
        guard resize.status == 0 else {
            AVMLog.write("AVM: growDiskImage - qemu-img resize FAILED (status \(resize.status)): \(resize.output)")
            throw failure("The disk could not be resized. \(resize.output)")
        }

        let info = try runQemuImg(["info", "--output=json", "-f", "qcow2", path])
        let expectedBytes = Int64(newSizeGB) * 1024 * 1024 * 1024
        var reportedBytes: Int64? = nil
        if info.status == 0,
           let data = info.output.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let size = json["virtual-size"] as? NSNumber {
            reportedBytes = size.int64Value
        }
        guard reportedBytes == expectedBytes else {
            let reported = reportedBytes.map { String($0) } ?? "nothing readable"
            AVMLog.write("AVM: growDiskImage - verification FAILED: expected \(expectedBytes) bytes, qemu-img info reported \(reported).")
            throw failure("AVM could not confirm the new disk size, so the setting was not changed.")
        }
        AVMLog.write("AVM: growDiskImage - VERIFIED at \(newSizeGB) GB.")
        appendConsole("AVM: Grew disk image at \(path) to \(newSizeGB) GB.\n")
    }

    // MARK: - USB redirection (helper increment 1b, 2026-09-12)

    /// Socket file name for one redirected root port. Lives in the VM's
    /// socket dir next to qmp.sock; QEMU listens, the root helper dials.
    // MARK: - Private socket directory (2026-10-25, security audit)

    /// /tmp/avm-<uid>/<uuid>, made owner-only, and checked every start.
    ///
    /// The sockets used to live in /tmp/avm/<uuid>, made with
    /// withIntermediateDirectories and no checks. /tmp is shared and
    /// emptied at boot, so another account on the Mac could create
    /// /tmp/avm first and then swap in its own spice.sock (receiving every
    /// keystroke), qmp.sock (full control), or usbredir-N.sock (the root
    /// USB helper connects to that one as root and streams the device to
    /// it). Now the folder carries the user's own uid, is created 0700,
    /// and AVM refuses to start, saying why, unless both levels are real
    /// directories (not symlinks), owned by this user, and closed to
    /// everyone else. The USB helper checks the same things before it
    /// connects (AVMUSBHelper/main.swift, streamSocketProblem).
    static func privateSocketDirectory(for vmID: UUID) throws -> URL {
        let uid = getuid()
        let root = "/tmp/avm-\(uid)"
        let dir = "\(root)/\(vmID.uuidString)"
        for path in [root, dir] {
            if mkdir(path, 0o700) != 0 && errno != EEXIST {
                throw AVMError.socketDirectoryUnsafe("AVM could not make its private folder \(path): \(String(cString: strerror(errno))).")
            }
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw AVMError.socketDirectoryUnsafe("AVM could not check its private folder \(path).")
            }
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            guard isDirectory, info.st_uid == uid, info.st_mode & 0o077 == 0 else {
                avmLog("privateSocketDirectory: refusing \(path): directory \(isDirectory), owner \(info.st_uid), mode \(String(info.st_mode & 0o777, radix: 8))")
                throw AVMError.socketDirectoryUnsafe("AVM's private folder \(path) belongs to someone else or can be opened by other accounts on this Mac, so AVM won't start the virtual machine with it. Next: restart the Mac, which empties that folder, then try again. If it happens again, another account on this Mac may be interfering; report it.")
            }
        }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    /// A value for a comma-separated QEMU or swtpm option (2026-10-25,
    /// code audit). Both read a comma as the start of the next option, and
    /// escape a literal one by doubling it. File paths come from where the
    /// user keeps AVM and their VMs: "/Volumes/Backup, 2TB/…" used to stop
    /// that VM ever starting, and a folder named "x,readonly=on" would
    /// quietly change the drive's options.
    static func qemuOptionValue(_ path: String) -> String {
        QEMUOption.value(path)
    }

    static func usbRedirSocketName(port: Int) -> String {
        "usbredir-\(port).sock"
    }

    /// Full path of the stream socket for `port`, or nil before startVM
    /// has created the socket directory.
    func usbRedirSocketPath(port: Int) -> String? {
        vmSocketDir?.appendingPathComponent(VMManager.usbRedirSocketName(port: port)).path
    }

    /// Adds a usbredir chardev listening on `socketPath` and a usb-redir
    /// device on root port `port` of the qemu-xhci controller. Explicit
    /// port always (handoff 47: a port-less device_add lands behind an
    /// auto-created USB 1.1 hub and a high-speed device is coerced to
    /// full speed). The JSON shapes are qmp.py's, proven live.
    /// On device_add failure the chardev is removed again.
    func attachUSBRedirect(port: Int, socketPath: String) async throws {
        let chardevID = "usbredir-\(port)"
        let deviceID = "usbredir-dev-\(port)"
        try? FileManager.default.removeItem(atPath: socketPath)
        avmLog("attachUSBRedirect: port \(port), socket \(socketPath)")
        // A previous attempt that failed between chardev-add and
        // device_add can leave the chardev behind; clear it so this
        // attempt cannot fail on a duplicate ID. Errors here are the
        // normal case (nothing to remove) and are ignored.
        if (try? await sendQMPCommand("chardev-remove", arguments: ["id": chardevID])) != nil {
            avmLog("attachUSBRedirect: removed a stale chardev \(chardevID) first")
        }
        try await sendQMPCommand("chardev-add", arguments: [
            "id": chardevID,
            "backend": [
                "type": "socket",
                "data": [
                    "addr": ["type": "unix", "data": ["path": socketPath]],
                    "server": true,
                    "wait": false
                ]
            ]
        ])
        do {
            try await sendQMPCommand("device_add", arguments: [
                "driver": "usb-redir",
                "chardev": chardevID,
                "id": deviceID,
                "bus": "usb.0",
                "port": "\(port)"
            ])
        } catch {
            avmLog("attachUSBRedirect: device_add failed (\(error)); removing chardev")
            try? await sendQMPCommand("chardev-remove", arguments: ["id": chardevID])
            throw error
        }
        avmLog("attachUSBRedirect: usb-redir device on port \(port) is listening")
    }

    /// Removes the usb-redir device from `port`, then whatever is left of
    /// its chardev, and the socket file. Call after the helper has
    /// released the device.
    ///
    /// QEMU's usb-redir device deletes its own chardev when the device
    /// is removed (learned live 2026-09-12: chardev-remove after
    /// device_del answered "not found"). The chardev-remove here is a
    /// best effort for the case where the device is already gone but
    /// the chardev is not; its failure is logged, never thrown.
    func detachUSBRedirect(port: Int) async throws {
        let chardevID = "usbredir-\(port)"
        let deviceID = "usbredir-dev-\(port)"
        avmLog("detachUSBRedirect: port \(port)")
        try await sendQMPCommand("device_del", arguments: ["id": deviceID])
        do {
            try await sendQMPCommand("chardev-remove", arguments: ["id": chardevID])
            avmLog("detachUSBRedirect: chardev \(chardevID) removed explicitly")
        } catch {
            avmLog("detachUSBRedirect: chardev \(chardevID) already gone (\(error))")
        }
        if let path = usbRedirSocketPath(port: port) {
            try? FileManager.default.removeItem(atPath: path)
        }
        avmLog("detachUSBRedirect: port \(port) cleared")
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
        diskWatchTask?.cancel()
        diskWatchTask = nil
        // The keyboard for Windows goes back to the Mac when the machine
        // stops (WindowsKeyboard.swift), and only then: it doesn't follow
        // the machine's window.
        // Only if it types into this machine (2026-10-27, several at once).
        if WindowsKeyboard.shared.target === self || WindowsKeyboard.shared.target == nil {
            WindowsKeyboard.shared.stop()
        }
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
            // Ports 5 through 8 are the free root ports on the p2=8,p3=8 map.
            let usbRedirSockets = (5...8).map { VMManager.usbRedirSocketName(port: $0) }
            for name in ["spice.sock", "qmp.sock", "qmp2.sock", "tpm.sock"] + usbRedirSockets {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    deinit {
        qemuProcess?.terminate()
        swtpmProcess?.terminate()
    }

    /// Ends QEMU and swtpm before AVM quits, and doesn't return until QEMU
    /// is gone (2026-10-25). deinit never runs at app exit, so before this a
    /// guest left running kept running after AVM closed, with no window and
    /// any USB devices still held. Same escalation as forceStopVM, but
    /// waited for here, because a detached task would die with the app:
    /// SIGTERM, then SIGKILL if QEMU is still alive after two seconds.
    func terminateForQuit() {
        stopBootKeypressTask()
        stopInstallWatchdog()
        endQEMUAndWait()
        swtpmProcess?.terminate()
        swtpmProcess = nil
        state = .stopped
    }

    /// SIGTERM, then SIGKILL if QEMU is still alive after two seconds, and
    /// back only when it is gone. qemuProcess is cleared first, so the exit
    /// handler's identity guard ignores this exit.
    private func endQEMUAndWait() {
        let doomed = qemuProcess
        qemuProcess = nil
        guard let proc = doomed, proc.isRunning else { return }
        let pid = proc.processIdentifier
        proc.terminate()
        let deadline = Date().addingTimeInterval(2)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning {
            kill(pid, SIGKILL)
            avmLog("endQEMUAndWait: QEMU pid \(pid) survived SIGTERM for 2s; sent SIGKILL")
        } else {
            avmLog("endQEMUAndWait: QEMU pid \(pid) ended")
        }
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
    case storageMissing(String)
    case socketDirectoryUnsafe(String)

    var errorDescription: String? {
        switch self {
        case .socketDirectoryUnsafe(let message):
            return message
        case .storageMissing(let message):
            return message
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

// MARK: - Install media with no VM (2026-10-26; InstallMediaJob.swift)

extension VMManager {
    /// The first start's media build, into a folder of the caller's.
    func buildInstallMedia(configuration: VMConfiguration, into folder: URL) async throws {
        try await ensureInstallMedia(configuration: configuration, runtimeDir: folder)
    }
}

// MARK: - Guest agent (2026-10-26; protocol in AVM/GuestAgent.swift)

extension VMManager {
    /// Sets Windows' clock to the Mac's. Returns true if the agent did it.
    @discardableResult
    func setGuestClock() async -> Bool {
        guard let path = guestAgentSocketPath else { return false }
        let command = GuestAgent.setTimeCommand()
        do {
            let replies = try await Task.detached { try GuestAgent.run([command], socketPath: path) }.value
            let ok = replies.first?.contains(#""return""#) == true
            AVMLog.write("AVM: GuestAgent — set the guest clock: \(ok ? "done" : replies.first ?? "no reply")")
            return ok
        } catch {
            AVMLog.write("AVM: GuestAgent — couldn't set the guest clock (\(error.localizedDescription)); Windows will correct it at its next time sync.")
            return false
        }
    }
}

// MARK: - Saved state (2026-10-27; AVM/QEMUSavedState.swift)

extension VMManager {
    /// True when the running machine can be saved: an installed machine
    /// on the virtio disk, not drawing in 3D (QEMU can't save virgl).
    var canSaveState: Bool {
        guard state == .running || state == .paused,
              let configuration = activeConfiguration,
              configuration.usesVirtioDisk, installCompleteAtStart,
              !(configuration.uses3D && Self.supports3D) else { return false }
        return true
    }

    /// True when this AVM's QEMU can draw in 3D: built from a sysroot
    /// with ANGLE and virglrenderer (Tools/build-sysroot.sh since
    /// 2026-10-27). An older sysroot has no virtio-gpu-gl-pci, and a
    /// machine asking for it wouldn't start, so 3D is neither offered nor
    /// used then.
    static let supports3D: Bool = {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(atPath: resources.appendingPathComponent("libvirglrenderer.1.dylib").path)
    }()

    /// The disk's top node, which snapshot-save and snapshot-load name.
    private func diskNodeName() async throws -> String {
        let blocks = try await sendQMPCommand("query-block", arguments: nil) as? [[String: Any]] ?? []
        guard let disk = blocks.first(where: { $0["device"] as? String == "disk0" }),
              let inserted = disk["inserted"] as? [String: Any],
              let node = inserted["node-name"] as? String else {
            throw AVMError.qmpCommandFailed("QEMU didn't say where the machine's disk is")
        }
        return node
    }

    /// Runs a QMP job (snapshot-save, -load, -delete) and waits for it to
    /// end, at most `limit`. Throws the job's own error.
    private func runQMPJob(_ command: String, id: String, arguments: [String: Any],
                           limit: Duration = .seconds(600)) async throws {
        var args = arguments
        args["job-id"] = id
        // The answer can wait for the whole save or load (see sendQMPCommand).
        _ = try await sendQMPCommand(command, arguments: args, timeout: TimeInterval(limit.components.seconds))
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while true {
            try await Task.sleep(for: .milliseconds(200))
            let jobs = try await sendQMPCommand("query-jobs", arguments: nil) as? [[String: Any]] ?? []
            guard let job = jobs.first(where: { $0["id"] as? String == id }) else {
                throw AVMError.qmpCommandFailed("QEMU lost track of the \(command) job")
            }
            if job["status"] as? String == "concluded" {
                _ = try? await sendQMPCommand("job-dismiss", arguments: ["id": id])
                if let error = job["error"] as? String { throw AVMError.qmpCommandFailed(error) }
                return
            }
            if clock.now > deadline {
                _ = try? await sendQMPCommand("job-cancel", arguments: ["id": id])
                throw AVMError.qmpCommandFailed("\(command) took longer than \(limit)")
            }
        }
    }

    /// A restore point taken while the machine runs (2026-10-27), memory
    /// and all: restoring it carries on from this moment, open apps too.
    /// The machine pauses while it's written (about a second, measured).
    func createRunningRestorePoint(label: String) async throws -> RestorePoint {
        guard canSaveState, let configuration = activeConfiguration, let runtimeDir = vmRuntimeDir else {
            throw AVMError.qmpCommandFailed("this machine can't take a restore point while it runs")
        }
        let tag = RestorePoints.newTag()
        try RestorePoints.writeFolder(vmDirectory: runtimeDir, tag: tag, label: label, secureBoot: configuration.usesSecureBoot)
        do {
            let node = try await diskNodeName()
            try await runQMPJob("snapshot-save", id: "avm-point",
                                arguments: ["tag": tag, "vmstate": node, "devices": [node]])
        } catch {
            RestorePoints.removeFolder(vmDirectory: runtimeDir, tag: tag)
            throw error
        }
        avmLog("createRunningRestorePoint: \(tag) taken with memory")
        return RestorePoint(tag: tag, label: label, date: Date(), secureBoot: configuration.usesSecureBoot, withMemory: true)
    }

    /// Saves the machine as it is and stops it; its next Start carries on
    /// from there. Returns true if it was saved. Spoken either way.
    @discardableResult
    func saveStateAndStop() async -> Bool {
        guard canSaveState, let configuration = activeConfiguration, let runtimeDir = vmRuntimeDir else { return false }
        let guest = configuration.guestOS.displayName
        // A USB device passed through was added after the start; a fresh
        // QEMU wouldn't have it to load into, so it goes back to the Mac.
        for device in USBRedirectController.shared.devices(for: self) {
            await USBRedirectController.shared.detach(device)
        }
        Announcer.shared.announce("Saving \(guest).", tone: .info)
        avmLog("saveStateAndStop: saving \(configuration.name)")
        let started = Date()
        do {
            let node = try await diskNodeName()
            try await runQMPJob("snapshot-save", id: "avm-save",
                                arguments: ["tag": QEMUSavedState.tag, "vmstate": node, "devices": [node]])
        } catch {
            avmLog("saveStateAndStop: save failed: \(error.localizedDescription)")
            // A save QEMU finished after AVM gave up would be carried on
            // over newer work at a later Start; it goes now.
            if let node = try? await diskNodeName() {
                _ = try? await sendQMPCommand("job-dismiss", arguments: ["id": "avm-save"])
                try? await runQMPJob("snapshot-delete", id: "avm-unsave",
                                     arguments: ["tag": QEMUSavedState.tag, "devices": [node]], limit: .seconds(120))
            }
            // snapshot-save lets a running machine go again by itself; a
            // paused one stays paused.
            Announcer.shared.announce("\(guest) couldn't be saved, so it's still running. Reason: \(error.localizedDescription)", tone: .failure)
            return false
        }
        avmLog("saveStateAndStop: saved in \(String(format: "%.1f", Date().timeIntervalSince(started))) s; quitting QEMU")
        try? "Saved \(Date())\n".write(to: QEMUSavedState.hint(in: runtimeDir), atomically: true, encoding: .utf8)
        state = .stopping
        _ = try? await sendQMPCommand("quit", arguments: nil)
        for _ in 0..<100 where state != .stopped {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if state != .stopped { forceStopVM() }
        Announcer.shared.announce("\(guest) is saved. Start it to carry on where you left it.", tone: .success)
        return true
    }

    /// Carries on from the saved state: QEMU was started paused (-S).
    /// Spoken. On a failed load the machine starts from its disk instead,
    /// as after a power cut, and that is said.
    func resumeSavedState(_ plan: QEMUSavedState.Plan, configuration: VMConfiguration, runtimeDir: URL) async {
        let guest = configuration.guestOS.displayName
        let fm = FileManager.default
        let marker = runtimeDir.appendingPathComponent(QEMUSavedState.loadedMarker)
        Announcer.shared.announce(plan.isSavedState ? "Resuming \(guest) where you left it." : "Resuming \(guest) at its restore point.", tone: .info)
        let started = Date()
        var node = ""
        do {
            node = try await diskNodeName()
            if plan.isSavedState { fm.createFile(atPath: marker.path, contents: nil) }
            try await runQMPJob("snapshot-load", id: "avm-load",
                                arguments: ["tag": plan.tag, "vmstate": node, "devices": [node]])
            _ = try await sendQMPCommand("cont", arguments: nil)
            avmLog("resumeSavedState: carried on in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            Announcer.shared.announce("\(guest) is running again.", tone: .success)
        } catch {
            avmLog("resumeSavedState: load failed: \(error.localizedDescription); starting from the disk")
            _ = try? await sendQMPCommand("system_reset", arguments: nil)
            _ = try? await sendQMPCommand("cont", arguments: nil)
            Announcer.shared.announce("\(guest) couldn't carry on from where it was saved, so it's starting fresh. Anything that wasn't saved inside \(guest) is lost. Reason: \(error.localizedDescription)", tone: .failure)
        }
        // A restore point stays a restore point; its note is spent.
        try? fm.removeItem(at: runtimeDir.appendingPathComponent(QEMUSavedState.resumeFile))
        // A saved state is spent either way: deleted now, so it's never
        // carried on twice.
        if plan.isSavedState, !node.isEmpty {
            do {
                try await runQMPJob("snapshot-delete", id: "avm-delete",
                                    arguments: ["tag": QEMUSavedState.tag, "devices": [node]])
                try? fm.removeItem(at: marker)
            } catch {
                avmLog("resumeSavedState: couldn't delete the saved state (\(error.localizedDescription)); the marker makes the next Start delete it")
            }
        }
        try? fm.removeItem(at: QEMUSavedState.hint(in: runtimeDir))
        // The guest's clock stopped while it was saved.
        try? await Task.sleep(for: .seconds(2))
        await setGuestClock()
    }
}

// MARK: - Moving an older machine to the virtio disk (2026-10-27)

/// Settings' Turn On Save with Open Apps, for machines made before the
/// virtio disk. Windows needs viostor installed for a device that exists
/// before it will load it at boot (MEASURED 2026-10-27: pnputil with no
/// virtio disk present stages it but makes no boot service), so the
/// pending Start attaches a small extra virtio disk (`probeFile`), and the
/// guest agent installs the driver for it. Linux needs virtio_blk in its
/// start-up image (Fedora's is made for the disk it was installed on) and
/// a fallback boot file, since the firmware's entry names the NVMe disk.
/// The first Start on the virtio disk then waits for the guest agent and
/// switches back to NVMe if it never answers.
extension VMManager {
    static let probeFile = "virtio-probe.qcow2"
    static let diskSwitchLimit: Duration = .seconds(600)

    /// The extra disk a pending Windows switch starts with.
    func diskSwitchArguments(configuration: VMConfiguration, runtimeDir: URL) -> [String] {
        let probe = runtimeDir.appendingPathComponent(Self.probeFile)
        guard configuration.diskBusSwitch == "pending", !configuration.usesVirtioDisk,
              configuration.guestOS == .windows else {
            try? FileManager.default.removeItem(at: probe)
            return []
        }
        if !FileManager.default.fileExists(atPath: probe.path), let tool = bundledBinaryURL(named: "qemu-img") {
            let process = Process()
            process.executableURL = tool
            process.arguments = ["create", "-q", "-f", "qcow2", probe.path, "64M"]
            try? process.run()
            process.waitUntilExit()
        }
        guard FileManager.default.fileExists(atPath: probe.path) else { return [] }
        return ["-drive", "if=none,id=probe,file=\(Self.qemuOptionValue(probe.path)),format=qcow2",
                "-device", "virtio-blk-pci,drive=probe,serial=avmprobe"]
    }

    /// Called once the machine runs: does the pending step, or watches the
    /// first Start on the virtio disk. Spoken; saves the configuration.
    func continueDiskSwitch(configuration: VMConfiguration) async {
        switch configuration.diskBusSwitch {
        case "pending" where !configuration.usesVirtioDisk:
            await prepareForVirtioDisk(configuration: configuration)
        case "firstBoot" where configuration.usesVirtioDisk:
            await watchFirstVirtioStart(configuration: configuration)
        default:
            break
        }
    }

    private func storeDiskSwitch(_ configuration: VMConfiguration, bus: String?, step: String?) {
        var updated = VMStore.shared?.configurations.first { $0.id == configuration.id } ?? configuration
        updated.diskBus = bus
        updated.diskBusSwitch = step
        VMStore.shared?.save(updated)
        if activeConfiguration?.id == configuration.id {
            activeConfiguration?.diskBus = bus
            activeConfiguration?.diskBusSwitch = step
        }
        diskSwitchResult = step == "firstBoot" ? "ready" : (bus == "virtio" ? "switched" : "nvme")
    }

    private func waitForGuestAgent(limit: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            guard state == .running || state == .paused || state == .starting else { return false }
            if let path = guestAgentSocketPath,
               let replies = try? await Task.detached(operation: { try GuestAgent.run([#"{"execute":"guest-ping"}"#], socketPath: path) }).value,
               replies.first?.contains(#""return""#) == true {
                return true
            }
            try? await Task.sleep(for: .seconds(3))
        }
        return false
    }

    /// One guest-agent command; its "return", or throws its error.
    private func agentCall(_ command: [String: Any], timeout: TimeInterval = 10) async throws -> Any? {
        guard let path = guestAgentSocketPath else { throw AVMError.qmpCommandFailed("no guest agent") }
        let data = try JSONSerialization.data(withJSONObject: command)
        let line = String(decoding: data, as: UTF8.self)
        let reply = try await Task.detached(operation: { try GuestAgent.run([line], socketPath: path, timeout: timeout) }).value.first ?? ""
        let object = try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        if let error = object?["error"] as? [String: Any] {
            throw AVMError.qmpCommandFailed(error["desc"] as? String ?? "the guest agent refused")
        }
        return object?["return"]
    }

    /// Runs a program in the guest, waiting at most `limit`; its output.
    private func agentRun(_ program: String, _ args: [String], limit: Duration = .seconds(300)) async throws -> String {
        let started = try await agentCall(["execute": "guest-exec",
                                           "arguments": ["path": program, "arg": args, "capture-output": true]])
        guard let pid = (started as? [String: Any])?["pid"] as? Int else {
            throw AVMError.qmpCommandFailed("the guest didn't start \(program)")
        }
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while clock.now < deadline {
            try await Task.sleep(for: .seconds(1))
            let status = try await agentCall(["execute": "guest-exec-status", "arguments": ["pid": pid]]) as? [String: Any]
            if status?["exited"] as? Bool == true {
                let out = (status?["out-data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                let err = (status?["err-data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
                return String(decoding: out + err, as: UTF8.self)
            }
        }
        throw AVMError.qmpCommandFailed("\(program) took too long in the guest")
    }

    private func agentWrite(_ file: URL, to guestPath: String) async throws {
        let data = try Data(contentsOf: file)
        guard let handle = try await agentCall(["execute": "guest-file-open", "arguments": ["path": guestPath, "mode": "wb"]]) as? Int else {
            throw AVMError.qmpCommandFailed("the guest couldn't make \(guestPath)")
        }
        _ = try await agentCall(["execute": "guest-file-write", "arguments": ["handle": handle, "buf-b64": data.base64EncodedString()]], timeout: 30)
        _ = try await agentCall(["execute": "guest-file-close", "arguments": ["handle": handle]])
    }

    private func prepareForVirtioDisk(configuration: VMConfiguration) async {
        let guest = configuration.guestOS.displayName
        guard await waitForGuestAgent(limit: Self.diskSwitchLimit) else {
            avmLog("diskSwitch: the guest agent never answered; still pending")
            Announcer.shared.announce("AVM couldn't turn on Save with open apps yet: \(guest)'s guest agent didn't answer. It tries again at the next Start.", tone: .info)
            return
        }
        do {
            if configuration.guestOS == .windows {
                guard let source = bundledBinaryURL(named: "virtio")?.appendingPathComponent("viostor") else {
                    throw AVMError.binaryNotFound("virtio/viostor")
                }
                _ = try await agentRun("cmd.exe", ["/c", "mkdir C:\\ProgramData\\AVM\\viostor"])
                for name in ["viostor.inf", "viostor.sys", "viostor.cat"] {
                    try await agentWrite(source.appendingPathComponent(name), to: "C:\\ProgramData\\AVM\\viostor\\\(name)")
                }
                let installed = try await agentRun("pnputil.exe", ["/add-driver", "C:\\ProgramData\\AVM\\viostor\\viostor.inf", "/install"])
                avmLog("diskSwitch: pnputil said: \(installed.replacingOccurrences(of: "\r\n", with: " | "))")
                let service = try await agentRun("reg.exe", ["query", "HKLM\\SYSTEM\\CurrentControlSet\\Services\\viostor", "/v", "Start"])
                guard service.contains("0x0") else {
                    throw AVMError.qmpCommandFailed("Windows didn't set the virtio disk driver to load at start-up")
                }
            } else {
                let script = """
                set -e
                if [ -d /etc/initramfs-tools ]; then
                  grep -qx virtio_blk /etc/initramfs-tools/modules || echo virtio_blk >> /etc/initramfs-tools/modules
                  update-initramfs -u -k all
                fi
                if command -v dracut >/dev/null && [ ! -d /etc/initramfs-tools ]; then
                  echo 'add_drivers+=" virtio_blk virtio_pci "' > /etc/dracut.conf.d/avm-virtio.conf
                  dracut -f --regenerate-all
                fi
                if [ -d /boot/efi/EFI ] && [ ! -e /boot/efi/EFI/BOOT/BOOTAA64.EFI ]; then
                  grub-install --target=arm64-efi --efi-directory=/boot/efi --removable --no-nvram
                fi
                echo avm-virtio-ready
                """
                let out = try await agentRun("/bin/sh", ["-c", script], limit: .seconds(600))
                avmLog("diskSwitch: setup said: \(out.suffix(500))")
                guard out.contains("avm-virtio-ready") else {
                    throw AVMError.qmpCommandFailed(String(out.suffix(200)))
                }
            }
        } catch {
            avmLog("diskSwitch: failed: \(error.localizedDescription)")
            Announcer.shared.announce("AVM couldn't turn on Save with open apps for \(guest). Nothing was changed. Reason: \(error.localizedDescription)", tone: .failure)
            diskSwitchResult = "failed"
            return
        }
        storeDiskSwitch(configuration, bus: "virtio", step: "firstBoot")
        avmLog("diskSwitch: ready; the next Start uses the virtio disk")
        Announcer.shared.announce("\(guest) is ready for Save with open apps. It turns on the next time \(guest) starts: shut it down and start it again when it suits you.", tone: .success)
    }

    private func watchFirstVirtioStart(configuration: VMConfiguration) async {
        let guest = configuration.guestOS.displayName
        if await waitForGuestAgent(limit: Self.diskSwitchLimit) {
            storeDiskSwitch(configuration, bus: "virtio", step: nil)
            avmLog("diskSwitch: first Start on the virtio disk came up")
            Announcer.shared.announce("\(guest) started with its new disk setting. Save now keeps open apps.", tone: .success)
        } else if state == .running || state == .paused {
            storeDiskSwitch(configuration, bus: nil, step: nil)
            avmLog("diskSwitch: no guest agent \(Self.diskSwitchLimit) after the first virtio Start; switched back to NVMe")
            Announcer.shared.announce("\(guest) didn't come up with its new disk setting, so AVM has switched it back. Use Force Stop, then start it again.", tone: .failure)
        }
    }
}

// MARK: - Send a file to the machine (2026-10-27)

/// Send File…: a file from the Mac goes into the machine's Downloads
/// folder through the guest agent, in pieces, so it works for any size and
/// needs no shared folder. Windows: the signed-in user's Downloads (the
/// Public one if no one is signed in). Linux: the first user's Downloads,
/// owned by them. Spoken: where it went, or why it didn't.
extension VMManager {
    /// One piece of the file per guest-agent write (base64 grows it by a
    /// third; the agent's messages stay well under its limit).
    private static let sendChunk = 1 << 20

    /// True if it arrived.
    @discardableResult
    func sendFile(_ file: URL) async -> Bool {
        let machine = machineName
        guard state == .running, let configuration = activeConfiguration else {
            Announcer.shared.announce("\(machine) isn't running, so nothing was sent.", tone: .failure)
            return false
        }
        let name = file.lastPathComponent
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else {
            Announcer.shared.announce("AVM can't read \(name), so nothing was sent.", tone: .failure)
            return false
        }
        Announcer.shared.announce("Sending \(name) to \(machine).", tone: .info)
        do {
            let windows = configuration.guestOS == .windows
            let folder: String
            var owner: String?
            if windows {
                let user = try await agentRun("powershell.exe", ["-NoProfile", "-Command",
                    "$u = (Get-CimInstance Win32_ComputerSystem).UserName; if ($u) { $p = (Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq (New-Object System.Security.Principal.NTAccount($u)).Translate([System.Security.Principal.SecurityIdentifier]).Value }).LocalPath; if ($p) { $p } }"], limit: .seconds(60))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                folder = (user.isEmpty ? "C:\\Users\\Public" : user) + "\\Downloads"
            } else {
                let home = try await agentRun("/bin/sh", ["-c", "getent passwd 1000 | cut -d: -f6,1 | tr ':' ' '"], limit: .seconds(30))
                    .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
                guard home.count == 2 else { throw AVMError.qmpCommandFailed("there's no user in \(machine) to send it to") }
                owner = String(home[0])
                folder = String(home[1]) + "/Downloads"
                _ = try await agentRun("/bin/mkdir", ["-p", folder])
            }
            let separator = windows ? "\\" : "/"
            // Never over a file already there: "name 2.ext" and so on.
            var target = folder + separator + name
            let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var n = 2
            while try await guestFileExists(target, windows: windows) {
                target = folder + separator + stem + " \(n)" + (ext.isEmpty ? "" : ".\(ext)")
                n += 1
            }

            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            guard let guestHandle = try await agentCall(["execute": "guest-file-open", "arguments": ["path": target, "mode": "wb"]]) as? Int else {
                throw AVMError.qmpCommandFailed("\(machine) couldn't make the file")
            }
            var sent: Int64 = 0
            var lastTenth: Int64 = 0
            do {
                while let data = try handle.read(upToCount: Self.sendChunk), !data.isEmpty {
                    _ = try await agentCall(["execute": "guest-file-write",
                                             "arguments": ["handle": guestHandle, "buf-b64": data.base64EncodedString()]], timeout: 60)
                    sent += Int64(data.count)
                    let tenth = size > 50_000_000 ? sent * 10 / max(size, 1) : 0
                    if tenth > lastTenth, tenth < 10 {
                        lastTenth = tenth
                        Announcer.shared.announce("Sending \(name), \(tenth * 10) percent.", tone: .info)
                    }
                }
                _ = try await agentCall(["execute": "guest-file-close", "arguments": ["handle": guestHandle]])
            } catch {
                _ = try? await agentCall(["execute": "guest-file-close", "arguments": ["handle": guestHandle]])
                throw error
            }
            if let owner {
                _ = try? await agentRun("/bin/chown", ["\(owner):\(owner)", target])
            }
            let landed = (target as NSString).lastPathComponent
            avmLog("sendFile: \(sent) bytes sent")
            Announcer.shared.announce("\(landed) is in Downloads in \(machine).", tone: .success)
            return true
        } catch {
            avmLog("sendFile: failed: \(error.localizedDescription)")
            Announcer.shared.announce("\(name) wasn't sent to \(machine). Reason: \(error.localizedDescription) Next: check \(machine) has finished starting, then try again.", tone: .failure)
            return false
        }
    }

    /// Whether a file is there: opening it for reading works only then.
    /// The same in every guest, with no shell quoting to get wrong
    /// (2026-10-27: cmd.exe's "if exist" lost the quotes in a path with
    /// spaces, and the second file overwrote the first).
    private func guestFileExists(_ path: String, windows: Bool) async throws -> Bool {
        guard let handle = try? await agentCall(["execute": "guest-file-open", "arguments": ["path": path, "mode": "r"]]) as? Int else {
            return false
        }
        _ = try? await agentCall(["execute": "guest-file-close", "arguments": ["handle": handle]])
        return true
    }
}

// MARK: - Disk space (2026-10-27; the decisions are in AVM/DiskWatch.swift)

extension VMManager {
    /// Once a minute while the machine runs: the Mac's free space, and
    /// whether QEMU paused it for a full disk; every five minutes, its own
    /// drives through the guest agent (once it's installed).
    func startDiskWatch(configuration: VMConfiguration, runtimeDir: URL, installed: Bool) {
        diskWatchTask?.cancel()
        let machine = configuration.name
        diskWatchTask = Task { [weak self] in
            var hostSpoken: Int64?
            var guestSpoken: Set<String> = []
            var minute = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                guard self.state == .running || self.state == .paused else { continue }
                minute += 1

                let free = (try? runtimeDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage ?? Int64.max
                let host = DiskWatch.hostWarning(free: free, lastSpoken: hostSpoken)
                hostSpoken = host.lastSpoken
                if host.speak != nil {
                    avmLog("diskWatch: the Mac has \(free / DiskWatch.gigabyte) GB free")
                    Announcer.shared.announce(DiskWatch.hostWords(machine: machine, free: free), tone: .info)
                }

                // QEMU stops a machine whose disk write found no space.
                if self.state == .running,
                   let status = try? await self.sendQMPCommand("query-status", arguments: nil) as? [String: Any],
                   status["status"] as? String == "io-error" {
                    avmLog("diskWatch: QEMU paused the machine with an I/O error (the Mac's disk is full)")
                    self.state = .paused
                    Announcer.shared.announce("\(machine) has paused: your Mac's disk is full. Next: free some space on your Mac, then choose Resume in \(machine)'s row.", tone: .failure)
                }

                if installed, minute % 5 == 0, self.state == .running, let path = self.guestAgentSocketPath,
                   let reply = try? await Task.detached(operation: { try GuestAgent.run([#"{"execute":"guest-get-fsinfo"}"#], socketPath: path, timeout: 10) }).value.first,
                   let json = try? JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any] {
                    let drives = DiskWatch.drives(fromFsinfo: json["return"])
                    let guest = DiskWatch.guestWarnings(drives, spoken: guestSpoken)
                    guestSpoken = guest.spoken
                    for drive in guest.speak {
                        avmLog("diskWatch: \(drive.name) is \(Int(drive.fraction * 100))% full")
                        Announcer.shared.announce(DiskWatch.guestWords(machine: machine, drive: drive), tone: .info)
                    }
                }
            }
        }
    }
}

// MARK: - The Mac's printers in the machine (2026-10-27; AVM/MacPrinters.swift)

extension VMManager {
    /// At Start, once the guest agent answers: each of the Mac's network
    /// printers is added in the machine, or its address updated. Spoken
    /// only when one is added or changed.
    func addMacPrinters(configuration: VMConfiguration) async {
        guard await waitForGuestAgent(limit: .seconds(600)) else {
            avmLog("printers: the guest agent never answered; none added")
            return
        }
        let printers = await Task.detached { MacPrinters.find() }.value
        avmLog("printers: \(printers.count) network printer(s) on the Mac")
        guard !printers.isEmpty else { return }
        let machine = configuration.name
        var added: [String] = []
        for printer in printers {
            let shown = "\(printer.name) (Mac)"
            do {
                let out: String
                if configuration.guestOS == .windows {
                    let url = printer.uri.replacingOccurrences(of: "ipp://", with: "http://")
                    let script = """
                    $n = '\(shown.replacingOccurrences(of: "'", with: "''"))'; $u = '\(url)'
                    $p = Get-Printer -Name $n -ErrorAction SilentlyContinue
                    # The address AVM gave it is kept in its comment: Windows
                    # names the port itself (WSD-...), so that can't say.
                    if ($p -and $p.Comment -eq $u) { 'same' } else {
                      if ($p) { Remove-Printer -Name $n }
                      Add-Printer -Name $n -IppURL $u -ErrorAction Stop
                      Set-Printer -Name $n -Comment $u; 'added'
                    }
                    """
                    out = try await agentRun("powershell.exe", ["-NoProfile", "-Command", script], limit: .seconds(180))
                } else {
                    let queue = "AVM-" + printer.queue.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
                    let script = """
                    q='\(queue)'; u='\(printer.uri)'
                    if lpstat -v "$q" 2>/dev/null | grep -qF "$u"; then echo same; exit 0; fi
                    lpadmin -p "$q" -D '\(shown.replacingOccurrences(of: "'", with: ""))' -E -v "$u" -m everywhere && echo added
                    lpstat -d 2>&1 | grep -q 'no system default' && lpadmin -d "$q"
                    true
                    """
                    out = try await agentRun("/bin/sh", ["-c", script], limit: .seconds(180))
                }
                avmLog("printers: \(printer.queue): \(out.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))")
                if out.contains("added") { added.append(printer.name) }
            } catch {
                avmLog("printers: \(printer.queue) not added: \(error.localizedDescription)")
            }
        }
        guard !added.isEmpty else { return }
        let list = ListFormatter.localizedString(byJoining: added)
        Announcer.shared.announce("\(machine) can print to your Mac's \(added.count == 1 ? "printer" : "printers") \(list). In \(machine) \(added.count == 1 ? "it's" : "they're") named with (Mac) at the end.", tone: .success)
    }
}

// MARK: - The Mac's camera in the machine (2026-10-27; AVM's QEMU usb-camera)

extension VMManager {
    /// Says what QEMU's camera reports: the camera light is something a
    /// VoiceOver user can't see, so on and off are spoken too.
    func announceCamera(_ text: String) {
        let machine = activeConfiguration?.name ?? "The machine"
        if text.contains("camera access was not allowed") {
            Announcer.shared.announce("\(machine) can't use your Mac's camera: macOS hasn't allowed AVM to. Turn on AVM in System Settings, Privacy and Security, Camera, then quit and reopen AVM.", tone: .failure)
        } else if text.contains("the Mac has no camera") {
            Announcer.shared.announce("\(machine) asked for the camera, but your Mac has no camera connected.", tone: .failure)
        } else if text.contains("could not be opened") {
            Announcer.shared.announce("\(machine) couldn't open your Mac's camera. Another app may be using it.", tone: .failure)
        } else if text.contains("camera is off") {
            Announcer.shared.announce("\(machine) stopped using your Mac's camera.", tone: .info)
        } else if text.contains(") is on at") {
            Announcer.shared.announce("\(machine) is using your Mac's camera.", tone: .info)
        }
    }
}
