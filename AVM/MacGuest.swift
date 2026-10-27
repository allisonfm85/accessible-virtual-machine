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
// THE KEYBOARD: while the machine's window is in front, its keys go to
// macOS in the machine. Command-Tab still switches apps on the Mac. The
// Mac's VoiceOver keeps the VoiceOver keys (Control-Option), so to use
// VoiceOver inside the machine, turn the Mac's VoiceOver off with
// Command-F5 while working there, as with Windows and JAWS or NVDA.
// macOS Setup Assistant offers VoiceOver itself: press Escape when it
// speaks, or Command-F5 once the Mac's VoiceOver is off.

import AppKit
import Virtualization

// MARK: - Files

nonisolated struct MacGuestFiles {
    let folder: URL
    var disk: URL { folder.appendingPathComponent("macos-disk.img") }
    var auxiliaryStorage: URL { folder.appendingPathComponent("AuxiliaryStorage") }
    var hardwareModel: URL { folder.appendingPathComponent("HardwareModel") }
    var machineIdentifier: URL { folder.appendingPathComponent("MachineIdentifier") }

    var isInstalled: Bool {
        [disk, auxiliaryStorage, hardwareModel, machineIdentifier].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

nonisolated struct MacGuestError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Configuration

@MainActor
enum MacGuestConfiguration {

    /// The machine as Apple's framework runs it, from AVM's settings.
    static func make(_ config: VMConfiguration, files: MacGuestFiles,
                     hardwareModel: VZMacHardwareModel? = nil) throws -> VZVirtualMachineConfiguration {
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
        vz.networkDevices = [network]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)]
        vz.graphicsDevices = [graphics]

        vz.keyboards = [VZUSBKeyboardConfiguration()]
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
        // "My Shared Files", in /Volumes.
        if let shared = config.sharedFolderURL {
            let share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: shared, readOnly: config.sharedFolderIsReadOnly))
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fs.share = share
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
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(AVMPaths.supportFolderName).appendingPathComponent("macos-restore-images")
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
        say("Downloading macOS \(latest.operatingSystemVersion.description) from Apple, about 15 gigabytes. AVM says how far it has got every gigabyte.")
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
final class MacGuestRunner: NSObject, VZVirtualMachineDelegate, NSWindowDelegate {
    static let shared = MacGuestRunner()

    private(set) var runningID: UUID?
    private var machine: VZVirtualMachine?
    private var window: NSWindow?
    private var name = "macOS"

    func start(_ config: VMConfiguration) {
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
            let vz = try MacGuestConfiguration.make(config, files: files)
            let machine = VZVirtualMachine(configuration: vz)
            machine.delegate = self
            self.machine = machine
            runningID = config.id
            name = config.name
            showWindow(for: machine, title: config.name)
            Announcer.shared.announce("Starting \(config.name).", tone: .info)
            machine.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    AVMLog.write("AVM: MacGuest — \(config.name) started.")
                    Announcer.shared.announce("\(config.name) is running. Its window has the keyboard; Command-Tab returns to your Mac's apps. To use VoiceOver inside it, turn your Mac's VoiceOver off with Command-F5 while you work there.", tone: .success)
                case .failure(let error):
                    self.ended(spoken: "\(config.name) could not start. Reason: \(error.localizedDescription)", tone: .failure)
                }
            }
        } catch {
            Announcer.shared.announce("\(config.name) could not start. Reason: \(error.localizedDescription)", tone: .failure)
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

    private func showWindow(for machine: VZVirtualMachine, title: String) {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = false        // Command-Tab stays the Mac's
        if #available(macOS 14.0, *) { view.automaticallyReconfiguresDisplay = true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel("\(title), macOS virtual machine")
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
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
            switch alert.runModal() {
            case .alertSecondButtonReturn: shutDown()
            case .alertThirdButtonReturn: forceStop()
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

    private func ended(spoken: String, tone: Announcer.Tone) {
        AVMLog.write("AVM: MacGuest — \(spoken)")
        window?.delegate = nil
        window?.close()
        window = nil
        machine = nil
        runningID = nil
        Announcer.shared.announce(spoken, tone: tone)
    }
}
