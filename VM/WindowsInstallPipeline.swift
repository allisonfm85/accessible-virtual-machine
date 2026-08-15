// WindowsInstallPipeline.swift
// AVM — Accessible Virtual Machine
//
// Builds a modified, bootable Windows 11 ARM64 install ISO + a FAT answer-file
// image at VM-CREATE TIME, so the VM can install fully unattended and reach OOBE
// with Narrator speaking — with NO interactive prompts a blind user can't see.
//
// ALL SIX STAGES + the validation gate are implemented, PROVEN GREEN IN-APP,
// and the output is BOOT-PROVEN: an AVM-built install-avm.iso + autounattend.img
// installed Windows 11 25H2 ARM64 fully unattended from a blank qcow2 to OOBE
// (disk 0 -> 15GB, rebooted to Windows Boot Manager off the GPT disk it created,
// accessibility button present at OOBE). Requires the bundled xorriso to be
// 1.5.8.pl02 or later — 1.5.6 produces ISOs the Windows loader can't read
// (Recovery 0xc000007b), boot-proven both directions.
//
// CONCURRENCY MODEL (this replaces the old @MainActor KNOWN LIMITATION):
//   run() is marked @concurrent, which FORCES it onto the background global
//   executor regardless of the caller's actor. (Plain `nonisolated async` was
//   proven INSUFFICIENT by the in-app self-test: under this toolchain's
//   concurrency defaults, a nonisolated async function called from a main-actor
//   context STAYS on the caller's actor — the entry point logged main=true. The
//   heartbeat still ticked only because every blocking wait lives inside
//   runTool's GCD continuation; the non-tool work, including the multi-GB
//   scratch deletions, was running on the main actor. @concurrent makes the
//   off-main guarantee explicit and deterministic.) The stage bodies and
//   FileManager work follow run()'s executor. runTool additionally wraps its
//   proven synchronous wait in a continuation on a background GCD queue, so no
//   actor and no cooperative-pool thread is blocked while a child tool runs.
//   The ONLY main-actor hops are progress emission (`emit` awaits MainActor.run
//   so each announcement is delivered BEFORE its stage begins — the
//   accessibility contract) and whatever the host's `confirmWarning` closure
//   does internally. RULES THAT FOLLOW:
//     - onProgress is invoked ON the main actor; hosts can touch UI directly.
//     - confirmWarning is invoked OFF the main actor; a host closure that
//       shows UI must hop to the main actor itself (e.g. await MainActor.run).
//     - Assign onProgress before calling run(); don't reassign mid-run.
//     - defer cannot await, so ISO mounts are detached explicitly on both the
//       success and error paths instead of via defer (see the two mount sites).
//
// WHY A SEPARATE PIPELINE (proven manually end-to-end; see AVM-HANDOFF series):
//   - Win11 25H2's "ConX" setup (SetupPrep.exe) silently IGNORES autounattend.xml.
//     The fix is to force the LEGACY setup.exe /legacy path by injecting a
//     winpeshl.ini into boot.wim image 2. That injection requires rebuilding the
//     ISO, which requires the whole pipeline.
//   - virtio NIC/balloon drivers must be dropped into $WinPEDriver$ on the media
//     so they auto-install during windowsPE (no network-driver prompt at OOBE,
//     and fast paravirtualized devices from first boot).
//   - The answer file carries the LabConfig hardware-check bypass (windowsPE pass),
//     edition select + generic product key, disk wipe/partition, and stops at OOBE.
//
// PATHS WITH SPACES (proven by in-app failure + isolated test): the pipeline's
//   scratch dir lives under "Application Support" — a path WITH A SPACE. Any
//   tool that word-splits an argument's CONTENTS (wimlib's --command string
//   splits on whitespace) will break on such paths unless they are quoted
//   INSIDE the string. Terminal proofs in /tmp never catch this. Rule: any
//   pipeline path embedded inside a tool's command-string argument must be
//   double-quoted; paths passed as their own argv elements are safe (Process
//   passes them verbatim, no shell).
//
// READING THE WINDOWS ISO — UDF, NOT xorriso (proven by test):
//   Windows 11 ISOs are UDF-PRIMARY. The ISO 9660 / Joliet trees are near-empty
//   stubs (only README.TXT + boot bits); the real install tree (sources/,
//   boot.wim, the ~6.6GB install.wim) lives ONLY in the UDF filesystem. xorriso
//   (libisofs: RockRidge/Joliet/ISO 9660) CANNOT read UDF — it sees an almost
//   empty root, and any attempt to extract the 7GB install.wim fails with "Value
//   too large to be stored in data type" (a 32-bit ISO 9660 size-field overflow,
//   NOT a flag problem). macOS mounts UDF natively, so we READ the ISO via
//   `hdiutil attach` + copy it out with `ditto`, and wimlib-imagex reads
//   install.wim straight off the mount. xorriso is OUTPUT-SIDE ONLY: el-torito
//   parse + ISO rebuild. BUT: xorriso CAN read the el-torito boot record and raw
//   bytes off the original ISO file (that's not the UDF tree) — Stage 5 depends
//   on exactly that, and it's proven on the real ISO (Ldsiz 3360, LBA 531).
//
// STAGE 5 — REBUILD (appended-partition method; proven in Terminal AND in-app,
// full 7.4GB+ rebuilds with verified output, and the output BOOT-PROVEN):
//   - Parse `-report_el_torito plain` off the ORIGINAL ISO. The "El Torito boot
//     img" row's LAST TWO whitespace-delimited fields are Ldsiz then LBA (in
//     that order). Parse by trailing fields keyed on the row prefix — NEVER by
//     column position (the rebuilt ISO's LBA is 7 digits, shifting columns).
//     Volume id is between the single quotes on its line. NEVER use the
//     "Roughly estimated EFI image size" NOTE — it's a bogus end-of-medium
//     artifact.
//   - Units are MIXED: LBA is in 2048-byte sectors, Ldsiz in 512-byte blocks.
//     dd bs=512 skip=(LBA*2048/512) count=Ldsiz. The result MUST be exactly
//     Ldsiz*512 bytes (1,720,320 on the reference ISO) and FAT — ~8GB means the
//     count was wrong and you grabbed the whole ISO.
//   - Rebuild: xorriso -as mkisofs -iso-level 3 -V <volid> -J -joliet-long
//     -append_partition 2 0xef <efiboot.img> -appended_part_as_gpt -e
//     --interval:appended_partition_2:all:: -no-emul-boot -o <out> <tree>.
//     The naive `-boot_image any replay` method produces Ldsiz 0, which our
//     edk2 firmware will NOT boot (falls to UEFI shell) — never use it.
//   - JOLIET (-J -joliet-long) is REQUIRED — DO NOT REMOVE (root-caused
//     2026-07-08, fix guest-proven 2026-07-11): `$` is not a legal character in
//     the plain ISO 9660 namespace, so without Joliet the rebuilt ISO stores
//     "$WinPEDriver$" MANGLED as "_WINPEDRIVER_". Windows CDFS reads the plain
//     9660 namespace when no Joliet is present, so Setup's literal
//     "$WinPEDriver$" scan MISSES the folder entirely — no windowsPE driver
//     install, and OOBE demands a network driver a blind user can't provide.
//     With Joliet, the name is carried verbatim in the Joliet (UCS-2)
//     namespace, which Windows PREFERS over 9660; the still-mangled 9660 name
//     is then harmless. Host-side tools (xorriso's own listing, even its
//     -rockridge off view) display Rock Ridge names and CANNOT see the
//     mangling — the guest's setupapi.dev.log was the decisive evidence.
//     Verified on the fixed ISO: the UTF-16BE byte sequence for $WinPEDriver$
//     is present in the Joliet directory records, and a fresh install passed
//     OOBE networking with NO driver prompt. Side effect: Joliet ISOs may
//     become hdiutil-mountable — fine, but do NOT re-adopt mountability as a
//     rebuild-health signal (ledger: it was closed as a non-signal).
//   - Postcondition: re-report el-torito on the OUTPUT; Ldsiz must be non-zero.
//     NOTE: non-zero Ldsiz is NECESSARY BUT INSUFFICIENT for bootability — the
//     bad 1.5.6 ISOs passed it. The real mitigation is the PINNED xorriso
//     version (1.5.8+), not a stronger postcondition.
//
// TOOLS (bundled, signed, exec-over-CLI via Process — same pattern as QEMU/swtpm;
// licensing is aggregate/GPLv2-clean because they're separate child processes):
//   - hdiutil       : (macOS built-in) mount the UDF ISO read-only to read/copy it
//   - ditto         : (macOS built-in) robust recursive copy of the mounted tree
//   - dd            : (macOS built-in) extract the EFI boot image by byte offsets
//   - wimlib-imagex : read editions/arch; inject winpeshl.ini into boot.wim image 2
//   - mtools        : mformat/mcopy/mdir the FAT answer image (dispatch by argv[0])
//   - xorriso       : parse el-torito; rebuild the bootable output ISO (1.5.8+)
//
// DYLD_LIBRARY_PATH — DO NOT SET IT for pipeline child processes (proven by
//   crash + test): every bundled tool's dependencies are rewritten to
//   @loader_path by the Run Script, which dyld resolves relative to the binary
//   itself with NO environment help. Setting DYLD_LIBRARY_PATH=Resources makes
//   dyld prefer bundle dylibs BY LEAF NAME over a binary's real deps — the
//   sysroot's libiconv.2.dylib then shadows the system /usr/lib/libiconv mtools
//   links, it lacks the _iconv symbol, and mtools dies with SIGABRT (Process
//   reports terminationStatus 6 = the signal number). System binaries
//   (hdiutil/ditto/chmod/dd) must never have sysroot libraries injected either.
//   runTool's extraEnvironment exists for any future per-call env needs.
//
// VIRTIO DRIVERS (Stage 3): bundled in Resources/virtio/<driver>/ by the Run
//   Script (inert data — NOT signed/path-rewritten; re-signing the Red Hat .cat
//   would break Win11 ARM driver-signature validation). The proven set is NetKVM
//   (a QUAD — netkvm.inf's CopyFiles/SourceDisksFiles pull in netkvmp.exe at
//   driver-install time, so it's .inf/.sys/.cat/.exe, not just the triple) and
//   Balloon (.inf/.sys/.cat). Setup auto-installs anything under a literal
//   "$WinPEDriver$" folder at the media root during windowsPE.
//
// ANSWER FILE (Stage 4) + EDITION RESOLUTION (2026-08-09, issue #6): the
//   canonical template is a bundled resource (Resources/autounattend.xml)
//   carrying two literal placeholder tokens — AVM_EDITION_NAME (the /IMAGE/NAME
//   value) and AVM_PRODUCT_KEY (the generic edition-select key in UserData).
//   The effective edition/key pair is resolved EXACTLY ONCE, at the top of
//   run(), BEFORE validation (empty PipelineInput values fall back to the
//   Windows 11 Pro defaults there and ONLY there — the edition-picker UI
//   doesn't exist yet). The resolved pair, with a wasDefaulted provenance
//   flag, flows to BOTH the validation gate and Stage 4, so validation and the
//   answer file can never disagree about which edition is in play (one source
//   of truth, same principle as VMView's shared aspect-fit scale). The gate:
//   a USER-CHOSEN edition missing from the disc warns and may proceed (the
//   disc may name it slightly differently); a DEFAULTED edition missing from
//   the disc HARD-STOPS with a spoken error naming the disc's editions —
//   root-caused from issue #6, where an IoT Enterprise LTSC ISO (no
//   "Windows 11 Pro" image) sailed through validation and Windows Setup hung
//   silently on an edition that didn't exist. Stage 4 substitutes from the
//   resolved pair and carries a BACKSTOP membership assert (defaulted edition
//   must be on the disc's list) that should be unreachable — it exists to
//   catch any future call path that skips the gate. Stage 4 then writes the
//   filled XML to scratch and builds a 2MB FAT12 answer image with
//   mformat/mcopy (proven geometry -T 4096 -h 16 -s 32; label UNATTEND).
//   Generic product keys select the edition only — they do NOT activate
//   Windows and store nothing sensitive.
//
// ACCESSIBILITY (non-negotiable): the pipeline is a potentially multi-minute
// async sequence. A silent hang is indistinguishable from a freeze for a blind
// user, so EVERY stage emits a labeled progress event (spoken + visible) before
// it begins work — and with this concurrency model those events can actually
// be announced WHILE a stage runs, because the main thread is never blocked.
// Failures map to spoken, specific, ACTIONABLE messages that name the stage and
// a likely cause — never a bare "VM creation failed."

import Foundation

// MARK: - Pipeline Logging

/// Forwards to AVMLog, the single file logger (see AVMLog.swift), tagging every
/// line with the `[pipeline]` category so pipeline lines stay distinguishable
/// from VMManager's.
///
/// CHANGED 2026-07-26: this function previously owned its own copy of the
/// open/seek/write/close code and its own path constant pointing at
/// ~/Desktop/avm_debug.log — a byte-identical twin of VMManager's avmLog,
/// writing to the SAME file.
///
/// THAT WAS A REAL RACE, and this file is the half that made it real. Each
/// write did open -> seekToEndOfFile -> write -> close, with no coordination.
/// VMManager is @MainActor; this pipeline is @concurrent, and pipelineLog is
/// called from inside runTool's DispatchQueue.global closure. During a VM
/// create both were therefore live SIMULTANEOUSLY from different threads, and
/// two seeks landing on the same end offset before either write meant one line
/// silently overwrote the other. A lost log line looks like a thing that never
/// happened — the worst failure mode for a diagnostic. Both writers now go
/// through AVMLog's single serial queue, so ordering is guaranteed and nothing
/// is dropped.
///
/// The `[pipeline]` prefix is now passed as a CATEGORY rather than interpolated
/// into the message, so the rendering lives in one place and cannot drift
/// between the two files.
///
/// PRIVACY: every line passes through AVMLog's sanitizer, which replaces the
/// Mac user's name with `~`. This file logs scratch paths, mount points, the
/// bundled-tool paths, and tool output that quotes paths back — all under the
/// user's home directory.
private func pipelineLog(_ msg: String) {
    AVMLog.write(msg, category: "pipeline")
}

// MARK: - Pipeline Stages

/// The ordered stages of building the install media. `rawValue` is the 1-based
/// step number; `Self.allCases.count` is the total used in "step N of M". The
/// validation gate runs BEFORE these (it's cheap + fail-fast) and is represented
/// separately so it never counts toward the user-facing step total of the
/// expensive build work.
enum PipelineStage: Int, CaseIterable, Sendable {
    case extractISO        = 1   // hdiutil attach + ditto copy: UDF tree -> scratch
    case injectWinpeshl    = 2   // wimlib-imagex: winpeshl.ini -> boot.wim image 2 (ConX bypass)
    case dropVirtioDrivers = 3   // FileManager: virtio ARM64 .inf/.sys/.cat -> $WinPEDriver$
    case buildAnswerImage  = 4   // mtools: generate autounattend.xml + mformat/mcopy FAT image
    case rebuildISO        = 5   // xorriso: extract EFI boot image, rebuild bootable ISO (Ldsiz!=0)
    case promote           = 6   // move verified artifacts from scratch into the VM runtime dir

    /// Short human label for the stage, used in spoken + visible progress.
    var label: String {
        switch self {
        case .extractISO:        return "Extracting the Windows installer"
        case .injectWinpeshl:    return "Preparing the installer for unattended setup"
        case .dropVirtioDrivers: return "Adding device drivers"
        case .buildAnswerImage:  return "Building the unattended answer file"
        case .rebuildISO:        return "Rebuilding the bootable installer"
        case .promote:           return "Finalizing the install media"
        }
    }
}

// MARK: - Progress

/// One progress event, surfaced to the UI as BOTH a VoiceOver announcement
/// (`spoken`) and visible text (`visible`). Emitted before each stage begins, so
/// a blind user always knows the pipeline is alive and what it's doing.
/// Sendable: it crosses from the background pipeline to the main actor.
struct PipelineProgress: Sendable {
    let stage: PipelineStage
    let stepNumber: Int          // 1-based, == stage.rawValue
    let totalSteps: Int          // == PipelineStage.allCases.count
    let spoken: String           // for VoiceOver: a full, natural sentence
    let visible: String          // for on-screen text: concise

    /// Build a standard "step N of M" progress event for a stage.
    static func forStage(_ stage: PipelineStage) -> PipelineProgress {
        let total = PipelineStage.allCases.count
        let n = stage.rawValue
        return PipelineProgress(
            stage: stage,
            stepNumber: n,
            totalSteps: total,
            spoken: "\(stage.label). Step \(n) of \(total).",
            visible: "Step \(n) of \(total): \(stage.label)"
        )
    }
}

// MARK: - WIM Image Info (parsed from wimlib-imagex info)

/// One image (edition) inside install.wim, as parsed from `wimlib-imagex info`.
struct WIMImageInfo {
    let index: Int
    let name: String
}

/// The subset of `wimlib-imagex info` we act on: the install.wim architecture and
/// its list of images (editions). Drives both the validation gate and (later) the
/// multi-edition picker.
struct WIMInfo {
    let architecture: String     // e.g. "ARM64", "AMD64", "x86"
    let images: [WIMImageInfo]
}

// MARK: - El Torito Info (parsed from xorriso -report_el_torito plain)

/// The subset of the el-torito report Stage 5 acts on. All values PARSED off the
/// actual ISO, never hardcoded (they vary per edition/language/build).
private struct ELToritoInfo {
    let ldsiz: Int               // EFI image load size, in 512-byte blocks
    let lba: Int                 // EFI image start, in 2048-byte sectors
    let volumeID: String         // for the rebuild's -V
}

// MARK: - Resolved Edition (single resolution point — issue #6)

/// The EFFECTIVE edition/key pair the pipeline installs, resolved EXACTLY ONCE
/// at the top of run() before validation. `wasDefaulted` records provenance:
/// true when PipelineInput arrived empty and the Windows 11 Pro defaults
/// engaged; false when the user (or a future edition picker) chose explicitly.
/// The flag drives the validation gate's tier — a defaulted edition missing
/// from the disc is a HARD-STOP (the user made no choice to honor; proceeding
/// guarantees the issue-#6 silent Setup hang), while a user-chosen edition
/// missing from the disc keeps the warn-and-proceed tier (the disc may name it
/// slightly differently). It also scopes Stage 4's backstop assert.
private struct ResolvedEdition {
    let name: String
    let key: String
    let wasDefaulted: Bool
}

// MARK: - Validation Gate

/// Result of the cheap, fail-fast ISO validation that runs BEFORE the expensive
/// extract. Two-tier by design (Allison's framing): HARD-STOP only where AVM is
/// CERTAIN the outcome is doomed (wrong architecture, not a Windows installer,
/// or — since issue #6 — the DEFAULTED edition absent from the disc, which
/// guarantees a silent Setup hang); WARN-AND-PROCEED where AVM is merely UNSURE
/// (user-requested edition not in the image list, unrecognized build) so a
/// techy user is never blocked on a valid-but-unusual ISO.
enum ISOValidation {
    /// Cleared the gate — proceed with the build.
    case ok
    /// AVM is certain this can't work. Halt before the extract, with a reason.
    case hardStop(reason: String)
    /// AVM is unsure. Surface the reason and let the user decide whether to go on.
    case warn(reason: String)
}

// MARK: - Pipeline Errors

/// A stage failure. Names the stage and carries a spoken, ACTIONABLE reason
/// (never a bare "failed"). Conforms to LocalizedError so it reads cleanly if it
/// ever surfaces through the same channel as AVMError.
enum PipelineError: LocalizedError {
    case notImplemented(PipelineStage)
    case toolNotFound(String)                       // a bundled tool missing from Resources
    case stageFailed(stage: PipelineStage, reason: String)
    case postconditionFailed(stage: PipelineStage, reason: String)
    case validationHardStop(reason: String)
    case isoMountFailed(reason: String)
    case userCancelled

    var errorDescription: String? {
        switch self {
        case .notImplemented(let stage):
            return "\(stage.label) is not implemented yet."
        case .toolNotFound(let name):
            return "A required tool (\(name)) is missing from the app. This is a build problem, not something you did."
        case .stageFailed(let stage, let reason):
            return "\(stage.label) failed. \(reason)"
        case .postconditionFailed(let stage, let reason):
            return "\(stage.label) did not produce the expected result. \(reason)"
        case .validationHardStop(let reason):
            return reason
        case .isoMountFailed(let reason):
            return "AVM couldn't open the Windows ISO. \(reason)"
        case .userCancelled:
            return "Install media preparation was cancelled."
        }
    }
}

// MARK: - Pipeline Input / Output

/// Everything the pipeline needs to build the media for one VM.
struct PipelineInput {
    let vmID: UUID
    let sourceISOPath: String        // the user's original Windows 11 ARM64 ISO
    let runtimeDir: URL              // the VM's runtime dir (verified artifacts land here)
    let editionName: String          // /IMAGE/NAME, e.g. "Windows 11 Pro" (multi-edition param #1)
    let productKey: String           // matching generic edition-select key (multi-edition param #2)
    /// Called when the validation gate returns `.warn`. Return true to proceed,
    /// false to abort. Lets the UI ask the (often techy) user to decide. Defaults
    /// to proceeding if the host never sets it (headless/testing).
    /// CONCURRENCY: this closure is invoked OFF the main actor. A closure that
    /// shows UI must hop to the main actor itself (e.g. await MainActor.run).
    var confirmWarning: ((String) async -> Bool)?
}

/// The verified artifacts the pipeline produces, living in the VM runtime dir.
struct PipelineOutput {
    let rebuiltISOPath: String       // the /legacy + driver ISO AVM generated
    let answerImagePath: String      // the FAT autounattend image (removable usb-storage at launch)
}

// MARK: - Windows Install Pipeline

/// NOT actor-isolated; run() is @concurrent so the whole pipeline executes on
/// the background global executor regardless of the caller's actor (see
/// CONCURRENCY MODEL in the file header). Progress hops to the main actor.
final class WindowsInstallPipeline {

    /// Progress sink. The host (VMManager) assigns this to forward events to its
    /// own @Published install-progress property + appendConsole, so the UI can
    /// announce them via VoiceOver and show them on screen.
    /// INVOKED ON THE MAIN ACTOR (emit hops there), so the host can touch UI
    /// state directly. Assign BEFORE calling run(); don't reassign mid-run.
    var onProgress: ((PipelineProgress) -> Void)?

    /// Scratch dir for the in-progress build. Everything is built HERE and only
    /// promoted into the runtime dir on verified success, so a failure never
    /// leaves a dud ISO where the launch path would find it. Touched only from
    /// run()'s serial flow.
    private var scratchDir: URL?

    /// The effective edition/key for THIS run, resolved once at the top of
    /// run() (see ResolvedEdition + the file-header EDITION RESOLUTION note).
    /// Touched only from run()'s serial flow, same discipline as scratchDir.
    private var resolvedEdition: ResolvedEdition?

    /// The edition names read off the disc's install.wim by the validation
    /// gate, kept for Stage 4's backstop assert. nil when the wim was
    /// unreadable (the gate's warn tier covered that) — the backstop cannot
    /// assert against a list that doesn't exist. Touched only from run()'s
    /// serial flow.
    private var discEditionNames: [String]?

    /// boot.wim image index that is "Microsoft Windows Setup (arm64)" — the image
    /// whose winpeshl.ini controls what runs at boot. VERIFIED on the real 25H2
    /// ARM64 ISO: image 1 is plain WinPE, image 2 is Windows Setup. Image 2 is the
    /// ConX-bypass injection target.
    private let setupBootWimImageIndex = 2

    /// Defaults for the SINGLE RESOLUTION POINT at the top of run() — the ONLY
    /// place they can engage (Stage 4's former private fallback is deleted;
    /// issue #6). Used when PipelineInput's editionName/productKey arrive empty
    /// (the edition-picker UI doesn't exist yet). The key is the PUBLIC generic
    /// Windows 11 Pro INSTALL key — it selects the edition only, does NOT
    /// activate Windows, and stores nothing sensitive.
    private let defaultEditionName = "Windows 11 Pro"
    private let defaultProductKey = "VK7JG-NPHTM-C97JM-9MPGT-3V66T"

    /// The literal placeholder tokens in the bundled autounattend.xml template.
    /// Stage 4 verifies both are PRESENT before substituting — a missing token
    /// means the template was edited without them and edition selection would
    /// silently break, so it's surfaced as a build problem.
    private let editionToken = "AVM_EDITION_NAME"
    private let productKeyToken = "AVM_PRODUCT_KEY"

    /// The virtio drivers to drop into $WinPEDriver$, and the files each one
    /// REQUIRES present for its PnP install to succeed inside the guest. NetKVM is
    /// a QUAD: netkvm.inf's CopyFiles/SourceDisksFiles copy netkvmp.exe into
    /// System32 at driver-install time, so a missing netkvmp.exe fails the install
    /// — it is NOT optional. Balloon is the plain .inf/.sys/.cat triple. These
    /// names are the postcondition's required set (the source folder may carry
    /// extra files — .pdb, helper .exe — which are harmless and simply copied).
    private let virtioRequiredFiles: [(driver: String, required: [String])] = [
        ("NetKVM",  ["netkvm.inf", "netkvm.sys", "netkvm.cat", "netkvmp.exe"]),
        ("Balloon", ["balloon.inf", "balloon.sys", "balloon.cat"])
    ]

    /// The guest-agent payload Stage 4 copies into the FAT answer image
    /// alongside autounattend.xml, so the specialize pass (template Orders 2-3)
    /// can install the vdagent's transport driver and the agent itself before
    /// OOBE — absolute (client-mode) mouse from the first interactive screen.
    /// This is DELIBERATELY separate from virtioRequiredFiles: that table
    /// drives Stage 3's $WinPEDriver$ drop, and vioserial must NOT go there
    /// (the answer image is its only ride; proven design 2026-08-15).
    ///
    /// - vioserial triple: ARM64 vioser.inf/.cat/.sys from virtio-win 0.1.285
    ///   (vioser.pdb — debug symbols — is deliberately NOT bundled), staged by
    ///   the Run Script from Resources/virtio/vioserial/.
    /// - vdagent MSI: the STANDALONE spice-vdagent-x64-0.10.0.msi (the
    ///   virtio-win-guest-tools bundle rolls back on ARM64 — do not swap it
    ///   in), staged by the Run Script from Resources/vdagent/, and copied
    ///   into the image under the plain 8.3 name VDAGENT.MSI so the template's
    ///   letter-enumeration command needs no long-filename handling.
    ///
    /// Each entry: the bundled source (resource dir + file name) and the name
    /// it takes at the image root. The image-root names are load-bearing —
    /// they are the literal names the template's if-exist guards test.
    private let answerImagePayload: [(resourceDir: String, sourceName: String, imageName: String)] = [
        ("virtio/vioserial", "vioser.inf", "vioser.inf"),
        ("virtio/vioserial", "vioser.cat", "vioser.cat"),
        ("virtio/vioserial", "vioser.sys", "vioser.sys"),
        ("vdagent", "spice-vdagent-x64-0.10.0.msi", "VDAGENT.MSI")
    ]

    init(onProgress: ((PipelineProgress) -> Void)? = nil) {
        self.onProgress = onProgress
    }

    // MARK: Tool Discovery

    /// Locate a bundled, signed pipeline tool in Resources. Mirrors VMManager's
    /// bundledBinaryURL discovery (these tools are staged + signed alongside
    /// qemu/swtpm by the Run Script). For mtools the pipeline invokes the
    /// `mformat`/`mcopy`/`mdir` SYMLINKS (dispatch is by argv[0]), which live next
    /// to the real `mtools` in Resources.
    private func toolURL(named name: String) throws -> URL {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw PipelineError.toolNotFound(name)
        }
        let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            pipelineLog("toolURL: \(name) not found at \(url.path)")
            throw PipelineError.toolNotFound(name)
        }
        return url
    }

    /// Locate a bundled DATA resource directory in Resources (e.g. "virtio").
    /// Unlike toolURL this is a directory of inert files, not an executable, so
    /// there's no exec-bit/signing expectation — just that the Run Script staged
    /// it. Throws toolNotFound (a build problem) if missing, matching how a
    /// missing tool is surfaced.
    private func resourceDirURL(named name: String) throws -> URL {
        guard let resourcePath = Bundle.main.resourcePath else {
            throw PipelineError.toolNotFound(name)
        }
        let url = URL(fileURLWithPath: resourcePath).appendingPathComponent(name, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            pipelineLog("resourceDirURL: \(name) not found (or not a directory) at \(url.path)")
            throw PipelineError.toolNotFound(name)
        }
        return url
    }

    // MARK: - Subprocess Helper

    /// Run a bundled tool (or a system binary at an absolute path) to completion,
    /// capturing stdout+stderr. Returns (exitCode, combinedOutput). Used for
    /// wimlib/xorriso/mtools and for hdiutil/ditto/dd.
    ///
    /// CONCURRENCY: async. The proven synchronous body (launch, read-before-wait,
    /// waitUntilExit) runs UNCHANGED on a background GCD queue inside a
    /// continuation, so the blocking wait ties up neither the main actor nor a
    /// cooperative-pool thread. Callers simply `await`.
    ///
    /// The child inherits the app's environment UNCHANGED. DYLD_LIBRARY_PATH is
    /// deliberately NOT set: bundled tools resolve their deps via @loader_path
    /// (no env help needed), and setting it makes dyld shadow a binary's real
    /// dependencies with same-named bundle dylibs — the sysroot's libiconv lacks
    /// the _iconv symbol the system-linked mtools needs, killing it with SIGABRT
    /// (Process reports terminationStatus 6 = the signal number). Proven by test.
    /// `extraEnvironment` merges per-call variables (e.g. MTOOLS_SKIP_CHECK).
    @discardableResult
    private func runTool(_ executable: URL, _ arguments: [String], extraEnvironment: [String: String] = [:]) async -> (code: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments

                if !extraEnvironment.isEmpty {
                    var env = ProcessInfo.processInfo.environment
                    for (key, value) in extraEnvironment {
                        env[key] = value
                    }
                    process.environment = env
                }

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                } catch {
                    pipelineLog("runTool: failed to launch \(executable.lastPathComponent): \(error)")
                    continuation.resume(returning: (-1, "Failed to launch \(executable.lastPathComponent): \(error.localizedDescription)"))
                    return
                }

                // Read before waitUntilExit to avoid a full-pipe deadlock on large output.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (process.terminationStatus, output))
            }
        }
    }

    // MARK: - ISO Mount / Detach (macOS UDF, read-only)

    /// Attach the source ISO read-only and return its mount point. Windows ISOs
    /// are UDF-primary; macOS mounts UDF natively, which is how we read the tree
    /// (xorriso can't — see file header). `-nobrowse -noautoopen` keeps it out of
    /// the user's Finder/VoiceOver focus. ALWAYS pair with detachISO on BOTH the
    /// success and error paths — defer can't await, so this is done explicitly
    /// at the two call sites.
    private func mountISO(_ isoPath: String) async throws -> URL {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let result = await runTool(hdiutil, [
            "attach", isoPath,
            "-readonly", "-nobrowse", "-noautoopen"
        ])
        guard result.code == 0 else {
            throw PipelineError.isoMountFailed(reason: "It may not be a valid disc image. (hdiutil exit \(result.code))")
        }
        // hdiutil prints one line per mounted filesystem: "<dev>\t<type>\t<mountpoint>".
        // Take the first line that carries a /Volumes mount point.
        for line in result.output.split(separator: "\n") {
            if let range = line.range(of: "/Volumes/") {
                let mountPoint = String(line[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !mountPoint.isEmpty {
                    pipelineLog("mountISO: \(isoPath) -> \(mountPoint)")
                    return URL(fileURLWithPath: mountPoint)
                }
            }
        }
        // Attached but no /Volumes mount point parsed — fail. (Rare; usually means
        // a non-filesystem image.)
        throw PipelineError.isoMountFailed(reason: "It mounted but exposed no readable volume.")
    }

    /// Detach a previously mounted ISO. Best-effort; tries a force detach on a
    /// first-attempt failure (a tool may still hold a handle for a moment).
    private func detachISO(_ mountPoint: URL) async {
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let r = await runTool(hdiutil, ["detach", mountPoint.path])
        if r.code != 0 {
            _ = await runTool(hdiutil, ["detach", mountPoint.path, "-force"])
        }
        pipelineLog("detachISO: \(mountPoint.path)")
    }

    // MARK: - WIM Info Parsing

    /// Parse the subset of `wimlib-imagex info` we act on: the architecture and
    /// the (index, name) of each image. The format is stable "Key: value" lines;
    /// `Architecture:` appears per-image but is the same across images in a normal
    /// Windows ISO, so we take the first one seen.
    private func parseWIMInfo(_ text: String) -> WIMInfo {
        var architecture = ""
        var images: [WIMImageInfo] = []
        var pendingIndex: Int?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Index:") {
                let v = line.dropFirst("Index:".count).trimmingCharacters(in: .whitespaces)
                pendingIndex = Int(v)
            } else if line.hasPrefix("Name:") {
                let v = line.dropFirst("Name:".count).trimmingCharacters(in: .whitespaces)
                if let idx = pendingIndex {
                    images.append(WIMImageInfo(index: idx, name: v))
                    pendingIndex = nil
                }
            } else if line.hasPrefix("Architecture:") && architecture.isEmpty {
                architecture = line.dropFirst("Architecture:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return WIMInfo(architecture: architecture, images: images)
    }

    // MARK: - El Torito Parsing

    /// Parse Ldsiz, LBA, and Volume id from `xorriso -report_el_torito plain`
    /// output. The "El Torito boot img" row's LAST TWO whitespace-delimited
    /// fields are Ldsiz then LBA — parsed as trailing fields keyed on the row
    /// prefix, NEVER by column position (a rebuilt ISO's LBA is 7 digits and
    /// shifts the columns). Volume id is between the single quotes on its line.
    /// Returns nil if any of the three pieces can't be found — the caller turns
    /// that into a stage failure naming what's missing.
    private func parseElTorito(_ text: String) -> ELToritoInfo? {
        var ldsiz: Int?
        var lba: Int?
        var volumeID: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("El Torito boot img") {
                let fields = line.split(separator: " ").map(String.init)
                if fields.count >= 2 {
                    lba = Int(fields[fields.count - 1])
                    ldsiz = Int(fields[fields.count - 2])
                }
            } else if line.hasPrefix("Volume id") {
                if let first = line.firstIndex(of: "'"),
                   let last = line.lastIndex(of: "'"),
                   first < last {
                    volumeID = String(line[line.index(after: first)..<last])
                }
            }
        }

        guard let l = ldsiz, let b = lba, let v = volumeID else { return nil }
        return ELToritoInfo(ldsiz: l, lba: b, volumeID: v)
    }

    // MARK: - Driver Loop

    /// Run the whole pipeline: edition resolution, validation gate, then the six
    /// build stages in order, halting on the first failure and cleaning up
    /// scratch. Emits a progress event before each stage. Returns the verified
    /// output artifacts.
    /// @concurrent: FORCED onto the background global executor regardless of
    /// the caller's actor (plain nonisolated async proved insufficient — see
    /// CONCURRENCY MODEL in the file header).
    @concurrent
    func run(_ input: PipelineInput) async throws -> PipelineOutput {
        pipelineLog("run: starting pipeline for VM \(input.vmID.uuidString)")
        pipelineLog("run: executing on main thread = \(Thread.isMainThread) (must be false)")

        // SINGLE RESOLUTION POINT (issue #6): resolve the effective edition/key
        // pair ONCE, before validation, so the gate and Stage 4 act on the same
        // values by construction. This is the ONLY place the defaults engage.
        let wasDefaulted = input.editionName.isEmpty
        let resolved = ResolvedEdition(
            name: wasDefaulted ? defaultEditionName : input.editionName,
            key: input.productKey.isEmpty ? defaultProductKey : input.productKey,
            wasDefaulted: wasDefaulted
        )
        resolvedEdition = resolved
        discEditionNames = nil   // fresh per run; the gate fills it when readable
        pipelineLog("run: resolved edition \"\(resolved.name)\" (\(resolved.wasDefaulted ? "default" : "user-selected"))")

        // Cheap, fail-fast validation BEFORE the expensive extract.
        let validation = try await validateISO(input, resolved: resolved)
        switch validation {
        case .ok:
            pipelineLog("run: validation OK")
        case .hardStop(let reason):
            pipelineLog("run: validation HARD-STOP: \(reason)")
            throw PipelineError.validationHardStop(reason: reason)
        case .warn(let reason):
            pipelineLog("run: validation WARN: \(reason)")
            let proceed = await (input.confirmWarning?(reason) ?? true)
            if !proceed {
                pipelineLog("run: user declined to proceed past warning")
                throw PipelineError.userCancelled
            }
        }

        // Fresh scratch dir for this build.
        let scratch = try makeScratchDir(for: input.vmID)
        scratchDir = scratch
        pipelineLog("run: scratch dir \(scratch.path)")

        do {
            for stage in PipelineStage.allCases {
                await emit(.forStage(stage))
                try await runStage(stage, input: input, scratch: scratch)
            }

            let output = PipelineOutput(
                rebuiltISOPath: input.runtimeDir.appendingPathComponent("install-avm.iso").path,
                answerImagePath: input.runtimeDir.appendingPathComponent("autounattend.img").path
            )
            cleanScratch()
            pipelineLog("run: pipeline complete")
            return output
        } catch {
            pipelineLog("run: pipeline FAILED: \(error.localizedDescription)")
            cleanScratch()
            throw error
        }
    }

    /// Dispatch one stage to its implementation.
    private func runStage(_ stage: PipelineStage, input: PipelineInput, scratch: URL) async throws {
        switch stage {
        case .extractISO:        try await stageExtractISO(input: input, scratch: scratch)
        case .injectWinpeshl:    try await stageInjectWinpeshl(input: input, scratch: scratch)
        case .dropVirtioDrivers: try await stageDropVirtioDrivers(input: input, scratch: scratch)
        case .buildAnswerImage:  try await stageBuildAnswerImage(input: input, scratch: scratch)
        case .rebuildISO:        try await stageRebuildISO(input: input, scratch: scratch)
        case .promote:           try await stagePromote(input: input, scratch: scratch)
        }
    }

    // MARK: - Progress Emission

    /// Emit one progress event. Hops to the MAIN ACTOR and AWAITS the hop, so
    /// the host's onProgress (and its VoiceOver announcement) is delivered
    /// before the stage begins work — the accessibility contract.
    private func emit(_ progress: PipelineProgress) async {
        pipelineLog("progress: \(progress.visible)")
        guard let handler = onProgress else { return }
        await MainActor.run {
            handler(progress)
        }
    }

    // MARK: - Shared Paths

    /// The writable copy of the ISO tree, inside scratch. Stages 1–5 read/write
    /// here; stage 5 builds the output ISO from it.
    private func isoTreeURL(in scratch: URL) -> URL {
        scratch.appendingPathComponent("iso-tree")
    }

    /// The FAT answer image built by Stage 4, inside scratch. Stage 6 promotes it
    /// to the runtime dir as autounattend.img.
    private func answerImageURL(in scratch: URL) -> URL {
        scratch.appendingPathComponent("autounattend.img")
    }

    /// The rebuilt bootable ISO built by Stage 5, inside scratch. Stage 6
    /// promotes it to the runtime dir as install-avm.iso.
    private func rebuiltISOURL(in scratch: URL) -> URL {
        scratch.appendingPathComponent("install-avm.iso")
    }

    // MARK: - Validation Gate (implemented)

    /// Two-tier ISO validation, run BEFORE the expensive extract. Mounts the ISO
    /// (its own independent mount, detached on BOTH exit paths — defer can't
    /// await), reads editions + architecture from install.wim via the bundled
    /// wimlib-imagex, and decides:
    ///   HARD-STOP  (certain):  no sources/install.wim (not a Windows installer);
    ///                          architecture is not ARM64 (won't boot on `virt`);
    ///                          the DEFAULTED edition isn't on the disc (issue
    ///                          #6 — Setup would hang silently on an edition
    ///                          that doesn't exist, and the user made no choice
    ///                          for the warn tier to honor).
    ///   WARN       (unsure):   the USER-CHOSEN edition name isn't among the
    ///                          images (the disc may name it differently);
    ///                          we couldn't read the architecture at all.
    ///   OK:                    install.wim present, ARM64, effective edition found.
    /// Side effect: stores the disc's edition names in discEditionNames (when
    /// the wim is readable) for Stage 4's backstop.
    private func validateISO(_ input: PipelineInput, resolved: ResolvedEdition) async throws -> ISOValidation {
        let wimlib = try toolURL(named: "wimlib-imagex")

        let mount = try await mountISO(input.sourceISOPath)
        let verdict = await validateMountedISO(input: input, resolved: resolved, wimlib: wimlib, mount: mount)
        await detachISO(mount)
        return verdict
    }

    /// The gate's decision logic against an already-mounted ISO. Non-throwing by
    /// design — every outcome is expressed as an ISOValidation — so the caller's
    /// mount/detach pairing has exactly one exit path to cover.
    private func validateMountedISO(input: PipelineInput, resolved: ResolvedEdition, wimlib: URL, mount: URL) async -> ISOValidation {
        let installWim = mount.appendingPathComponent("sources/install.wim")
        guard FileManager.default.fileExists(atPath: installWim.path) else {
            // Certain: a Windows install ISO always has sources/install.wim.
            return .hardStop(reason: "This doesn't look like a Windows 11 installer — it has no install image (sources/install.wim). Make sure you selected a Windows 11 ARM64 ISO.")
        }

        let result = await runTool(wimlib, ["info", installWim.path])
        guard result.code == 0 else {
            // We found install.wim but couldn't read it. Unsure rather than
            // certain — let a techy user proceed. (discEditionNames stays nil;
            // Stage 4's backstop cannot assert without a list.)
            return .warn(reason: "AVM found the Windows install image but couldn't read its details. The ISO may be unusual or partly corrupted. You can proceed, but the install might not complete cleanly.")
        }

        let info = parseWIMInfo(result.output)

        // CERTAIN hard-stop: wrong architecture. An x64/x86 install.wim will never
        // boot on the aarch64 `virt` machine.
        if !info.architecture.isEmpty {
            let arch = info.architecture.uppercased()
            if arch != "ARM64" {
                return .hardStop(reason: "This is a \(info.architecture) version of Windows, which can't run on this Mac's virtual machine. You need a Windows 11 ARM64 ISO.")
            }
        } else {
            // Couldn't read architecture — unsure, not certain. Warn.
            return .warn(reason: "AVM couldn't confirm this ISO is the ARM64 version of Windows. If it isn't ARM64, the install won't boot. You can proceed if you're sure it's the ARM64 ISO.")
        }

        // The wim is readable — record the disc's edition names for Stage 4's
        // backstop before the edition check decides anything.
        let names = info.images.map { $0.name }
        discEditionNames = names

        // EDITION CHECK, two tiers by provenance (issue #6). The EFFECTIVE
        // edition is checked — the resolved value, never raw input — so the
        // defaulted case can no longer slip through unexamined.
        if !names.contains(resolved.name) {
            let available = names.isEmpty ? "none found" : names.joined(separator: ", ")
            if resolved.wasDefaulted {
                // CERTAIN: the default isn't on this disc. Proceeding writes an
                // answer file naming an edition that doesn't exist, and Windows
                // Setup hangs silently — field-proven by issue #6 (IoT
                // Enterprise LTSC). The user made no choice to honor, so there
                // is nothing to warn about — stop, say why, name what IS there.
                return .hardStop(reason: "This ISO does not contain \(resolved.name), the edition AVM currently installs. It contains: \(available). AVM can't install these editions yet. A standard Windows 11 ARM64 ISO from Microsoft's Windows 11 download page will work.")
            } else {
                // UNSURE: the user chose this name; the disc may name the
                // edition slightly differently. Warn and let them decide.
                return .warn(reason: "The edition you chose (\(resolved.name)) wasn't found on this ISO. Available editions are: \(available). You can proceed, but the install may not match your choice.")
            }
        }

        pipelineLog("validateISO: OK — arch \(info.architecture), \(info.images.count) edition(s), effective edition \"\(resolved.name)\" present")
        return .ok
    }

    // MARK: - Stage 1 — Extract ISO (implemented)

    /// Mount the source ISO (hdiutil, UDF) and copy its entire tree into
    /// scratch/iso-tree with `ditto` (macOS's robust recursive copy — proven to
    /// copy the 7.5GB tree, both WIMs at full size, in a few seconds). NOT xorriso
    /// (it can't read the UDF tree — see file header). The copied tree inherits
    /// the ISO's read-only permission bits, so we then make it user-writable
    /// (stages 2–4 modify boot.wim in place and create $WinPEDriver$).
    /// Postcondition: scratch/iso-tree/sources/{boot.wim,install.wim} exist and
    /// are non-trivial in size (the big files actually came across).
    /// The mount is detached on BOTH the success and error paths (defer can't
    /// await).
    private func stageExtractISO(input: PipelineInput, scratch: URL) async throws {
        let mount = try await mountISO(input.sourceISOPath)
        do {
            try await performExtract(from: mount, scratch: scratch)
        } catch {
            await detachISO(mount)
            throw error
        }
        await detachISO(mount)
    }

    /// Stage 1's body against an already-mounted ISO — the copy, the chmod, and
    /// the postconditions. Split out so stageExtractISO's mount/detach pairing
    /// stays trivially auditable.
    private func performExtract(from mount: URL, scratch: URL) async throws {
        let tree = isoTreeURL(in: scratch)
        // ditto creates the destination; remove any stale tree first so a partial
        // prior copy can't contaminate this one.
        try? FileManager.default.removeItem(at: tree)

        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        let copyResult = await runTool(ditto, [mount.path, tree.path])
        guard copyResult.code == 0 else {
            throw PipelineError.stageFailed(
                stage: .extractISO,
                reason: "Couldn't copy the installer files from the ISO. (ditto exit \(copyResult.code): \(copyResult.output.suffix(300)))"
            )
        }

        // The copy carries the ISO's read-only bits; make the tree writable so the
        // later stages can modify boot.wim and add the driver folder.
        let chmod = URL(fileURLWithPath: "/bin/chmod")
        let chmodResult = await runTool(chmod, ["-R", "u+w", tree.path])
        if chmodResult.code != 0 {
            // Non-fatal here, but log it — a later stage's write would surface the
            // real failure with its own actionable message.
            pipelineLog("stageExtractISO: chmod -R u+w returned \(chmodResult.code) (continuing)")
        }

        // Postcondition: both WIMs present and non-trivial. A directory-only copy
        // (or a truncated big file) would otherwise pass silently and break stage 2.
        let bootWim = tree.appendingPathComponent("sources/boot.wim")
        let installWim = tree.appendingPathComponent("sources/install.wim")
        let fm = FileManager.default
        for (wim, label) in [(bootWim, "boot.wim"), (installWim, "install.wim")] {
            guard fm.fileExists(atPath: wim.path) else {
                throw PipelineError.postconditionFailed(
                    stage: .extractISO,
                    reason: "The installer file \(label) is missing after copying. The ISO may be incomplete."
                )
            }
            let size = (try? fm.attributesOfItem(atPath: wim.path)[.size] as? Int) ?? 0
            // boot.wim is hundreds of MB, install.wim multiple GB; anything under a
            // few MB means the copy didn't really bring the file across.
            if (size ?? 0) < 4_000_000 {
                throw PipelineError.postconditionFailed(
                    stage: .extractISO,
                    reason: "The installer file \(label) didn't copy completely from the ISO."
                )
            }
        }

        pipelineLog("stageExtractISO: copied ISO tree to \(tree.path) and made it writable")
    }

    // MARK: - Stage 2 — Inject winpeshl.ini (implemented; the ConX bypass)

    /// Inject a winpeshl.ini into boot.wim image 2 ("Microsoft Windows Setup
    /// (arm64)") so WinPE launches `setup.exe /legacy` instead of letting 25H2's
    /// ConX (SetupPrep.exe) run — ConX silently ignores autounattend.xml, so this
    /// is THE step that makes the unattended install apply. Proven on the real
    /// boot.wim: image 2 is the Setup image, the file lands at exactly
    /// \Windows\System32\winpeshl.ini, and legacy setup honors the answer file.
    ///
    /// winpeshl.ini is generated here (tiny, fixed content) with CRLF line endings
    /// (Windows .ini convention). Injected via the bundled wimlib-imagex `update`.
    ///
    /// QUOTING (proven by in-app failure + isolated test): wimlib word-splits the
    /// --command STRING'S contents on whitespace, so the source path — which
    /// lives under "Application Support" and contains a SPACE — must be
    /// double-quoted INSIDE the command string or the add command falls apart
    /// with exit 255. The wimpath is quoted too, for uniformity.
    ///
    /// Postcondition: `dir` of image 2 shows the file at /Windows/System32/.
    private func stageInjectWinpeshl(input: PipelineInput, scratch: URL) async throws {
        let wimlib = try toolURL(named: "wimlib-imagex")
        let tree = isoTreeURL(in: scratch)
        let bootWim = tree.appendingPathComponent("sources/boot.wim")

        guard FileManager.default.fileExists(atPath: bootWim.path) else {
            throw PipelineError.stageFailed(
                stage: .injectWinpeshl,
                reason: "The boot image (boot.wim) wasn't found in the extracted installer."
            )
        }

        // Generate winpeshl.ini with CRLF line endings. The [LaunchApps] section
        // forces legacy Setup; %SYSTEMDRIVE%\sources\setup.exe is WinPE's path to
        // the installer at boot. (Verified contents — see header.)
        let winpeshlContents = "[LaunchApps]\r\n%SYSTEMDRIVE%\\sources\\setup.exe, /legacy\r\n"
        let winpeshlURL = scratch.appendingPathComponent("winpeshl.ini")
        do {
            try winpeshlContents.write(to: winpeshlURL, atomically: true, encoding: .utf8)
        } catch {
            throw PipelineError.stageFailed(
                stage: .injectWinpeshl,
                reason: "Couldn't write the setup configuration file. (\(error.localizedDescription))"
            )
        }

        // Inject into the Setup image. wimlib `update <wim> <image> --command="add
        // <src> <wimpath>"` — the wimpath is the destination inside the image.
        // BOTH paths are double-quoted inside the command string (see QUOTING
        // note above — the scratch path contains a space).
        let addCommand = "add \"\(winpeshlURL.path)\" \"/Windows/System32/winpeshl.ini\""
        let result = await runTool(wimlib, [
            "update", bootWim.path, "\(setupBootWimImageIndex)",
            "--command=\(addCommand)"
        ])
        guard result.code == 0 else {
            throw PipelineError.stageFailed(
                stage: .injectWinpeshl,
                reason: "Couldn't modify the boot image to enable unattended setup. (wimlib exit \(result.code): \(result.output.suffix(300)))"
            )
        }

        // Postcondition: confirm the file is actually present at the target path
        // inside image 2. A silent miss here would mean the answer file never
        // applies and the user hits interactive prompts they can't see — exactly
        // the failure this whole pipeline exists to prevent — so verify it landed.
        let dirResult = await runTool(wimlib, ["dir", bootWim.path, "\(setupBootWimImageIndex)"])
        let landed = dirResult.output
            .split(separator: "\n")
            .contains { line in
                let l = line.lowercased()
                return l.contains("/windows/system32/winpeshl.ini")
            }
        guard landed else {
            throw PipelineError.postconditionFailed(
                stage: .injectWinpeshl,
                reason: "The setup configuration didn't take effect inside the boot image."
            )
        }

        pipelineLog("stageInjectWinpeshl: winpeshl.ini injected into boot.wim image \(setupBootWimImageIndex) and verified")
    }

    // MARK: - Stage 3 — Drop virtio drivers (implemented)

    /// Copy the bundled virtio ARM64 driver folders into a literal "$WinPEDriver$"
    /// directory at the root of the extracted ISO tree. Windows Setup recursively
    /// scans "$WinPEDriver$" at the media root during windowsPE and auto-installs
    /// every .inf it finds, so NetKVM (paravirtualized NIC) and Balloon install
    /// during setup — no network-driver prompt at OOBE (which a blind user can't
    /// answer), and fast virtio devices from first boot. The drivers are INERT
    /// DATA bundled by the Run Script (Resources/virtio/<driver>/) and copied
    /// verbatim — never re-signed (the Red Hat .cat catalog signature is what
    /// Win11 ARM's driver-signing enforcement checks; re-signing would break it).
    ///
    /// NetKVM is a QUAD, not a triple: netkvm.inf's CopyFiles/SourceDisksFiles
    /// pull netkvmp.exe into System32 at driver-install time, so netkvmp.exe must
    /// be present or PnP install fails inside the guest. The required-files table
    /// (virtioRequiredFiles) encodes this; the postcondition enforces it.
    ///
    /// NAME PRESERVATION: the "$WinPEDriver$" name survives to the OUTPUT ISO
    /// only because Stage 5 builds with Joliet (see the Stage 5 doc + file
    /// header) — the plain ISO 9660 namespace can't carry `$` and mangles it.
    ///
    /// Postcondition: for each driver, "$WinPEDriver$/<driver>/" exists and every
    /// REQUIRED file is present. (Extra files in the source folder — none here,
    /// since the Run Script stages only the required set — would be harmless.)
    private func stageDropVirtioDrivers(input: PipelineInput, scratch: URL) async throws {
        let fm = FileManager.default
        let tree = isoTreeURL(in: scratch)

        // The bundled source tree: Resources/virtio/<driver>/. A missing tree is a
        // build problem (Run Script didn't stage it), surfaced as toolNotFound.
        let virtioSrc = try resourceDirURL(named: "virtio")

        // Create the literal "$WinPEDriver$" folder at the tree root. The dollar
        // signs are part of the literal directory name (FileManager treats the
        // string verbatim — no shell expansion); proven by bare-Terminal test.
        let winPEDriverDir = tree.appendingPathComponent("$WinPEDriver$", isDirectory: true)
        do {
            // Remove any stale copy first so a re-run can't merge with a partial
            // prior attempt, then create fresh.
            try? fm.removeItem(at: winPEDriverDir)
            try fm.createDirectory(at: winPEDriverDir, withIntermediateDirectories: true)
        } catch {
            throw PipelineError.stageFailed(
                stage: .dropVirtioDrivers,
                reason: "Couldn't create the driver folder in the installer. (\(error.localizedDescription))"
            )
        }

        // Copy each driver folder verbatim (cp -R equivalent). copyItem fails if
        // the destination exists, but we just created a fresh empty parent, so
        // each per-driver destination is new.
        for entry in virtioRequiredFiles {
            let srcDir = virtioSrc.appendingPathComponent(entry.driver, isDirectory: true)
            let dstDir = winPEDriverDir.appendingPathComponent(entry.driver, isDirectory: true)

            guard fm.fileExists(atPath: srcDir.path) else {
                throw PipelineError.stageFailed(
                    stage: .dropVirtioDrivers,
                    reason: "The bundled \(entry.driver) driver is missing from the app. This is a build problem, not something you did."
                )
            }

            do {
                try fm.copyItem(at: srcDir, to: dstDir)
            } catch {
                throw PipelineError.stageFailed(
                    stage: .dropVirtioDrivers,
                    reason: "Couldn't copy the \(entry.driver) driver into the installer. (\(error.localizedDescription))"
                )
            }
        }

        // Postcondition: every REQUIRED file is present for every driver. A silent
        // miss (e.g. NetKVM's netkvmp.exe absent) would surface inside the guest as
        // a failed driver install or an OOBE network-driver prompt the user can't
        // see — verify here instead.
        for entry in virtioRequiredFiles {
            let dstDir = winPEDriverDir.appendingPathComponent(entry.driver, isDirectory: true)
            for fileName in entry.required {
                let fileURL = dstDir.appendingPathComponent(fileName)
                guard fm.fileExists(atPath: fileURL.path) else {
                    throw PipelineError.postconditionFailed(
                        stage: .dropVirtioDrivers,
                        reason: "The \(entry.driver) driver file \(fileName) is missing after copying."
                    )
                }
            }
        }

        pipelineLog("stageDropVirtioDrivers: staged \(virtioRequiredFiles.map { $0.driver }.joined(separator: ", ")) into $WinPEDriver$ and verified required files")
    }

    // MARK: - Stage 4 — Build answer image (implemented)

    /// Template-fill the bundled autounattend.xml from the RESOLVED edition/key
    /// pair (single resolution point at the top of run() — Stage 4 no longer
    /// owns a fallback; issue #6), then build an 8MB FAT12 answer image with
    /// mformat/mcopy carrying the XML PLUS the guest-agent payload
    /// (answerImagePayload: vioserial driver triple + vdagent MSI — see that
    /// table's doc for what and why), and verify all five files with mdir. The
    /// image is attached at launch as removable usb-storage, which is where
    /// Windows Setup scans for autounattend.xml; the specialize pass (template
    /// Orders 2-3) installs the payload from this same volume before OOBE.
    ///
    /// WHY 8MB: the old 2MB image left only ~78KB free once the ~1.8MB MSI
    /// was aboard — too thin for msiexec's verbose VDAGENT.LOG (91KB observed)
    /// plus slack. 8MB was the geometry proven end to end 2026-08-15.
    ///
    /// Template: Resources/autounattend.xml carries two literal tokens —
    /// AVM_EDITION_NAME (the /IMAGE/NAME value) and AVM_PRODUCT_KEY (the generic
    /// edition-select key). Both are verified PRESENT before substitution: a
    /// missing token means the template lost its placeholders and edition
    /// selection would silently break, so it's surfaced as a build problem.
    ///
    /// BACKSTOP (issue #6): before substituting, a DEFAULTED edition is
    /// asserted to be on the disc's edition list (recorded by the validation
    /// gate). The gate already hard-stops this case, so the assert should be
    /// unreachable — it exists to catch any future call path that skips the
    /// gate, and its message says "build problem" accordingly. A USER-CHOSEN
    /// edition is deliberately NOT asserted (the warn tier exists precisely
    /// because the disc may name it differently and the user consciously
    /// proceeded), and no assert is possible when the gate couldn't read the
    /// wim (discEditionNames nil — the warn tier covered that).
    ///
    /// FAT image recipe (proven in bare Terminal AND green in-app):
    ///   - 8MB zero-filled file (written by FileManager — no dd child process)
    ///   - mformat -i <img> -v UNATTEND -T 16384 -h 16 -s 63 ::  (8MB geometry,
    ///     read back off the proven experiment image with file(1) — NOT scaled
    ///     from the old 2MB "-T 4096 -s 32" by arithmetic; the -f 1440 floppy
    ///     preset FAILS on non-1.44MB images)
    ///   - mcopy -n -i <img> <filled.xml> ::autounattend.xml     (-n avoids
    ///     interactive overwrite prompts that would hang the pipeline)
    ///   - MTOOLS_SKIP_CHECK=1 in the environment suppresses geometry warnings
    ///   - invoked via the mformat/mcopy/mdir SYMLINKS (dispatch is by argv[0])
    ///   - NO DYLD_LIBRARY_PATH (see file header — it kills mtools via a
    ///     shadowed libiconv)
    ///   - mtools paths are passed as their own argv elements (safe with spaces);
    ///     only command-STRING contents need quoting (see PATHS WITH SPACES)
    ///
    /// Postcondition: PER-FILE `mdir ::<name>` succeeds for autounattend.xml
    /// and every payload file. Per-file (exit-code) checks, NOT a listing
    /// substring match: mdir prints 8.3-compliant names COLUMN-SPLIT
    /// ("vioser   inf"), so contains("vioser.inf") on the listing would
    /// false-negative on every good image — proven in bare Terminal with the
    /// bundled mtools version, 2026-08-15. Per-file mdir is case-insensitive,
    /// works for both 8.3 and long names, and exits 1 on a miss.
    private func stageBuildAnswerImage(input: PipelineInput, scratch: URL) async throws {
        let mformat = try toolURL(named: "mformat")
        let mcopy = try toolURL(named: "mcopy")
        let mdir = try toolURL(named: "mdir")
        let mtoolsEnv = ["MTOOLS_SKIP_CHECK": "1"]

        // --- The resolved edition MUST exist (set at the top of run()). Its
        // absence means a call path reached Stage 4 without running run()'s
        // resolution — a build problem by definition. ---
        guard let resolved = resolvedEdition else {
            throw PipelineError.stageFailed(
                stage: .buildAnswerImage,
                reason: "The edition to install was never resolved. This is a build problem, not something you did."
            )
        }

        // --- BACKSTOP (issue #6): a DEFAULTED edition must be on the disc's
        // list. The validation gate hard-stops this case, so firing here means
        // a code path skipped the gate. See the doc comment for why user-chosen
        // and unreadable-wim runs are exempt. ---
        if resolved.wasDefaulted, let names = discEditionNames, !names.contains(resolved.name) {
            throw PipelineError.stageFailed(
                stage: .buildAnswerImage,
                reason: "The edition \(resolved.name) is not on this ISO, and the earlier check that should have caught this didn't run. This is a build problem, not something you did."
            )
        }

        // --- Read the bundled template. ---
        guard let templateURL = Bundle.main.url(forResource: "autounattend", withExtension: "xml") else {
            throw PipelineError.toolNotFound("autounattend.xml")
        }
        let template: String
        do {
            template = try String(contentsOf: templateURL, encoding: .utf8)
        } catch {
            throw PipelineError.stageFailed(
                stage: .buildAnswerImage,
                reason: "Couldn't read the bundled answer-file template. (\(error.localizedDescription))"
            )
        }

        // --- Verify both tokens are present BEFORE substituting. A template that
        // lost its placeholders would otherwise produce an answer file with the
        // token text (or a stale hardcoded edition) and the install would silently
        // diverge from the user's choice. This is a build problem — say so. ---
        for token in [editionToken, productKeyToken] {
            guard template.contains(token) else {
                throw PipelineError.stageFailed(
                    stage: .buildAnswerImage,
                    reason: "The answer-file template is missing its \(token) placeholder. This is a build problem, not something you did."
                )
            }
        }

        // --- Substitute from the RESOLVED pair (no local fallback — the single
        // resolution point at the top of run() is the only place defaults can
        // engage; issue #6). ---
        let filled = template
            .replacingOccurrences(of: editionToken, with: resolved.name)
            .replacingOccurrences(of: productKeyToken, with: resolved.key)

        // --- Write the filled XML to scratch. ---
        let filledXMLURL = scratch.appendingPathComponent("autounattend-filled.xml")
        do {
            try filled.write(to: filledXMLURL, atomically: true, encoding: .utf8)
        } catch {
            throw PipelineError.stageFailed(
                stage: .buildAnswerImage,
                reason: "Couldn't write the filled answer file. (\(error.localizedDescription))"
            )
        }

        // --- Create the blank 8MB image (zero-filled; FileManager, no dd). ---
        let imageURL = answerImageURL(in: scratch)
        try? FileManager.default.removeItem(at: imageURL)
        let blank = Data(count: 8_388_608)   // 8MB, matching the proven mformat geometry
        do {
            try blank.write(to: imageURL)
        } catch {
            throw PipelineError.stageFailed(
                stage: .buildAnswerImage,
                reason: "Couldn't create the answer-file disk image. (\(error.localizedDescription))"
            )
        }

        // --- Format FAT12, label UNATTEND, proven 8MB geometry (read back off
        // the 2026-08-15 experiment image: 16384 sectors, 16 heads, 63 s/track). ---
        let formatResult = await runTool(mformat, [
            "-i", imageURL.path,
            "-v", "UNATTEND",
            "-T", "16384", "-h", "16", "-s", "63",
            "::"
        ], extraEnvironment: mtoolsEnv)
        guard formatResult.code == 0 else {
            throw PipelineError.stageFailed(
                stage: .buildAnswerImage,
                reason: "Couldn't format the answer-file disk image. (mformat exit \(formatResult.code): \(formatResult.output.prefix(300)))"
            )
        }

        // --- Copy the filled XML to the image root as autounattend.xml. ---
        let copyResult = await runTool(mcopy, [
            "-n",
            "-i", imageURL.path,
            filledXMLURL.path,
            "::autounattend.xml"
        ], extraEnvironment: mtoolsEnv)
        guard copyResult.code == 0 else {
            throw PipelineError.stageFailed(
                stage: .buildAnswerImage,
                reason: "Couldn't copy the answer file into the disk image. (mcopy exit \(copyResult.code): \(copyResult.output.prefix(300)))"
            )
        }

        // --- Copy the guest-agent payload to the image root (vioserial triple +
        // vdagent MSI under its 8.3 name — see answerImagePayload's doc). Source
        // presence is checked first: a missing bundled file is a build problem
        // (Run Script didn't stage it), surfaced before mcopy can fail cryptically. ---
        for item in answerImagePayload {
            let srcDir = try resourceDirURL(named: item.resourceDir)
            let srcFile = srcDir.appendingPathComponent(item.sourceName)
            guard FileManager.default.fileExists(atPath: srcFile.path) else {
                throw PipelineError.stageFailed(
                    stage: .buildAnswerImage,
                    reason: "The bundled \(item.sourceName) payload file is missing from the app. This is a build problem, not something you did."
                )
            }
            let payloadCopy = await runTool(mcopy, [
                "-n",
                "-i", imageURL.path,
                srcFile.path,
                "::\(item.imageName)"
            ], extraEnvironment: mtoolsEnv)
            guard payloadCopy.code == 0 else {
                throw PipelineError.stageFailed(
                    stage: .buildAnswerImage,
                    reason: "Couldn't copy \(item.imageName) into the answer-file disk image. (mcopy exit \(payloadCopy.code): \(payloadCopy.output.prefix(300)))"
                )
            }
        }

        // --- Postcondition: PER-FILE mdir for autounattend.xml and every
        // payload file (exit 0 = present; see the doc comment for why a
        // listing substring match is WRONG for 8.3 names). A silent
        // autounattend.xml miss would mean Setup finds an empty answer volume
        // and runs interactively; a silent payload miss would mean the
        // specialize if-exist guards no-op and the guest lands at OOBE without
        // absolute mouse — both are exactly the failures this pipeline exists
        // to prevent, and each is named on failure. ---
        var expectedNames = ["autounattend.xml"]
        expectedNames.append(contentsOf: answerImagePayload.map { $0.imageName })
        for name in expectedNames {
            let fileCheck = await runTool(mdir, ["-i", imageURL.path, "::\(name)"], extraEnvironment: mtoolsEnv)
            guard fileCheck.code == 0 else {
                throw PipelineError.postconditionFailed(
                    stage: .buildAnswerImage,
                    reason: "\(name) didn't land inside the answer-file disk image."
                )
            }
        }

        pipelineLog("stageBuildAnswerImage: built \(imageURL.lastPathComponent) — edition \"\(resolved.name)\" (\(resolved.wasDefaulted ? "default" : "user-selected")), \(expectedNames.count) files verified via per-file mdir")
    }

    // MARK: - Stage 5 — Rebuild bootable ISO (implemented; appended-partition method)

    /// Rebuild a bootable ISO from the MODIFIED scratch iso-tree, carrying the
    /// injected boot.wim, the $WinPEDriver$ tree, and everything else. Proven in
    /// Terminal AND in-app, and the output BOOT-PROVEN with xorriso 1.5.8.
    ///
    /// JOLIET (-J -joliet-long) is REQUIRED in the rebuild — DO NOT REMOVE.
    /// Without it, "$WinPEDriver$" is stored MANGLED ("_WINPEDRIVER_") in the
    /// plain ISO 9660 namespace (`$` is illegal there), Windows CDFS reads that
    /// namespace when no Joliet exists, Setup's literal folder scan misses the
    /// drivers, and OOBE demands a network driver a blind user can't provide.
    /// Root-caused via the guest's setupapi.dev.log (host-side tools display
    /// Rock Ridge names and cannot see the mangling); the Joliet fix is
    /// guest-proven — a fresh install passed OOBE networking with no driver
    /// prompt, and the Joliet namespace carries the name verbatim (verified at
    /// the byte level, UTF-16BE).
    ///
    /// Four moves, each checked:
    ///   1. Parse el-torito off the ORIGINAL ISO (Ldsiz/LBA/Volume id — xorriso
    ///      CAN read the boot record and raw bytes even though it can't read the
    ///      UDF tree). A zero source Ldsiz is a hard stage failure: it means an
    ///      EFI layout we don't understand, and any rebuild from it won't boot.
    ///   2. dd-extract the EFI boot image at the COMPUTED offsets (LBA is in
    ///      2048-byte sectors, Ldsiz in 512-byte blocks: bs=512
    ///      skip=LBA*2048/512 count=Ldsiz). Postcondition: exactly Ldsiz*512
    ///      bytes — a wrong count silently grabs gigabytes of ISO instead.
    ///   3. Rebuild with the appended-partition method + Joliet (the ONLY method
    ///      proven to produce a non-zero Ldsiz our edk2 firmware boots; `replay`
    ///      gives Ldsiz 0 -> UEFI shell). All paths here are their own argv
    ///      elements — safe with spaces; no command-string quoting needed in
    ///      this stage.
    ///   4. Postcondition: re-report el-torito on the OUTPUT and require a
    ///      non-zero Ldsiz. (Necessary but NOT sufficient — the pinned xorriso
    ///      1.5.8+ is the real bootability guarantee.)
    private func stageRebuildISO(input: PipelineInput, scratch: URL) async throws {
        let xorriso = try toolURL(named: "xorriso")
        let dd = URL(fileURLWithPath: "/bin/dd")
        let tree = isoTreeURL(in: scratch)
        let outputISO = rebuiltISOURL(in: scratch)

        guard FileManager.default.fileExists(atPath: tree.path) else {
            throw PipelineError.stageFailed(
                stage: .rebuildISO,
                reason: "The extracted installer files weren't found. An earlier step may not have completed."
            )
        }

        // --- 1. Parse el-torito off the ORIGINAL ISO. ---
        let reportResult = await runTool(xorriso, [
            "-indev", input.sourceISOPath,
            "-report_el_torito", "plain"
        ])
        guard reportResult.code == 0 else {
            throw PipelineError.stageFailed(
                stage: .rebuildISO,
                reason: "Couldn't read the boot information from the Windows ISO — it may not be a bootable installer. (xorriso exit \(reportResult.code))"
            )
        }
        guard let elTorito = parseElTorito(reportResult.output) else {
            throw PipelineError.stageFailed(
                stage: .rebuildISO,
                reason: "The Windows ISO's boot information couldn't be understood. It may not be a standard Windows installer ISO."
            )
        }
        guard elTorito.ldsiz > 0 else {
            throw PipelineError.stageFailed(
                stage: .rebuildISO,
                reason: "The Windows ISO's boot image has an unusual layout AVM can't rebuild. It may not be a standard Windows installer ISO."
            )
        }
        pipelineLog("stageRebuildISO: source el-torito — Ldsiz \(elTorito.ldsiz), LBA \(elTorito.lba), volid \(elTorito.volumeID)")

        // --- 2. dd-extract the EFI boot image at the computed offsets. ---
        // Units are MIXED: LBA in 2048-byte sectors, Ldsiz in 512-byte blocks.
        let skip = elTorito.lba * 2048 / 512
        let expectedBytes = elTorito.ldsiz * 512
        let efibootURL = scratch.appendingPathComponent("efiboot.img")
        try? FileManager.default.removeItem(at: efibootURL)

        let ddResult = await runTool(dd, [
            "if=\(input.sourceISOPath)",
            "of=\(efibootURL.path)",
            "bs=512",
            "skip=\(skip)",
            "count=\(elTorito.ldsiz)"
        ])
        guard ddResult.code == 0 else {
            throw PipelineError.stageFailed(
                stage: .rebuildISO,
                reason: "Couldn't extract the boot image from the Windows ISO. (dd exit \(ddResult.code))"
            )
        }

        // Postcondition on the extraction: EXACTLY Ldsiz*512 bytes. A wrong count
        // grabs the rest of the ISO (gigabytes) and the rebuild would produce an
        // unbootable monster — catch it here.
        let efibootSize = (try? FileManager.default.attributesOfItem(atPath: efibootURL.path)[.size] as? Int) ?? 0
        guard (efibootSize ?? 0) == expectedBytes else {
            throw PipelineError.postconditionFailed(
                stage: .rebuildISO,
                reason: "The extracted boot image is the wrong size (\(efibootSize ?? 0) bytes, expected \(expectedBytes))."
            )
        }
        pipelineLog("stageRebuildISO: extracted efiboot.img — \(expectedBytes) bytes, verified exact")

        // --- 3. Rebuild with the appended-partition method + Joliet (proven
        // invocation; -J -joliet-long carry $WinPEDriver$ verbatim in the Joliet
        // namespace Windows prefers — see the doc comment). This is the slow
        // step on slower machines. ---
        try? FileManager.default.removeItem(at: outputISO)
        let rebuildResult = await runTool(xorriso, [
            "-as", "mkisofs",
            "-iso-level", "3",
            "-V", elTorito.volumeID,
            "-J", "-joliet-long",
            "-append_partition", "2", "0xef", efibootURL.path,
            "-appended_part_as_gpt",
            "-e", "--interval:appended_partition_2:all::",
            "-no-emul-boot",
            "-o", outputISO.path,
            tree.path
        ])
        guard rebuildResult.code == 0 else {
            throw PipelineError.stageFailed(
                stage: .rebuildISO,
                reason: "Couldn't build the modified installer ISO. (xorriso exit \(rebuildResult.code): \(rebuildResult.output.suffix(300)))"
            )
        }

        // --- 4. Postcondition: the OUTPUT's el-torito must show a non-zero
        // Ldsiz. Zero means our edk2 firmware won't boot it (falls to the UEFI
        // shell) — the launch path must never receive such an ISO. ---
        let verifyResult = await runTool(xorriso, [
            "-indev", outputISO.path,
            "-report_el_torito", "plain"
        ])
        guard verifyResult.code == 0,
              let rebuiltInfo = parseElTorito(verifyResult.output),
              rebuiltInfo.ldsiz > 0 else {
            throw PipelineError.postconditionFailed(
                stage: .rebuildISO,
                reason: "The rebuilt installer ISO isn't bootable. This shouldn't happen with a standard Windows ISO."
            )
        }

        pipelineLog("stageRebuildISO: rebuilt \(outputISO.lastPathComponent) — output Ldsiz \(rebuiltInfo.ldsiz), verified bootable, Joliet enabled")
    }

    // MARK: - Stage 6 — Promote (implemented)

    /// Move the verified rebuilt ISO + answer image from scratch into the VM
    /// runtime dir under their final names. Only reached if every prior stage +
    /// postcondition passed, so the launch path never finds a half-built
    /// artifact. Scratch and the runtime dir both live under Application
    /// Support, so the move is a cheap same-volume rename, not a copy.
    /// Postcondition: both artifacts exist at their destinations, non-empty.
    private func stagePromote(input: PipelineInput, scratch: URL) async throws {
        let fm = FileManager.default

        // Ensure the runtime dir exists (it normally does — VMManager creates
        // it — but the pipeline shouldn't assume).
        do {
            try fm.createDirectory(at: input.runtimeDir, withIntermediateDirectories: true)
        } catch {
            throw PipelineError.stageFailed(
                stage: .promote,
                reason: "Couldn't access the virtual machine's folder. (\(error.localizedDescription))"
            )
        }

        let moves: [(src: URL, destName: String)] = [
            (rebuiltISOURL(in: scratch), "install-avm.iso"),
            (answerImageURL(in: scratch), "autounattend.img")
        ]

        for move in moves {
            guard fm.fileExists(atPath: move.src.path) else {
                throw PipelineError.stageFailed(
                    stage: .promote,
                    reason: "The built file \(move.destName) wasn't found. An earlier step may not have completed."
                )
            }
            let dst = input.runtimeDir.appendingPathComponent(move.destName)
            // Remove any stale artifact from a previous create so the move can't
            // collide.
            try? fm.removeItem(at: dst)
            do {
                try fm.moveItem(at: move.src, to: dst)
            } catch {
                throw PipelineError.stageFailed(
                    stage: .promote,
                    reason: "Couldn't move \(move.destName) into the virtual machine's folder. (\(error.localizedDescription))"
                )
            }
        }

        // Postcondition: both artifacts present and non-empty at the destination.
        for move in moves {
            let dst = input.runtimeDir.appendingPathComponent(move.destName)
            let size = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
            guard (size ?? 0) > 0 else {
                throw PipelineError.postconditionFailed(
                    stage: .promote,
                    reason: "The file \(move.destName) is missing or empty after finalizing."
                )
            }
        }

        pipelineLog("stagePromote: promoted install-avm.iso + autounattend.img to \(input.runtimeDir.path)")
    }

    // MARK: - Scratch Lifecycle

    /// Create a fresh, empty scratch dir for this build (siblings the runtime dir
    /// under Application Support, so it's on the same volume — promotion is a
    /// cheap rename, not a cross-volume copy). Any prior scratch for this VM is
    /// removed first. Runs off the main actor (a stale multi-GB scratch removal
    /// must not block the UI).
    private func makeScratchDir(for vmID: UUID) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport
            .appendingPathComponent("AVM")
            .appendingPathComponent("scratch")
            .appendingPathComponent(vmID.uuidString)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Remove the scratch dir (on success or failure). Best-effort; a leftover
    /// scratch dir is reclaimable and never on the launch path. Runs off the
    /// main actor (this removes a multi-GB tree — it must not block the UI).
    private func cleanScratch() {
        if let scratch = scratchDir {
            try? FileManager.default.removeItem(at: scratch)
            pipelineLog("cleanScratch: removed \(scratch.path)")
        }
        scratchDir = nil
    }
}
