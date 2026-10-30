// WindowsApps.swift
// AVM — Accessible Virtual Machine
//
// Windows apps in the Mac's Command-Tab list (2026-10-29, the user's
// request): every app with a window open in a running Windows machine is
// in Command-Tab as an app of its own, "Microsoft Word (Amena-PC)", added
// when it opens and gone when it closes. Command-Tab to one, press
// Command-Shift-E, and the app comes forward in Windows and the keyboard
// locks into the machine, where NVDA, JAWS or Narrator read it as usual.
// Control-Command-Escape comes back to the Mac. (While locked, AVM keeps
// Command-Tab off, so switching is always from the Mac side.)
//
// Two halves:
//   - In Windows, AVMWindowsApps.exe (Resources/windows-apps), running in
//     the signed-in user's session from the scheduled task \AVM\Windows
//     Apps. The guest agent runs as SYSTEM in session 0 and can see none
//     of the user's windows, so the helper lists the apps open
//     (C:\ProgramData\AVM\apps\running.txt) and brings one forward when
//     asked (request.txt, reply.txt). AVM installs it, compiled in Windows
//     by .NET Framework's own compiler, and replaces it when its version
//     changes, through the agent, with no window or prompt in Windows.
//   - On the Mac, one small app per Windows app: a copy of
//     AVMWindowsApp (Contents/MacOS) in a bundle of its own, named for the
//     app and signed on this Mac, launched hidden so it's in Command-Tab
//     (and so in the Dock: macOS has no way to have one without the
//     other). It calls back through the control socket ("launch-app").
//
// Every few seconds, for each running Windows machine with the setting on
// (VMConfiguration.windowsAppsInCommandTab, on unless turned off).
//
// Machines too (2026-10-30, the user's request, to switch between them):
// each running machine, of any kind, has an app of its own in Command-Tab,
// named for it, made from the same AVMWindowsApp program
// (AVMKind = machine). Switched to, it hands the front to AVM, which
// brings the machine's window forward with the keyboard in it
// ("enter-machine"). It goes when the machine stops.

import AppKit
import CryptoKit

@MainActor
final class WindowsApps {
    static let shared = WindowsApps()

    /// Bumped with every change to AVMWindowsApps.cs or the install script
    /// (3: launch, for pinned apps; 5: a file per request, launches waited
    /// for apart, the task started safely before sign-in, 2026-10-30).
    static let helperVersion = "5"
    static let guestFolder = #"C:\ProgramData\AVM"#

    /// What a Mac app stands for: an app open in Windows, one kept in the
    /// Dock and Applications, or a running machine. The raw value is its
    /// part of the bundle identifier.
    private enum Kind: String {
        case app = ""
        case pinned = "pinned."
        case machine = "machine."
    }

    private struct Entry {
        let bundleID: String
        let name: String
        /// When AVM last opened it, so one still launching isn't opened again.
        var opened = Date()

        /// Quit by the person, or crashed, though what it stands for is still
        /// open (2026-10-30 audit: it stayed out of Command-Tab until then),
        /// given the bundle identifiers running now.
        func wasQuit(running: Set<String>) -> Bool {
            Date().timeIntervalSince(opened) > 10 && !running.contains(bundleID)
        }
    }
    /// The Mac apps launched, by machine, by the helper's key for the app.
    private var entries: [UUID: [String: Entry]] = [:]
    /// The machine run (its QEMU process) whose helper is known current.
    private var helperReady: [UUID: Int] = [:]
    private var installing: Set<UUID> = []
    private var timer: Timer?
    private var ticking = false
    private var built: Set<String> = []
    private var requestNumber = 0
    /// Launches under way, by machine and app key: one at a time each.
    private var launching: Set<String> = []
    /// Pinned ones looked over this run (refreshPinned).
    private var pinnedRefreshed = false
    /// Each running machine's own app, by machine (syncMachines).
    private var machineEntries: [UUID: Entry] = [:]

    private var bundlePrefix: String { (Bundle.main.bundleIdentifier ?? "com.alllisonmeloy.AVM") + ".windowsapp." }

    /// Every running app's bundle identifier, from one walk of the list.
    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func start() {
        guard timer == nil else { return }
        // A pinned one may be what opened AVM, waiting for its answer.
        quitLeftovers(keepingPinned: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { WindowsApps.shared.tick() }
        }
    }

    /// AVM quitting: every Windows app's Mac app goes too.
    func quitAll() {
        for machine in entries.keys { quitEntries(of: machine) }
        for entry in machineEntries.values { quit(entry.bundleID) }
        machineEntries = [:]
        quitLeftovers()
    }

    // MARK: Watching

    private func tick() {
        guard !ticking else { return }
        // Every running Windows machine gets the helper, which its pinned
        // apps need too; only those with the setting on get their apps in
        // Command-Tab.
        let machines = MachineSessions.shared.sessions.values.filter {
            $0.configuration.guestOS == .windows && $0.vmState == .running
        }
        let running = Set(machines.map { $0.configuration.id })
        let listed = Set(machines.filter { $0.configuration.windowsAppsInCommandTab != false }.map { $0.configuration.id })
        for machine in entries.keys where !listed.contains(machine) { quitEntries(of: machine) }
        for machine in helperReady.keys where !running.contains(machine) { helperReady[machine] = nil }
        ticking = true
        Task {
            defer { ticking = false }
            if !pinnedRefreshed, let store = VMStore.shared, !store.configurations.isEmpty {
                pinnedRefreshed = true
                await refreshPinned(store)
            }
            await syncMachines()
            for session in machines {
                let manager = session.manager
                let id = session.configuration.id
                if helperReady[id] != manager.qemuPID {
                    guard await ensureHelper(manager, machine: id) else { continue }
                }
                guard listed.contains(id) else { continue }
                guard let list = try? await Self.readGuestFile(manager, Self.guestFolder + #"\apps\running.txt"#) else { continue }
                await sync(machine: id, machineName: session.configuration.name, list: list)
            }
        }
    }

    private func sync(machine: UUID, machineName: String, list: String) async {
        var open: [String: String] = [:]
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            open[parts[0]] = parts[1]
        }
        // Made again just below.
        let runningIDs = Self.runningBundleIDs()
        for (key, entry) in entries[machine] ?? [:] where open[key] != nil && entry.wasQuit(running: runningIDs) {
            entries[machine]?[key] = nil
            AVMLog.write("Windows apps: \(entry.name) was quit on the Mac; opening it again", category: "WindowsApps")
        }
        for (key, entry) in entries[machine] ?? [:] where open[key] == nil {
            quit(entry.bundleID)
            entries[machine]?[key] = nil
            AVMLog.write("Windows apps: \(entry.name) closed in \(machineName); out of Command-Tab", category: "WindowsApps")
        }
        let new = open.filter { entries[machine]?[$0.key] == nil }
        guard !new.isEmpty else { return }
        // Looked at once for them all, not once an app.
        let pinned = pinnedBundles()
        for (key, name) in new {
            guard let entry = await launchEntry(machine: machine, machineName: machineName, key: key, name: name,
                                                pinned: pinned, running: runningIDs) else { continue }
            entries[machine, default: [:]][key] = entry
            AVMLog.write("Windows apps: \(name) open in \(machineName); in Command-Tab", category: "WindowsApps")
        }
    }

    // MARK: The Mac apps

    /// A machine's own app has no app key.
    private func bundleID(machine: UUID, key: String, kind: Kind) -> String {
        let digest = SHA256.hash(data: Data((machine.uuidString + "\n" + key).utf8))
        return bundlePrefix + kind.rawValue + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func launchEntry(machine: UUID, machineName: String, key: String, name: String,
                             pinned bundles: [(url: URL, info: NSDictionary)], running: Set<String>) async -> Entry? {
        let title = "\(name) (\(machineName))"
        // A pinned one opens as itself, so its Dock icon shows it's open.
        if let pinned = pinnedBundle(machine: machine, key: key, in: bundles) {
            // Opened by the person already, it stays as it is, not hidden.
            if !running.contains(pinned.bundleID) {
                openHidden(pinned.url, title: title)
            }
            return Entry(bundleID: pinned.bundleID, name: name)
        }
        let bundleID = bundleID(machine: machine, key: key, kind: .app)
        do {
            let url = try bundleURL(machine: machine, key: key, title: title)
            if !built.contains(bundleID) {
                try await build(url, bundleID: bundleID, title: title, name: name, key: key, machine: machine, machineName: machineName)
                built.insert(bundleID)
            }
            openHidden(url, title: title)
            return Entry(bundleID: bundleID, name: name)
        } catch {
            AVMLog.write("Windows apps: couldn't make \(title): \(error.localizedDescription)", category: "WindowsApps")
            return nil
        }
    }

    /// Opened by AVM, not by the person: --avm-opened, so it doesn't ask to
    /// launch the app it stands for.
    private func openHidden(_ url: URL, title: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        configuration.arguments = ["--avm-opened"]
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                AVMLog.write("Windows apps: \(title) didn't open: \(error.localizedDescription)", category: "WindowsApps")
            }
        }
    }

    /// AVM's folder for them, one per machine; the file name is the name
    /// Command-Tab shows.
    private func bundleURL(machine: UUID, key: String, title: String) throws -> URL {
        let folder = try AVMPaths.supportDirectory()
            .appendingPathComponent("windows-apps", isDirectory: true)
            .appendingPathComponent(machine.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Self.freeURL(in: folder, title: title, machine: machine, key: key)
    }

    /// A bundle's place in a folder, named for its title, "Python
    /// (Amena-PC)", or "Python (Amena-PC) 2" when another app or machine
    /// has that name there already (2026-10-30 audit: two apps Windows
    /// names alike, or two machines named alike, shared one bundle, and
    /// the second replaced the first).
    private static func freeURL(in folder: URL, title: String, machine: UUID, key: String) -> URL {
        let safe = String(title.map { "/:".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "Windows app" : safe
        var number = 1
        while true {
            let url = folder.appendingPathComponent((number == 1 ? base : "\(base) \(number)") + ".app", isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { return url }
            if let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
               info["AVMMachineID"] as? String == machine.uuidString, info["AVMAppKey"] as? String == key {
                return url
            }
            number += 1
        }
    }

    private func build(_ url: URL, bundleID: String, title: String, name: String, key: String,
                       machine: UUID, machineName: String, kind: Kind = .app) async throws {
        let fm = FileManager.default
        guard let stub = Bundle.main.url(forAuxiliaryExecutable: "AVMWindowsApp") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "AVMWindowsApp isn't in AVM"])
        }
        try? fm.removeItem(at: url)
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: stub, to: macOS.appendingPathComponent("AVMWindowsApp"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": title,
            "CFBundleDisplayName": title,
            "CFBundleExecutable": "AVMWindowsApp",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1",
            "CFBundleVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": true,
            "AVMAppName": name,
            "AVMAppKey": key,
            "AVMMachineID": machine.uuidString,
            "AVMMachineName": machineName,
            "AVMControlSocket": ControlServer.socketURL?.path ?? "",
            "AVMBundleID": Bundle.main.bundleIdentifier ?? "",
            "AVMPinned": kind == .pinned,
            "AVMKind": kind == .machine ? "machine" : "app",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        // Signed for this Mac: the copy's signature is for AVM's bundle.
        // Waited for without holding the main thread (2026-10-30 cleanup):
        // a tenth of a second or more a bundle, and a machine with ten apps
        // open froze AVM, VoiceOver and all, for a second or more.
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", url.path]
            sign.standardOutput = FileHandle.nullDevice
            sign.standardError = FileHandle.nullDevice
            sign.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try sign.run() } catch { done.resume(throwing: error) }
        }
        guard status == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "codesign failed (\(status))"])
        }
    }

    private func quit(_ bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
    }

    private func quitEntries(of machine: UUID) {
        for entry in (entries[machine] ?? [:]).values { quit(entry.bundleID) }
        entries[machine] = nil
    }

    /// From an AVM that didn't quit cleanly.
    private func quitLeftovers(keepingPinned: Bool = false) {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.hasPrefix(bundlePrefix) == true {
            if keepingPinned, app.bundleIdentifier?.hasPrefix(bundlePrefix + Kind.pinned.rawValue) == true { continue }
            app.terminate()
        }
    }

    // MARK: Machines in Command-Tab (2026-10-30)

    /// Every running machine has its app, named for it; one quit by the
    /// person, or renamed, is made again, and a stopped one's goes.
    private func syncMachines() async {
        var running: [UUID: String] = [:]
        func name(_ id: UUID, _ fallback: String) -> String {
            VMStore.shared?.configurations.first { $0.id == id }?.name ?? fallback
        }
        for session in MachineSessions.shared.sessions.values where session.isRunningOrPaused {
            running[session.configuration.id] = name(session.configuration.id, session.configuration.name)
        }
        if let id = MacGuestRunner.shared.runningID { running[id] = name(id, "macOS") }
        let runningIDs = Self.runningBundleIDs()
        for (id, entry) in machineEntries where running[id] != entry.name || entry.wasQuit(running: runningIDs) {
            quit(entry.bundleID)
            machineEntries[id] = nil
        }
        for (id, machineName) in running where machineEntries[id] == nil {
            let bundleID = bundleID(machine: id, key: "", kind: .machine)
            do {
                let url = try bundleURL(machine: id, key: "", title: machineName)
                if !built.contains(bundleID) || !FileManager.default.fileExists(atPath: url.path) {
                    try await build(url, bundleID: bundleID, title: machineName, name: machineName, key: "",
                                    machine: id, machineName: machineName, kind: .machine)
                    built.insert(bundleID)
                }
                openHidden(url, title: machineName)
                machineEntries[id] = Entry(bundleID: bundleID, name: machineName)
                AVMLog.write("Windows apps: \(machineName) is in Command-Tab", category: "WindowsApps")
            } catch {
                AVMLog.write("Windows apps: couldn't put \(machineName) in Command-Tab: \(error.localizedDescription)", category: "WindowsApps")
            }
        }
    }

    // MARK: Pinned: in Applications and the Dock (2026-10-30)

    /// Where pinned ones live: the Mac's Applications folder, which
    /// Command-Shift-A opens and Launchpad and Spotlight list (2026-10-30
    /// audit: they were in the home folder's, where the user didn't find
    /// them); the home folder's when the Mac's can't be written, as on a
    /// standard account.
    static let pinnedFolder = URL(fileURLWithPath: "/Applications/AVM Windows Apps", isDirectory: true)
    static var homePinnedFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("AVM Windows Apps", isDirectory: true)
    }

    private static func folderForPinning() -> URL? {
        let fm = FileManager.default
        for folder in [pinnedFolder, homePinnedFolder] {
            if (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
               fm.isWritableFile(atPath: folder.path) { return folder }
        }
        return nil
    }

    private func pinnedBundles() -> [(url: URL, info: NSDictionary)] {
        var found: [(url: URL, info: NSDictionary)] = []
        for folder in [Self.pinnedFolder, Self.homePinnedFolder] {
            guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                      info["AVMMachineID"] is String else { continue }
                found.append((url, info))
            }
        }
        return found
    }

    /// In `bundles` when they've been looked at already.
    private func pinnedBundle(machine: UUID, key: String,
                              in bundles: [(url: URL, info: NSDictionary)]? = nil) -> (url: URL, bundleID: String)? {
        for (url, info) in bundles ?? pinnedBundles() {
            guard info["AVMMachineID"] as? String == machine.uuidString, info["AVMAppKey"] as? String == key,
                  let id = info["CFBundleIdentifier"] as? String else { continue }
            return (url, id)
        }
        return nil
    }

    /// Once a run, at the first look (2026-10-30 audit): pinned ones made
    /// again with this AVM's copy of the program when AVM has changed since
    /// (they were made once, at pinning, and kept the old one for good),
    /// moved from the home folder's Applications to the Mac's when they can
    /// be, and those of a machine no longer in AVM taken out of the Dock and
    /// moved to the Trash. One that's running is left for the next run: it
    /// may be what opened AVM.
    private func refreshPinned(_ store: VMStore) async {
        let fm = FileManager.default
        let version = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let socket = ControlServer.socketURL?.path ?? ""
        let machines = Set(store.configurations.map(\.id))
        let canMove = Self.folderForPinning() == Self.pinnedFolder
        var moved: [String: URL] = [:]
        var removed: Set<String> = []
        let runningIDs = Self.runningBundleIDs()
        for (url, info) in pinnedBundles() {
            guard let id = info["CFBundleIdentifier"] as? String,
                  let machine = UUID(uuidString: info["AVMMachineID"] as? String ?? ""),
                  let key = info["AVMAppKey"] as? String, let name = info["AVMAppName"] as? String,
                  !runningIDs.contains(id) else { continue }
            let title = info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent
            if !machines.contains(machine) {
                if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil {
                    removed.insert(id)
                    AVMLog.write("Windows apps: \(title) unpinned: its machine isn't in AVM any more", category: "WindowsApps")
                }
                continue
            }
            var place = url
            if canMove, url.deletingLastPathComponent().standardizedFileURL == Self.homePinnedFolder.standardizedFileURL {
                let target = Self.freeURL(in: Self.pinnedFolder, title: title, machine: machine, key: key)
                do {
                    try fm.moveItem(at: url, to: target)
                    place = target
                    moved[id] = target
                    AVMLog.write("Windows apps: \(title) moved to \(target.path)", category: "WindowsApps")
                } catch {
                    AVMLog.write("Windows apps: couldn't move \(title) to Applications: \(error.localizedDescription)", category: "WindowsApps")
                }
            }
            guard info["CFBundleVersion"] as? String != version || info["AVMControlSocket"] as? String != socket else { continue }
            do {
                try await build(place, bundleID: id, title: title, name: name, key: key, machine: machine,
                                machineName: info["AVMMachineName"] as? String ?? "", kind: .pinned)
                built.insert(id)
                AVMLog.write("Windows apps: \(title) made again for this AVM", category: "WindowsApps")
            } catch {
                AVMLog.write("Windows apps: couldn't make \(title) again: \(error.localizedDescription)", category: "WindowsApps")
            }
        }
        if !moved.isEmpty || !removed.isEmpty { Self.updateDock(moved: moved, removed: removed) }
        if let left = try? fm.contentsOfDirectory(atPath: Self.homePinnedFolder.path), !left.contains(where: { !$0.hasPrefix(".") }) {
            try? fm.removeItem(at: Self.homePinnedFolder)
        }
    }

    /// Keep in Dock and Applications.
    func pin(machine: UUID, appKey: String, name: String) async -> (ok: Bool, message: String) {
        guard let config = VMStore.shared?.configurations.first(where: { $0.id == machine }) else {
            return (false, "That machine isn't in AVM any more.")
        }
        let title = "\(name) (\(config.name))"
        if pinnedBundle(machine: machine, key: appKey) != nil {
            return (true, "\(title) is in your Dock and Applications already.")
        }
        let id = bundleID(machine: machine, key: appKey, kind: .pinned)
        guard let folder = Self.folderForPinning() else {
            return (false, "AVM couldn't keep \(title): it can't write to Applications.")
        }
        do {
            let url = Self.freeURL(in: folder, title: title, machine: machine, key: appKey)
            try await build(url, bundleID: id, title: title, name: name, key: appKey, machine: machine, machineName: config.name, kind: .pinned)
            built.insert(id)
            Self.addToDock(url, title: title, bundleID: id)
            // The pinned one stands for the app from now on.
            if let entry = entries[machine]?[appKey] {
                quit(entry.bundleID)
                openHidden(url, title: title)
                entries[machine]?[appKey] = Entry(bundleID: id, name: name)
            }
            AVMLog.write("Windows apps: \(title) pinned (Dock and \(url.path))", category: "WindowsApps")
            let line = folder == Self.pinnedFolder
                ? "\(title) is in your Dock, and in Applications, in the AVM Windows Apps folder."
                : "\(title) is in your Dock, and in the Applications folder in your home folder, in AVM Windows Apps."
            Announcer.shared.announce(line, tone: .success)
            return (true, line)
        } catch {
            return (false, "AVM couldn't keep \(title): \(error.localizedDescription)")
        }
    }

    /// Remove from Dock and Applications. The bundle goes to the Trash.
    func unpin(machine: UUID, appKey: String) -> (ok: Bool, message: String) {
        guard let pinned = pinnedBundle(machine: machine, key: appKey) else { return (true, "It isn't pinned.") }
        let title = pinned.url.deletingPathExtension().lastPathComponent
        Self.removeFromDock(pinned.url, bundleID: pinned.bundleID)
        quit(pinned.bundleID)
        do {
            try FileManager.default.trashItem(at: pinned.url, resultingItemURL: nil)
        } catch {
            return (false, "AVM couldn't remove \(title): \(error.localizedDescription)")
        }
        // While the app is open, a temporary one stands for it again.
        entries[machine]?[appKey] = nil
        AVMLog.write("Windows apps: \(title) unpinned", category: "WindowsApps")
        let line = "\(title) is out of your Dock and Applications."
        Announcer.shared.announce(line, tone: .info)
        return (true, line)
    }

    /// The Dock's own list (com.apple.dock persistent-apps), then the Dock
    /// restarted to read it, as the Dock's Keep in Dock does it.
    private static func addToDock(_ url: URL, title: String, bundleID: String) {
        var apps = dockApps()
        guard !apps.contains(where: { dockTile($0, is: url, bundleID: bundleID) }) else { return }
        apps.append(["tile-type": "file-tile",
                     "tile-data": ["file-label": title, "bundle-identifier": bundleID,
                                   "file-data": ["_CFURLString": url.absoluteString, "_CFURLStringType": 15]]])
        setDockApps(apps)
    }

    private static func removeFromDock(_ url: URL, bundleID: String) {
        let apps = dockApps()
        let kept = apps.filter { !dockTile($0, is: url, bundleID: bundleID) }
        if kept.count != apps.count { setDockApps(kept) }
    }

    /// Tiles pointed at a pinned one's new place, or taken out, with one
    /// restart of the Dock.
    private static func updateDock(moved: [String: URL], removed: Set<String>) {
        var changed = false
        let apps = dockApps().compactMap { tile -> [String: Any]? in
            guard var data = tile["tile-data"] as? [String: Any], let id = data["bundle-identifier"] as? String else { return tile }
            if removed.contains(id) { changed = true; return nil }
            guard let url = moved[id] else { return tile }
            var file = data["file-data"] as? [String: Any] ?? [:]
            file["_CFURLString"] = url.absoluteString
            file["_CFURLStringType"] = 15
            data["file-data"] = file
            var updated = tile
            updated["tile-data"] = data
            changed = true
            return updated
        }
        if changed { setDockApps(apps) }
    }

    private static func dockApps() -> [[String: Any]] {
        CFPreferencesCopyAppValue("persistent-apps" as CFString, "com.apple.dock" as CFString) as? [[String: Any]] ?? []
    }

    private static func dockTile(_ tile: [String: Any], is url: URL, bundleID: String) -> Bool {
        let data = tile["tile-data"] as? [String: Any]
        if data?["bundle-identifier"] as? String == bundleID { return true }
        return ((data?["file-data"] as? [String: Any])?["_CFURLString"] as? String) == url.absoluteString
    }

    private static func setDockApps(_ apps: [[String: Any]]) {
        CFPreferencesSetAppValue("persistent-apps" as CFString, apps as CFArray, "com.apple.dock" as CFString)
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        let dock = Process()
        dock.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        dock.arguments = ["Dock"]
        try? dock.run()
    }

    // MARK: Opening an app from its Mac app (2026-10-30)

    /// Its Mac app was opened, by a click in the Dock or Applications, or
    /// Command-Shift-E in it: the machine started if it isn't running (its
    /// keyboard in it, to sign in), then, once Windows is signed in, the
    /// app opened or brought forward, and entered. Answers at once; the
    /// rest is said as it happens.
    func launch(machine: UUID, appKey: String, name: String) -> (ok: Bool, message: String) {
        guard let config = VMStore.shared?.configurations.first(where: { $0.id == machine }) else {
            return (false, "That machine isn't in AVM any more.")
        }
        let job = machine.uuidString + "\n" + appKey
        guard !launching.contains(job) else { return (true, "\(name) is opening already.") }
        if MachineSessions.shared.session(for: machine) == nil {
            if config.isATemplate { return (false, "\(config.name) is a template.") }
            if let busy = MachineArchiveController.shared.busyMessage(for: config) { return (false, busy) }
            BackgroundMode.shared.comeForward(announce: false)
            _ = MachineSessions.shared.start(config, vmStore: VMStore.shared, focusLock: FocusLockManager.shared, takesKeyboard: true)
            Announcer.shared.announce("Starting \(config.name) for \(name). Sign in to Windows when it asks, and \(name) opens.", tone: .info)
        }
        launching.insert(job)
        Task {
            defer { launching.remove(job) }
            await finishLaunch(machine: machine, machineName: config.name, appKey: appKey, name: name)
        }
        return (true, "")
    }

    private func finishLaunch(machine: UUID, machineName: String, appKey: String, name: String) async {
        let started = Date()
        func session() -> VMSession? { MachineSessions.shared.session(for: machine) }
        // Running, with the agent and the helper, within five minutes.
        while Date().timeIntervalSince(started) < 300 {
            guard let s = session(), s.vmState != .stopping else { return }
            if s.vmState == .running, helperReady[machine] == s.manager.qemuPID { break }
            if s.vmState == .running { _ = await ensureHelper(s.manager, machine: machine) }
            try? await Task.sleep(for: .seconds(2))
        }
        guard let s = session(), s.vmState == .running, helperReady[machine] == s.manager.qemuPID else {
            Announcer.shared.announce("\(name) didn't open: \(machineName) wasn't ready in time.", tone: .failure)
            return
        }
        let manager = s.manager
        requestNumber += 1
        let id = "\(requestNumber)-\(Int(Date().timeIntervalSince1970))"
        // A file each (2026-10-30 audit): one request.txt for all let a
        // second request, another app opened meanwhile, overwrite this one.
        let replyPath = Self.guestFolder + #"\apps\reply-"# + id + ".txt"
        do {
            try await Self.writeGuestFile(manager, Self.guestFolder + #"\apps\request-"# + id + ".txt",
                                          "\(id)\tlaunch\t\(appKey)\t\(Int(Date().timeIntervalSince1970))\n")
        } catch {
            Announcer.shared.announce("\(name) didn't open: \(error.localizedDescription).", tone: .failure)
            return
        }
        // The helper answers once Windows is signed in: ten minutes for
        // that, and its 90 seconds for a slow app's window. Looked for
        // often at first, as Command-Shift-E in an open app is answered in
        // a moment.
        let asked = Date()
        while Date().timeIntervalSince(asked) < 720 {
            try? await Task.sleep(for: Date().timeIntervalSince(asked) < 30 ? .milliseconds(250) : .seconds(1))
            guard session()?.vmState == .running else { return }
            guard let reply = try? await Self.readGuestFile(manager, replyPath) else { continue }
            let parts = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.first == id else { continue }
            if parts.count > 1, parts[1] == "ok" {
                AVMLog.write("Windows apps: \(name) open and in front in \(machineName); entering", category: "WindowsApps")
                BackgroundMode.shared.comeForward(announce: false)
                MachineSessions.shared.enter(machine)
            } else {
                let why = parts.count > 2 ? parts[2] : "it didn't open"
                AVMLog.write("Windows apps: \(name) didn't open in \(machineName): \(why)", category: "WindowsApps")
                Announcer.shared.announce("\(name) didn't open in Windows: \(why).", tone: .failure)
            }
            return
        }
        Announcer.shared.announce("\(name) didn't open: Windows wasn't signed in within ten minutes. Open it again once you're signed in.", tone: .info)
    }

    // MARK: The helper in Windows

    private func ensureHelper(_ manager: VMManager, machine: UUID) async -> Bool {
        guard !installing.contains(machine) else { return false }
        installing.insert(machine)
        defer { installing.remove(machine) }
        let version = try? await Self.readGuestFile(manager, Self.guestFolder + #"\bin\version.txt"#)
        if version?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.helperVersion {
            helperReady[machine] = manager.qemuPID
            return true
        }
        guard let source = Bundle.main.url(forResource: "AVMWindowsApps", withExtension: "cs"),
              let code = try? String(contentsOf: source, encoding: .utf8) else {
            AVMLog.write("Windows apps: AVMWindowsApps.cs isn't in AVM", category: "WindowsApps")
            return false
        }
        do {
            _ = try await manager.agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", Self.prepareScript], limit: .seconds(60))
            try await Self.writeGuestFile(manager, Self.guestFolder + #"\bin\AVMWindowsApps.cs"#, code)
            let output = try await manager.agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", Self.installScript], limit: .seconds(120))
            guard output.contains("AVM-INSTALLED") else {
                AVMLog.write("Windows apps: the helper didn't install: \(output.prefix(600))", category: "WindowsApps")
                return false
            }
            AVMLog.write("Windows apps: helper \(Self.helperVersion) installed in \(manager.machineName)", category: "WindowsApps")
            helperReady[machine] = manager.qemuPID
            return true
        } catch {
            // Most often the agent isn't up yet; the next look tries again.
            return false
        }
    }

    /// Folders, with the apps folder writable by the signed-in user, who
    /// writes the list and the replies; the old helper stopped.
    private static let prepareScript = #"""
        $ErrorActionPreference = 'Stop'
        New-Item -ItemType Directory -Force 'C:\ProgramData\AVM\bin','C:\ProgramData\AVM\apps' | Out-Null
        icacls 'C:\ProgramData\AVM\apps' /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
        Get-Process AVMWindowsApps -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 300
        """#

    /// Compiled with Windows' own .NET Framework compiler (Arm64 where
    /// there is one), then the task at sign-in, started now.
    private static var installScript: String {
        #"""
        $ErrorActionPreference = 'Stop'
        $csc = @('C:\Windows\Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe', 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $csc) { 'no C# compiler'; exit 1 }
        & $csc /nologo /target:winexe /platform:anycpu /optimize /out:C:\ProgramData\AVM\bin\AVMWindowsApps.exe C:\ProgramData\AVM\bin\AVMWindowsApps.cs
        if ($LASTEXITCODE -ne 0) { 'compile failed'; exit 1 }
        $action = New-ScheduledTaskAction -Execute 'C:\ProgramData\AVM\bin\AVMWindowsApps.exe'
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
        Register-ScheduledTask -TaskPath '\AVM\' -TaskName 'Windows Apps' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Lets AVM on the Mac list the apps open in Windows and bring one forward.' -Force | Out-Null
        # At the sign-in screen there's no one to run it for, and Windows
        # refuses (2026-10-30 audit); it starts at sign-in anyway.
        try { Start-ScheduledTask -TaskPath '\AVM\' -TaskName 'Windows Apps' } catch { }
        Set-Content -Path 'C:\ProgramData\AVM\bin\version.txt' -Value '\#(helperVersion)' -Encoding ASCII
        'AVM-INSTALLED'
        """#
    }

    // MARK: Files in Windows, through the agent

    nonisolated static func readGuestFile(_ manager: VMManager, _ path: String) async throws -> String? {
        guard let handle = try await manager.agentCall(["execute": "guest-file-open", "arguments": ["path": path, "mode": "rb"]]) as? Int else { return nil }
        let read = try? await manager.agentCall(["execute": "guest-file-read", "arguments": ["handle": handle, "count": 262_144]]) as? [String: Any]
        _ = try? await manager.agentCall(["execute": "guest-file-close", "arguments": ["handle": handle]])
        guard let base64 = read?["buf-b64"] as? String, let data = Data(base64Encoded: base64) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func writeGuestFile(_ manager: VMManager, _ path: String, _ text: String) async throws {
        guard let handle = try await manager.agentCall(["execute": "guest-file-open", "arguments": ["path": path, "mode": "wb"]]) as? Int else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Windows couldn't make \(path)"])
        }
        _ = try await manager.agentCall(["execute": "guest-file-write", "arguments": ["handle": handle, "buf-b64": Data(text.utf8).base64EncodedString()]])
        _ = try await manager.agentCall(["execute": "guest-file-close", "arguments": ["handle": handle]])
    }
}
