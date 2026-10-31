// RemoveAVM.swift
// AVM — Accessible Virtual Machine
//
// AVM > Remove AVM… (2026-10-30, the user's request): taking AVM off a Mac
// took a Terminal command with an administrator password, because the USB
// helper is a system service that only AVM itself, or root, can remove;
// dragging the app to the Trash left it registered and failing to start.
// This does it all from AVM, while AVM can still unregister its own
// services:
//   1. the USB helper (SMAppService daemon) and the open-at-login item;
//   2. AVM's caches, settings and the AVM Windows Apps folders;
//   3. the virtual machines and AVM's support folder, only when chosen;
//   4. the app itself, last, then AVM quits.
// Everything goes to the Trash, so it can be put back until the Trash is
// emptied. Not with a machine running: its disk would go mid-write.

import AppKit
import ServiceManagement

@MainActor
enum RemoveAVM {

    static func ask() {
        if MachineSessions.shared.anyActive || MacGuestRunner.shared.runningID != nil {
            Announcer.shared.announce("Shut down every virtual machine first, then choose Remove AVM again.", tone: .info)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove AVM from this Mac?"
        alert.informativeText = "AVM removes its USB helper and its login item, then moves its settings, caches and the AVM Windows Apps folder to the Trash, then the app itself, and quits. Remove AVM and Its Machines also moves every virtual machine, and the installers AVM downloaded, to the Trash. Nothing is gone until you empty the Trash."
        alert.addButton(withTitle: "Remove AVM, Keep Machines")
        alert.addButton(withTitle: "Remove AVM and Its Machines")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: remove(machinesToo: false)
        case .alertSecondButtonReturn: remove(machinesToo: true)
        default: return
        }
    }

    private static func remove(machinesToo: Bool) {
        AVMLog.write("AVM: Remove AVM — starting (machines too: \(machinesToo)).")
        var problems: [String] = []
        let fm = FileManager.default

        // 1. The services, while AVM can still unregister its own.
        USBHelperClient.shared.disconnect()
        do {
            try SMAppService.daemon(plistName: AVMUSBHelperNames.launchdPlistName).unregister()
        } catch {
            problems.append("the USB helper (\(error.localizedDescription))")
        }
        if SMAppService.mainApp.status != .notRegistered {
            do { try SMAppService.mainApp.unregister() } catch { problems.append("the login item (\(error.localizedDescription))") }
        }

        // 2 and 3. The files.
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let id = Bundle.main.bundleIdentifier ?? "com.alllisonmeloy.AVM"
        var items = [
            library.appendingPathComponent("Caches/\(id)"),
            library.appendingPathComponent("HTTPStorages/\(id)"),
            library.appendingPathComponent("Saved Application State/\(id).savedState"),
            WindowsApps.pinnedFolder,
            WindowsApps.homePinnedFolder,
        ]
        if machinesToo, let support = try? AVMPaths.supportDirectory() {
            items.append(support)
        }
        for item in items where fm.fileExists(atPath: item.path) {
            do { try fm.trashItem(at: item, resultingItemURL: nil) } catch {
                problems.append("\(item.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        UserDefaults.standard.removePersistentDomain(forName: id)
        UserDefaults.standard.synchronize()

        // 4. The app, last.
        do {
            try fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        } catch {
            problems.append("the app (\(error.localizedDescription)); drag it to the Trash from Applications")
        }

        if problems.isEmpty {
            AVMLog.write("AVM: Remove AVM — done.")
            Announcer.shared.announce("AVM is removed and in the Trash. It quits now.", tone: .success)
        } else {
            AVMLog.write("AVM: Remove AVM — done, except: \(problems.joined(separator: "; ")).")
            Announcer.shared.announce("AVM is removed, except: \(problems.joined(separator: "; ")). It quits now.", tone: .info)
        }
        NSApp.terminate(nil)
    }
}
