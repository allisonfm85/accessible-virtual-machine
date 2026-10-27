// MacGuest.swift
// AVM — Accessible Virtual Machine
//
// macOS virtual machines (2026-10-26). QEMU can't run macOS on Apple
// Silicon, so a macOS machine runs on Apple's own Virtualization framework
// (the com.apple.security.virtualization entitlement AVM already has), a
// second engine beside QEMU. It shares AVM's dashboard list, spoken status
// and settings store; the parts that differ are here:
//
//   MacGuestFiles  — a macOS machine's files in its VM folder: the disk
//                    (raw, sparse), auxiliary storage, hardware model and
//                    machine identifier.
//   MacInstaller   — gets macOS from Apple (the newest this Mac supports,
//                    VZMacOSRestoreImage) or from an IPSW the user has,
//                    and installs it, saying how far it has got.
//   MacGuestRunner — starts a machine in its own window (Apple's
//                    VZVirtualMachineView), with sound, the shared folder
//                    and a clean shutdown when the window closes.
//
// THE KEYBOARD (same model as Windows, 2026-10-26): Command-Shift-E
// (Virtual Machine > Enter macOS) brings the machine's window forward and
// gives macOS the keyboard; Control-Command-Escape gives it back to the
// Mac and the machine keeps running. Command-Tab still switches apps. The
// machine's screen is a picture VoiceOver can't read, so the window has a
// bar above it that it can: where the keyboard is, a button to give macOS
// the keyboard, and Shut Down. The
// Mac's VoiceOver keeps the VoiceOver keys (Control-Option), so to use
// VoiceOver inside the machine, turn the Mac's VoiceOver off with
// Command-F5 while working there, as with Windows and JAWS or NVDA.
// VOICEOVER INSIDE: macOS Setup Assistant offers it itself: wait on its
// first screen with macOS holding the keyboard, and press Escape when it
// speaks; macOS then keeps VoiceOver on for good. (AVM's own Command-F5
// sender was removed, 2026-10-26: it never reached the machine, and typed
// Command-F5 can only reach it by capturing the keyboard, which also
// blocked the way back to the Mac.)

import AppKit
import Carbon.HIToolbox
import Combine
import Virtualization

// MARK: - Configuration

@MainActor
enum MacGuestConfiguration {

    /// The machine as Apple's framework runs it, from AVM's settings.
    static func make(_ config: VMConfiguration, files: MacGuestFiles,
                     hardwareModel: VZMacHardwareModel? = nil,
                     clipboardFolder: URL? = nil) throws -> VZVirtualMachineConfiguration {
        let model: VZMacHardwareModel
        if let hardwareModel {
            model = hardwareModel
        } else {
            guard let data = try? Data(contentsOf: files.hardwareModel),
                  let loaded = VZMacHardwareModel(dataRepresentation: data) else {
                throw MacGuestError("This macOS machine's hardware model is missing or damaged.")
            }
            model = loaded
        }
        guard model.isSupported else {
            throw MacGuestError("This Mac can't run the version of macOS installed in this machine.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: files.auxiliaryStorage)
        guard let idData = try? Data(contentsOf: files.machineIdentifier),
              let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
            throw MacGuestError("This macOS machine's identifier is missing or damaged.")
        }
        platform.machineIdentifier = identifier

        let vz = VZVirtualMachineConfiguration()
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()
        vz.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                          min(config.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        vz.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                            min(UInt64(config.ramSizeGB) << 30, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        let disk = try VZDiskImageStorageDeviceAttachment(url: files.disk, readOnly: false)
        vz.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        if let text = try? String(contentsOf: files.macAddress, encoding: .utf8),
           let saved = VZMACAddress(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            network.macAddress = saved
        } else {
            let fresh = VZMACAddress.randomLocallyAdministered()
            network.macAddress = fresh
            try? fresh.string.write(to: files.macAddress, atomically: true, encoding: .utf8)
        }
        vz.networkDevices = [network]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)]
        vz.graphicsDevices = [graphics]

        // A Mac keyboard, not a generic USB one (2026-10-26, "Return and
        // Escape still thunk" with keys reaching the machine's screen and
        // no modifier held): macOS meeting an unknown USB keyboard opens
        // Keyboard Setup Assistant ("your keyboard can't be identified"),
        // a window that sits over Setup Assistant, takes Return and Escape,
        // and that VoiceOver users can't see. Apple's Mac keyboard device
        // (macOS 14 and later) is one macOS knows, so it never asks.
        if #available(macOS 14.0, *) {
            vz.keyboards = [VZMacKeyboardConfiguration()]
        } else {
            vz.keyboards = [VZUSBKeyboardConfiguration()]
        }
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Sound out only: VoiceOver's speech in the machine comes out of the
        // Mac. No microphone, so no microphone permission is asked.
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        vz.audioDevices = [sound]

        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // The shared folder appears in the machine's Finder by itself, as
        // "My Shared Files", in /Volumes. With clipboard sharing
        // (MacClipboard.swift) there are two folders, so each is a folder
        // inside My Shared Files: the user's by its own name, and AVM
        // Clipboard.
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        if let clipboardFolder {
            var directories = [MacClipboard.folderName: VZSharedDirectory(url: clipboardFolder, readOnly: false)]
            if let shared = config.sharedFolderURL {
                directories[shared.lastPathComponent] = VZSharedDirectory(url: shared, readOnly: config.sharedFolderIsReadOnly)
            }
            fs.share = VZMultipleDirectoryShare(directories: directories)
            vz.directorySharingDevices = [fs]
        } else if let shared = config.sharedFolderURL {
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: shared, readOnly: config.sharedFolderIsReadOnly))
            vz.directorySharingDevices = [fs]
        }

        try vz.validate()
        return vz
    }
}

// MARK: - Installing

@MainActor
final class MacInstaller: NSObject, URLSessionDownloadDelegate {

    /// Says how far it has got; the wizard shows the same line.
    var onProgress: ((String) -> Void)?

    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var downloadDestination: URL?
    private var lastSpokenGB = 0
    private var installObservation: NSKeyValueObservation?

    /// Where downloaded macOS restore images are kept, so a second machine
    /// doesn't download one again.
    static var cacheFolder: URL {
        let support = (try? AVMPaths.supportDirectory())
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(AVMPaths.supportFolderName)
        return support.appendingPathComponent("macos-restore-images")
    }

    /// Installs macOS into `config`'s folder: from `ipsw` if given, else
    /// the newest macOS this Mac supports, from Apple.
    func install(_ config: VMConfiguration, ipsw: URL?) async throws {
        let folder = try config.directoryURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = MacGuestFiles(folder: folder)

        let imageURL = try await restoreImage(ipsw)
        say("Checking the macOS installer.")
        let image = try await VZMacOSRestoreImage.image(from: imageURL)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw MacGuestError("This Mac can't run macOS \(image.operatingSystemVersion.description). Next: choose an older macOS installer.")
        }
        if config.cpuCount < requirements.minimumSupportedCPUCount || UInt64(config.ramSizeGB) << 30 < requirements.minimumSupportedMemorySize {
            throw MacGuestError("macOS \(image.operatingSystemVersion.description) needs at least \(requirements.minimumSupportedCPUCount) cores and \(requirements.minimumSupportedMemorySize >> 30) gigabytes of memory. Next: give the machine more, then try again.")
        }

        // The machine's own files.
        try requirements.hardwareModel.dataRepresentation.write(to: files.hardwareModel)
        try VZMacMachineIdentifier().dataRepresentation.write(to: files.machineIdentifier)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: files.auxiliaryStorage, hardwareModel: requirements.hardwareModel, options: [.allowOverwrite])
        FileManager.default.createFile(atPath: files.disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: files.disk)
        try handle.truncate(atOffset: UInt64(config.diskSizeGB) << 30)   // sparse: grows as used
        try handle.close()

        let vz = try MacGuestConfiguration.make(config, files: files, hardwareModel: requirements.hardwareModel)
        let machine = VZVirtualMachine(configuration: vz)
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: imageURL)
        say("Installing macOS \(image.operatingSystemVersion.description). This takes about 15 to 30 minutes.")
        var lastTenth = 0
        installObservation = installer.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let tenth = Int(progress.fractionCompleted * 10)
            DispatchQueue.main.async {
                guard tenth > lastTenth, tenth < 10 else { return }
                lastTenth = tenth
                self?.say("macOS install \(tenth * 10) percent.")
            }
        }
        defer { installObservation = nil }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            installer.install { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
        AVMLog.write("AVM: MacGuest — installed macOS \(image.operatingSystemVersion.description) in \(config.name).")
        // A restore point of the fresh install, free on APFS (2026-10-26).
        do {
            try MacRestorePoints.take(files, name: "Fresh install of macOS \(image.operatingSystemVersion.description)")
        } catch {
            AVMLog.write("AVM: MacGuest — no fresh-install restore point: \(error.localizedDescription)")
        }
    }

    private func restoreImage(_ ipsw: URL?) async throws -> URL {
        if let ipsw { return ipsw }
        say("Asking Apple for the newest macOS this Mac can run.")
        let latest = try await VZMacOSRestoreImage.latestSupported
        let fm = FileManager.default
        try fm.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
        let cached = Self.cacheFolder.appendingPathComponent(latest.url.lastPathComponent)
        if fm.fileExists(atPath: cached.path) {
            say("Using the macOS \(latest.operatingSystemVersion.description) installer downloaded before.")
            return cached
        }
        // The size comes from the download itself (26 GB for macOS 27.0.1,
        // 2026-10-26), in the first progress line.
        say("Downloading macOS \(latest.operatingSystemVersion.description) from Apple. It's large, usually over 15 gigabytes; AVM says how far it has got every gigabyte.")
        lastSpokenGB = 0
        downloadDestination = cached
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        return try await withCheckedThrowingContinuation { cont in
            downloadContinuation = cont
            session.downloadTask(with: latest.url).resume()
        }
    }

    // URLSessionDownloadDelegate, on the main queue.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            let gb = Int(totalBytesWritten / 1_000_000_000)
            guard gb > lastSpokenGB else { return }
            lastSpokenGB = gb
            let total = totalBytesExpectedToWrite > 0 ? " of \(Int(totalBytesExpectedToWrite / 1_000_000_000))" : ""
            say("macOS download: \(gb)\(total) gigabytes.")
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let destination = downloadDestination else { return }
            do {
                // Only a real download is kept (2026-10-26, code audit): an
                // error page saved as the installer was "used" again every
                // time after, and failed every time.
                if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw MacGuestError("Apple's server answered \(http.statusCode) instead of sending macOS. Next: try again later.")
                }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                downloadContinuation?.resume(returning: destination)
            } catch {
                downloadContinuation?.resume(throwing: error)
            }
            downloadContinuation = nil
            session.finishTasksAndInvalidate()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                downloadContinuation?.resume(throwing: MacGuestError("The macOS download stopped. Reason: \(error.localizedDescription)"))
                downloadContinuation = nil
            }
            session.finishTasksAndInvalidate()
        }
    }

    private func say(_ message: String) {
        onProgress?(message)
        Announcer.shared.announce(message, tone: .info)
        AVMLog.write("AVM: MacGuest — \(message)")
    }
}

extension VZMacOSRestoreImage {
    @MainActor static func image(from url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.load(from: url) { cont.resume(with: $0) }
        }
    }

    @MainActor static var latestSupported: VZMacOSRestoreImage {
        get async throws {
            try await withCheckedThrowingContinuation { cont in
                VZMacOSRestoreImage.fetchLatestSupported { cont.resume(with: $0) }
            }
        }
    }
}

extension OperatingSystemVersion {
    nonisolated var description: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}

// MARK: - Running

@MainActor
final class MacGuestRunner: NSObject, ObservableObject, VZVirtualMachineDelegate, NSWindowDelegate {
    static let shared = MacGuestRunner()

    @Published private(set) var runningID: UUID?
    @Published private(set) var keyboardInGuest = false
    private var machineView: VZVirtualMachineView?
    private var statusLabel: NSTextField?
    private weak var giveButton: NSButton?
    /// The first "Entering macOS" of a run adds the key back; later ones
    /// are just the two words.
    private var hintGiven = false
    /// How many keys went to macOS, and how many were typed into another
    /// window while macOS should have had them, per stretch in macOS:
    /// counts only, for the log; which keys is never kept.
    private var keysToMacOS = 0
    private var keysElsewhere = 0
    /// Spoken as "Entering macOS" whatever the machine is called.
    private let guestName = "macOS"
    private var keyMonitor: Any?
    private var machine: VZVirtualMachine?
    private var files: MacGuestFiles?
    /// New at every start, so timers from an earlier run can tell.
    private var runToken = UUID()
    private var clipboard: MacClipboard?
    private var vzConfiguration: VZVirtualMachineConfiguration?
    private var window: NSWindow?
    private var name = "macOS"

    func start(_ config: VMConfiguration, attempt: Int = 1) {
        if runningID == config.id {
            window?.makeKeyAndOrderFront(nil)
            Announcer.shared.announce("\(config.name) is already running; its window is in front.", tone: .info)
            return
        }
        guard runningID == nil else {
            Announcer.shared.announce("Another macOS machine is running. Shut it down first.", tone: .failure)
            return
        }
        do {
            let files = MacGuestFiles(folder: try config.directoryURL())
            guard files.isInstalled else {
                throw MacGuestError("macOS isn't installed in \(config.name). Next: delete it and make it again with New macOS Virtual Machine.")
            }
            clipboard = config.sharesClipboard ? (try? MacClipboard(vmFolder: files.folder)) : nil
            let vz = try MacGuestConfiguration.make(config, files: files, clipboardFolder: clipboard?.sharedDirectory)
            clipboard?.start()
            let machine = VZVirtualMachine(configuration: vz)
            machine.delegate = self
            self.machine = machine
            self.vzConfiguration = vz
            runningID = config.id
            runToken = UUID()
            name = config.name
            showWindow(for: machine, title: config.name)
            self.files = files
            if #available(macOS 14.0, *), FileManager.default.fileExists(atPath: files.savedState.path) {
                resume(machine, config: config, files: files)
                return
            }
            Announcer.shared.announce("Starting \(config.name).", tone: .info)
            coldStart(machine, config: config, attempt: attempt)
        } catch {
            clipboard?.stop()
            clipboard = nil
            // Just after an install (2026-10-26, measured by the macOS
            // test): the installer's machine still holds the auxiliary
            // storage for a few seconds, and the start fails with "Failed
            // to lock auxiliary storage". Tried again, quietly, for 15 s.
            if error.localizedDescription.localizedCaseInsensitiveContains("lock"), attempt < 6 {
                AVMLog.write("AVM: MacGuest — \(config.name)'s files are still in use (\(error.localizedDescription)); trying again in 3 seconds.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated { self?.start(config, attempt: attempt + 1) }
                }
                return
            }
            Announcer.shared.announce("\(config.name) could not start. Reason: \(error.localizedDescription)", tone: .failure)
        }
    }

    private func coldStart(_ machine: VZVirtualMachine, config: VMConfiguration, attempt: Int = 1) {
        machine.start { [weak self] result in
            guard let self else { return }
            // The installer's lock on the files (see start()) can also
            // show here, as the machine starts: closed quietly and
            // started again.
            if case .failure(let error) = result,
               error.localizedDescription.localizedCaseInsensitiveContains("lock"), attempt < 6 {
                AVMLog.write("AVM: MacGuest — \(config.name)'s files are still in use as it starts (\(error.localizedDescription)); trying again in 3 seconds.")
                self.ended(spoken: nil, tone: .info)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated { self?.start(config, attempt: attempt + 1) }
                }
                return
            }
            switch result {
            case .success:
                AVMLog.write("AVM: MacGuest — \(config.name) started.")
                Announcer.shared.announce("\(config.name) is running.", tone: .success)
                self.enter()
                self.offerVoiceOverOnce(config)
            case .failure(let error):
                self.ended(spoken: "\(config.name) could not start. Reason: \(error.localizedDescription)", tone: .failure)
            }
        }
    }

    // MARK: Saved state (2026-10-26)

    /// The machine as it was when saved, running again in seconds instead
    /// of a 3-minute start. The saved file is used once: it's deleted as
    /// soon as the machine runs from it (the disk moves on from there), or
    /// if it can't be used, and then the machine starts as usual.
    @available(macOS 14.0, *)
    private func resume(_ machine: VZVirtualMachine, config: VMConfiguration, files: MacGuestFiles) {
        Announcer.shared.announce("Resuming \(config.name) where you left it.", tone: .info)
        machine.restoreMachineStateFrom(url: files.savedState) { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let error {
                        AVMLog.write("AVM: MacGuest — saved state not usable: \(error.localizedDescription); starting as usual.")
                        try? FileManager.default.removeItem(at: files.savedState)
                        Announcer.shared.announce("\(config.name) couldn't resume, so it's starting as usual. Reason: \(error.localizedDescription)", tone: .info)
                        self.coldStart(machine, config: config)
                        return
                    }
                    machine.resume { result in
                        try? FileManager.default.removeItem(at: files.savedState)
                        switch result {
                        case .success:
                            AVMLog.write("AVM: MacGuest — \(config.name) resumed from its saved state.")
                            Announcer.shared.announce("\(config.name) is running again.", tone: .success)
                            self.enter()
                        case .failure(let error):
                            self.ended(spoken: "\(config.name) could not resume. Reason: \(error.localizedDescription) Start it again to start it as usual.", tone: .failure)
                        }
                    }
                }
            }
        }
    }

    /// True if this machine can be saved and resumed (macOS 14 and later,
    /// and a configuration Apple's framework can save).
    var canSave: Bool {
        guard #available(macOS 14.0, *), let machine, let vzConfiguration,
              machine.state == .running || machine.state == .paused else { return false }
        do {
            try vzConfiguration.validateSaveRestoreSupport()
            return true
        } catch {
            AVMLog.write("AVM: MacGuest — this machine can't be saved: \(error.localizedDescription)")
            return false
        }
    }

    /// Pauses the machine, saves it to disk and stops it; the next Start
    /// resumes it. `done` gets whether it was saved.
    func saveAndStop(done: @escaping @MainActor (Bool) -> Void) {
        guard #available(macOS 14.0, *), let machine, let files else { done(false); return }
        if keyboardInGuest { leave() }
        Announcer.shared.announce("Saving \(name).", tone: .info)
        let finish: @MainActor (Error?) -> Void = { [weak self] error in
            guard let self else { done(false); return }
            if let error {
                AVMLog.write("AVM: MacGuest — couldn't save: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: files.savedState)
                Announcer.shared.announce("\(self.name) couldn't be saved. Reason: \(error.localizedDescription)", tone: .failure)
                if machine.state == .paused { machine.resume { _ in } }
                done(false)
                return
            }
            AVMLog.write("AVM: MacGuest — saved; stopping.")
            machine.stop { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.ended(spoken: "\(self?.name ?? "macOS") is saved. Start it to carry on where you left it.", tone: .success)
                        done(true)
                    }
                }
            }
        }
        let save = {
            machine.saveMachineStateTo(url: files.savedState) { error in
                DispatchQueue.main.async { MainActor.assumeIsolated { finish(error) } }
            }
        }
        if machine.state == .paused {
            save()
        } else {
            machine.pause { result in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if case .failure(let error) = result { finish(error) } else { save() }
                    }
                }
            }
        }
    }

    // MARK: VoiceOver at the first start (2026-10-26)

    /// A new machine's first start: when Setup Assistant should be up
    /// (about 3 minutes, measured), AVM runs the Command-F5 pass itself,
    /// so turning on macOS's VoiceOver needs no button. Once per machine.
    private func offerVoiceOverOnce(_ config: VMConfiguration) {
        // false only for machines made since this existed (MacSetupView):
        // older ones have been through Setup Assistant already.
        guard config.macVoiceOverOffered == false else { return }
        var updated = VMStore.shared?.configurations.first { $0.id == config.id } ?? config
        updated.macVoiceOverOffered = true
        VMStore.shared?.save(updated)
        Announcer.shared.announce("When macOS's Setup Assistant is up, in about 3 minutes, AVM will ask you to press Command-F5 to turn on its VoiceOver.", tone: .info)
        let id = config.id
        // This run's, not a later one's (2026-10-26, code audit): a machine
        // stopped and started again inside 200 s had the first run's timer
        // capture its keys mid-start.
        let run = runToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 200) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runningID == id, self.runToken == run else { return }
                guard self.keyboardInGuest else {
                    Announcer.shared.announce("Setup Assistant should be up in \(self.name). To turn on its VoiceOver, choose Turn On VoiceOver in macOS in its window.", tone: .info)
                    return
                }
                AVMLog.write("AVM: MacGuest — first start: passing Command-F5 for macOS's VoiceOver.")
                self.passSystemKeysBriefly()
            }
        }
    }

    /// Asks macOS in the machine to shut down, as its power button would.
    func shutDown() {
        guard let machine, machine.canRequestStop else { forceStop(); return }
        do {
            try machine.requestStop()
            Announcer.shared.announce("Asked \(name) to shut down.", tone: .info)
        } catch {
            forceStop()
        }
    }

    func forceStop() {
        guard let machine else { return }
        machine.stop { [weak self] _ in
            self?.ended(spoken: "\(self?.name ?? "macOS") was turned off.", tone: .info)
        }
    }

    // MARK: Keyboard

    /// Gives macOS the keyboard: its window in front, its screen first
    /// responder. Command-Shift-E.
    func enter(spoken: String? = nil) {
        guard let window, let machineView else {
            NSSound.beep()
            return
        }
        // Set before the window becomes key, so windowDidBecomeKey leaves
        // the screen as first responder.
        setKeyboard(inGuest: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // The screen takes the keyboard only once every modifier is let go
        // (2026-10-26): Command-Shift-E is still held as this runs, and a
        // machine that sees Command go up without going down (or the other
        // way round) can be left thinking it's held, so Return arrives as
        // Command-Return.
        whenModifiersReleased { [weak self] in
            guard let self, self.keyboardInGuest, let window = self.window, let machineView = self.machineView else { return }
            // AVM wasn't let in front (2026-10-26, code audit: another app
            // was in front as a start finished, and macOS 14's activation
            // can refuse): keys would go to that app while AVM thinks macOS
            // has them, with Control-Command-Escape taken system-wide.
            guard window.isKeyWindow, NSApp.isActive else {
                self.releaseFullControl()
                self.setKeyboard(inGuest: false)
                Announcer.shared.announce("\(self.guestName) didn't get the keyboard, because AVM isn't in front. To give it the keyboard, switch to AVM and choose Enter macOS.", tone: .leaveGuest)
                AVMLog.write("AVM: MacGuest — keyboard NOT given to macOS: AVM's window isn't key.")
                return
            }
            window.makeFirstResponder(machineView)
            AVMLog.write("AVM: MacGuest — machine's screen is \(window.firstResponder === machineView ? "" : "NOT ")first responder; window is \(window.isKeyWindow ? "" : "NOT ")key; AVM is \(NSApp.isActive ? "" : "NOT ")active.")
        }
        // NEVER capturesSystemKeys = true here (2026-10-26, a user stuck in
        // macOS): Apple's capture takes the keyboard below AVM's key monitor
        // AND its system-wide hotkey, so Control-Command-Escape stopped
        // working and only quitting AVM got the keyboard back. Command-Tab
        // and Command-F5 stay the Mac's. The hotkey stays as a second way out.
        registerEscapeHotKey()
        // "Entering macOS", the same words every time, as for Windows; the
        // keys to know are added the first time only.
        // Both VoiceOvers at once (2026-10-26, "random VoiceOver dings"):
        // the Mac's VoiceOver takes its Control-Option chords, but the
        // machine still sees the Control and Option presses alone, and
        // macOS's VoiceOver dings at the half-chords. Said every time the
        // Mac's VoiceOver is on as macOS takes the keyboard.
        // AVM can't turn it off for good (measured; MacVoiceOver below), so
        // it asks for Command-F5, and turns it back on itself when the
        // keyboard leaves macOS.
        var entering = hintGiven ? "Entering \(guestName)" : "Entering \(guestName). Control-Command-Escape returns to your Mac."
        if MacVoiceOver.noteEnteringGuest() {
            entering += (entering.hasSuffix(".") ? " " : ". ") + "Press Command-F5 to turn your Mac's VoiceOver off while you're in \(guestName); AVM turns it back on when you return."
        }
        Announcer.shared.announce(entering, tone: .enterGuest)
        hintGiven = true
        AVMLog.write("AVM: MacGuest — keyboard to macOS.")
    }

    /// Gives the keyboard back to the Mac; the machine keeps running.
    /// Control-Command-Escape.
    func leave() {
        guard window != nil, keyboardInGuest else { return }
        // Off first, so windowDidResignKey doesn't announce it again.
        releaseFullControl()
        setKeyboard(inGuest: false)
        Announcer.shared.announce("Entering Mac", tone: .leaveGuest)
        // The machine keeps the keyboard until Control and Command are let
        // go, so it sees them come up rather than staying held.
        whenModifiersReleased { [weak self] in
            guard let self, !self.keyboardInGuest else { return }
            self.window?.makeFirstResponder(self.giveButton)
            if let main = NSApp.windows.first(where: { $0 !== self.window && $0.isVisible && $0.canBecomeMain }) {
                main.makeKeyAndOrderFront(nil)
            }
        }
        AVMLog.write("AVM: MacGuest — keyboard to the Mac.")
    }

    /// The next Command-F5 goes to macOS, to start its VoiceOver from any
    /// screen (2026-10-26). The Mac keeps Command-F5 unless the machine's
    /// view captures system keys, so AVM captures them until that one
    /// Command-F5 has gone through, then stops; and 10 seconds after asking
    /// whatever happens. The first try failed twice: "Press Command-F5 now"
    /// was said BEFORE capturing began and used up half the time, and
    /// capture was switched on while the screen already had the keyboard,
    /// where it doesn't take effect (setCapturesSystemKeys). While capture
    /// is on, Control-Command-Escape may not work (the 2026-10-26 trap), so
    /// the timer is the backstop and it is short. Also the bar's "Turn On
    /// VoiceOver in macOS" button, for use with the Mac's VoiceOver on.
    /// Virtual Machine > Pass Command-F5 to macOS, Command-Option-Shift-V.
    private var systemKeysGeneration = 0
    private var passingCommandF5 = false
    func passSystemKeysBriefly() {
        guard machineView != nil else { NSSound.beep(); return }
        if !keyboardInGuest { enter() }
        systemKeysGeneration += 1
        let generation = systemKeysGeneration
        whenModifiersReleased { [weak self] in
            guard let self, self.keyboardInGuest, generation == self.systemKeysGeneration else { return }
            self.passingCommandF5 = true
            self.setCapturesSystemKeys(true)
            AVMLog.write("AVM: MacGuest — the next Command-F5 goes to macOS (10 seconds at most).")
            // Said once capturing has begun, so a quick Command-F5 can't
            // come too early.
            Announcer.shared.announce("Press Command-F5 now. It goes to \(self.guestName).", tone: .info)
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, generation == self.systemKeysGeneration, self.passingCommandF5 else { return }
                    self.endPassingCommandF5(timedOut: true)
                }
            }
        }
    }

    /// capturesSystemKeys takes effect as the screen BECOMES first
    /// responder (2026-10-26, inferred from the log): set while it already
    /// was, it changed nothing, and the Command-F5s went to the Mac; set
    /// before (the trap) it captured at once. So each change is followed
    /// by the screen giving up the keyboard and taking it back, both ways:
    /// turning capture off must take effect too.
    private func setCapturesSystemKeys(_ on: Bool) {
        guard let window, let machineView else { return }
        machineView.capturesSystemKeys = on
        if keyboardInGuest {
            window.makeFirstResponder(nil)
            window.makeFirstResponder(machineView)
        }
    }

    private func endPassingCommandF5(timedOut: Bool) {
        guard passingCommandF5 else { return }
        passingCommandF5 = false
        setCapturesSystemKeys(false)
        AVMLog.write("AVM: MacGuest — system keys back to the Mac\(timedOut ? " (10 seconds passed)" : "").")
        var said = timedOut ? "Command-F5 is your Mac's again." : ""
        if NSWorkspace.shared.isVoiceOverEnabled {
            said += (said.isEmpty ? "" : " ") + "If you hear both VoiceOvers, press Command-F5 to turn your Mac's off."
        }
        if !said.isEmpty { Announcer.shared.announce(said, tone: .info) }
    }

    /// Runs `action` once no modifier key is held, checking every 20 ms,
    /// for at most 3 seconds.
    private func whenModifiersReleased(_ action: @escaping @MainActor () -> Void) {
        let deadline = Date().addingTimeInterval(3)
        func check() {
            let held = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift])
            if held.isEmpty || Date() > deadline {
                action()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { MainActor.assumeIsolated { check() } }
            }
        }
        check()
    }

    // MARK: Full control's way out

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    /// "AVMm": not FocusLockManager's id, so neither handler acts on the
    /// other's hotkey (only one is ever registered at a time anyway).
    private static let escapeHotKeyID = EventHotKeyID(signature: OSType(0x4156_4D6D), id: 2)

    /// Control-Command-Escape as a system-wide hotkey while macOS has full
    /// control, the mechanism Windows' focus lock relies on, so the way
    /// back works even when the machine has captured the keyboard.
    private func registerEscapeHotKey() {
        guard hotKeyRef == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == MacGuestRunner.escapeHotKeyID.signature, id.id == MacGuestRunner.escapeHotKeyID.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { MacGuestRunner.shared.leave() } }
            return noErr
        }, 1, &type, nil, &hotKeyHandler)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | cmdKey), Self.escapeHotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        AVMLog.write("AVM: MacGuest — Control-Command-Escape hotkey \(status == noErr ? "registered" : "not registered (\(status))").")
        // Not registered: its handler goes too, or each later try installs
        // another that is never removed (2026-10-26, code audit).
        if status != noErr {
            hotKeyRef = nil
            if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
            hotKeyHandler = nil
        }
    }

    /// Back to the Mac's own shortcuts, and the hotkey off.
    private func releaseFullControl() {
        passingCommandF5 = false
        machineView?.capturesSystemKeys = false
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
    }

    private func setKeyboard(inGuest: Bool) {
        // Back to the Mac, however it happens: the Mac's VoiceOver comes
        // back on if AVM turned it off.
        if keyboardInGuest && !inGuest {
            MacVoiceOver.restoreAfterGuest()
        }
        if keyboardInGuest && !inGuest {
            AVMLog.write("AVM: MacGuest — while macOS had the keyboard: \(keysToMacOS) key presses went to the machine's window, \(keysElsewhere) to another window.")
        }
        if inGuest {
            keysToMacOS = 0
            keysElsewhere = 0
        }
        keyboardInGuest = inGuest
        statusLabel?.stringValue = inGuest
            ? "Keyboard: \(name). Every key goes to \(name) except Command-Tab and Command-F5, which stay your Mac's. Control-Command-Escape returns to your Mac."
            : "Keyboard: your Mac. Command-Shift-E, or the button, gives it to \(name)."
    }

    private func showWindow(for machine: VZVirtualMachine, title: String) {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = false        // Command-Tab stays the Mac's
        if #available(macOS 14.0, *) { view.automaticallyReconfiguresDisplay = true }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("\(title) screen")
        view.setAccessibilityHelp("macOS's screen. When it has the keyboard, keys go to macOS; Control-Command-Escape returns to your Mac.")
        view.translatesAutoresizingMaskIntoConstraints = false

        // The bar VoiceOver can read, above the screen.
        let status = NSTextField(labelWithString: "")
        status.setAccessibilityLabel("Keyboard status")
        let give = NSButton(title: "Give \(title) the Keyboard", target: self, action: #selector(giveKeyboard))
        giveButton = give
        let voiceOver = NSButton(title: "Turn On VoiceOver in \(guestName)", target: self, action: #selector(voiceOverPressed))
        voiceOver.setAccessibilityHelp("Gives \(guestName) the keyboard and passes it your next Command-F5, which starts its VoiceOver on any screen. Command-Option-Shift-V.")
        let shut = NSButton(title: "Shut Down", target: self, action: #selector(shutDownPressed))
        let bar = NSStackView(views: [status, NSView(), give, voiceOver, shut])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.group)
        bar.setAccessibilityLabel("\(title) controls")
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(bar)
        content.addSubview(view)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel("\(title), macOS virtual machine")
        window.center()
        self.window = window
        self.machineView = view
        self.statusLabel = status
        setKeyboard(inGuest: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(give)

        // THE ONE KEYBOARD RULE (2026-10-26, after "switching is unclear and
        // keystrokes don't work consistently"): keys reach macOS only after
        // Enter (Command-Shift-E or the button), and then go to it the
        // normal way. One chord is AVM's: Control-Command-Escape, back to
        // the Mac. (Command shortcuts that are AVM menu items, like
        // Command-Q, are AVM's; quitting asks first while macOS runs.)
        // Command-F5 and Command-Tab are the Mac's own: macOS lets no app see
        // them without capturing the keyboard, and capturing it disables the
        // way out (see enter()).
        // MEASURED 2026-10-26: keys reach this monitor on their way to the
        // machine's screen (17 counted in one stretch, Return working); in
        // an earlier stretch, with the Mac's VoiceOver on, none did. Counted
        // either way, never identified.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.keyboardInGuest, let screen = self.machineView else { return event }
            guard event.window === self.window else {
                // A key typed while AVM thinks macOS has the keyboard, but
                // into another window: counted, never identified.
                if event.type == .keyDown { self.keysElsewhere += 1 }
                return event
            }
            let mods = event.modifierFlags.intersection([.control, .command, .option, .shift])
            if event.type == .keyDown, event.keyCode == 53, mods == [.control, .command] {
                self.leave()
                return nil
            }
            // The one Command-F5 being passed to macOS: it goes through,
            // then the Mac gets its system keys back once it's let go.
            if self.passingCommandF5, event.keyCode == UInt16(kVK_F5), mods.contains(.command) {
                AVMLog.write("AVM: MacGuest — Command-F5 went to macOS.")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated { self?.endPassingCommandF5(timedOut: false) }
                }
            }
            // Let every other key go the normal way, to the machine's screen
            // as first responder. MEASURED 2026-10-26: handing keys to the
            // screen from here (screen.keyDown(with:)) made the Mac thunk
            // and macOS never got them; Return and Escape in Setup
            // Assistant failed that way once the Mac's VoiceOver was off
            // and keys came through AppKit. Counted, never identified.
            if event.type == .keyDown {
                self.keysToMacOS += 1
                // Where this key is going, never which key it is: the first
                // few of each stretch in macOS, to tell whether a "thunk"
                // is the Mac's (a key nothing took) or macOS's.
                if self.keysToMacOS <= 5 {
                    let responder = self.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                    AVMLog.write("AVM: MacGuest — a key to the machine's window: first responder \(responder), window \(self.window?.isKeyWindow == true ? "key" : "NOT key"), AVM \(NSApp.isActive ? "active" : "NOT active"), modifiers held: \(event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty ? "none" : "some").")
                }
            }
            return event
        }
    }

    @objc private func giveKeyboard() { enter() }
    @objc private func shutDownPressed() { shutDown() }
    @objc private func voiceOverPressed() { passSystemKeysBriefly() }

    /// Leaving the window by any other way (Command-Tab, a click on the
    /// dashboard) gives the keyboard back to the Mac, and says so.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard keyboardInGuest else { return }
            releaseFullControl()
            setKeyboard(inGuest: false)
            window?.makeFirstResponder(giveButton)
            Announcer.shared.announce("Entering Mac", tone: .leaveGuest)
            AVMLog.write("AVM: MacGuest — keyboard to the Mac (window left).")
        }
    }

    /// Arriving at the window (Command-backquote, a click, VoiceOver) does
    /// not give macOS the keyboard: only Enter does. Focus rests on the
    /// bar's button, so keys typed here go nowhere unexpected.
    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !keyboardInGuest else { return }
            window?.makeFirstResponder(giveButton)
        }
    }

    // Closing the window shuts the machine down, asking first.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard machine != nil else { return true }
            let alert = NSAlert()
            alert.messageText = "Shut down \(name)?"
            alert.informativeText = "macOS in the machine shuts down as it would on a Mac; unsaved work there may be lost."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Shut Down")
            alert.addButton(withTitle: "Force Stop")
            let saveable = canSave
            if saveable {
                alert.addButton(withTitle: "Save and Close")
                alert.informativeText += " Save and Close keeps \(name) as it is, open apps and all, and the next Start carries on from there in seconds."
            }
            switch alert.runModal() {
            case .alertSecondButtonReturn: shutDown()
            case .alertThirdButtonReturn: forceStop()
            case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1) where saveable:
                saveAndStop { _ in }
            default: break
            }
            return false
        }
    }

    // VZVirtualMachineDelegate
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { ended(spoken: "\(name) shut down.", tone: .info) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { ended(spoken: "\(name) stopped unexpectedly. Reason: \(error.localizedDescription)", tone: .failure) }
    }

    /// `spoken` nil: closed quietly, to be started again at once.
    private func ended(spoken: String?, tone: Announcer.Tone) {
        if let spoken { AVMLog.write("AVM: MacGuest — \(spoken)") }
        releaseFullControl()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.delegate = nil
        window?.close()
        window = nil
        machine = nil
        files = nil
        clipboard?.stop()
        clipboard = nil
        vzConfiguration = nil
        machineView = nil
        statusLabel = nil
        if keyboardInGuest { MacVoiceOver.restoreAfterGuest() }
        keyboardInGuest = false
        hintGiven = false
        runningID = nil
        if let spoken { Announcer.shared.announce(spoken, tone: tone) }
    }
}

// MARK: - The Mac's VoiceOver while macOS has the keyboard

/// The Mac's VoiceOver while a macOS machine has the keyboard (2026-10-26).
/// With both on, the Mac's VoiceOver takes arrow keys (Quick Nav) and its
/// Control-Option commands, and macOS's dings at what's left.
///
/// AVM CAN'T TURN IT OFF, MEASURED 2026-10-26: VoiceOver's AppleScript
/// "quit" stops it, but macOS's own setting (com.apple.universalaccess
/// voiceOverOnOffKey) stays on, and launchd starts VoiceOver again within
/// 2 seconds (new process each time, the setting 1 throughout). That
/// setting can't be written from outside ("Could not write domain"), and
/// macOS ignores a Command-F5 a program sends (CGEvent, posting allowed).
/// Only the person's own Command-F5 turns it off for good, so AVM asks for
/// it on entering, and turns VoiceOver back on itself on leaving: opening
/// VoiceOver.app starts it the way Command-F5 does, and that works.
@MainActor
enum MacVoiceOver {

    /// Kept on disk, not just in memory: if AVM crashes or is force-quit
    /// while macOS has the keyboard, applicationWillTerminate never runs,
    /// and the Mac would stay without its screen reader. recoverAtLaunch
    /// turns it back on next time.
    private static let flagKey = "AVMMacVoiceOverTurnedOff"
    private static var bringBack: Bool {
        get { UserDefaults.standard.bool(forKey: flagKey) }
        set { UserDefaults.standard.set(newValue, forKey: flagKey) }
    }

    /// On entering macOS: true if the Mac's VoiceOver is on (AVM then asks
    /// for Command-F5), remembering to bring it back on the way out.
    static func noteEnteringGuest() -> Bool {
        let on = NSWorkspace.shared.isVoiceOverEnabled
        AVMLog.write("AVM: MacVoiceOver — \(on ? "on" : "off") on entering macOS.")
        if on { bringBack = true }
        return on
    }

    /// At launch: VoiceOver back on if a previous AVM ended while macOS had
    /// the keyboard. Touches nothing otherwise.
    static func recoverAtLaunch() {
        guard bringBack else { return }
        AVMLog.write("AVM: MacVoiceOver — AVM ended while macOS had the keyboard; bringing the Mac's VoiceOver back.")
        restoreAfterGuest()
    }

    /// `beforeQuitting`: from applicationWillTerminate, where an
    /// asynchronous launch can be lost as the process exits (2026-10-26,
    /// code audit), so VoiceOver is opened with open(1) and waited for. The
    /// flag is cleared only once VoiceOver is on its way, so a launch that
    /// didn't happen is tried again at the next start (recoverAtLaunch).
    static func restoreAfterGuest(beforeQuitting: Bool = false) {
        guard bringBack else { return }
        if NSWorkspace.shared.isVoiceOverEnabled {
            bringBack = false
            AVMLog.write("AVM: MacVoiceOver — still on on leaving macOS.")
            return
        }
        let app = URL(fileURLWithPath: "/System/Library/CoreServices/VoiceOver.app")
        if beforeQuitting {
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [app.path]
            if (try? open.run()) != nil {
                open.waitUntilExit()
                if open.terminationStatus == 0 { bringBack = false }
            }
            NSLog("AVM: MacVoiceOver — opened before quitting (status \(open.terminationStatus)).")
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if error == nil { bringBack = false } }
            }
            AVMLog.write("AVM: MacVoiceOver — \(error == nil ? "turned back on" : "couldn't turn it back on: \(error!.localizedDescription)").")
        }
    }
}
