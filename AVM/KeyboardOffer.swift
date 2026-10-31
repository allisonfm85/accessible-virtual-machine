// KeyboardOffer.swift
// AVM — Accessible Virtual Machine
//
// A second keyboard offered for Windows (2026-10-30, a tester's log): his
// second keyboard was plugged in, AVM kept it on the Mac as it should, and
// nothing told him a keyboard for Windows has to be chosen in Settings, so
// he took it for a fault. Now, when an installed Windows machine starts
// with no keyboard for Windows and a second keyboard is connected, AVM asks
// once: use this keyboard for Windows? Yes chooses it, as Settings does, and
// it goes into Windows at once. Not Now is remembered for that keyboard and
// machine, so AVM asks again only about a keyboard it hasn't asked about.
//
// Asked only while AVM is in front with no other question up, so a
// machine started at login, in the background, never brings a question
// up over another app; the offer waits for a start the user is at.

import AppKit

@MainActor
enum KeyboardOffer {
    private static let declinedKey = "AVMKeyboardOffersDeclined"

    /// From VMManager.startVM, for an installed Windows machine with no
    /// keyboard for Windows.
    static func offerIfUseful(machine: VMManager, configuration: VMConfiguration) {
        guard configuration.guestOS == .windows, configuration.windowsKeyboardID == nil,
              !WindowsKeyboard.disabledForTests,
              !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) else { return }
        Task { @MainActor in
            // Once Windows is well on its way: a question in the first
            // seconds of a start lands on top of "Starting Windows".
            try? await Task.sleep(for: .seconds(20))
            guard machine.state == .running, WindowsKeyboard.shared.keyboardID == nil else { return }
            // Not registering the helper for this: an unasked-for Login
            // Items prompt is worse than no offer.
            guard case .success(let list) = await USBHelperClient.shared.listKeyboards(registering: false) else { return }
            let declined = Set(UserDefaults.standard.stringArray(forKey: declinedKey) ?? [])
            let keyboards = list.compactMap { entry -> (id: String, name: String)? in
                guard (entry["builtIn"] as? NSNumber)?.boolValue != true, let id = entry["id"] as? String else { return nil }
                return (id, entry["name"] as? String ?? "Keyboard")
            }
            guard let keyboard = keyboards.first(where: { !declined.contains("\(configuration.id.uuidString)|\($0.id)") }) else { return }
            guard NSApp.isActive, NSApp.modalWindow == nil,
                  !NSApp.windows.contains(where: { $0.attachedSheet != nil }) else {
                AVMLog.write("AVM: KeyboardOffer — \(keyboard.name) could go to \(configuration.name), but AVM isn't in front; asking at a later start.")
                return
            }
            ask(keyboard, machine: machine, configuration: configuration)
        }
    }

    private static func ask(_ keyboard: (id: String, name: String), machine: VMManager, configuration: VMConfiguration) {
        let alert = NSAlert()
        alert.messageText = "Use \(keyboard.name) for \(configuration.name)?"
        alert.informativeText = "A second keyboard is connected. As \(configuration.name)'s keyboard for Windows, it types only into Windows while \(configuration.name) runs, whichever app is in front, and your Mac's keyboard stays with your Mac and VoiceOver. You can change this in \(configuration.name)'s Settings, under Devices."
        alert.addButton(withTitle: "Use for Windows")
        alert.addButton(withTitle: "Not Now")
        let answer = alert.runModal()
        guard answer == .alertFirstButtonReturn else {
            var declined = UserDefaults.standard.stringArray(forKey: declinedKey) ?? []
            declined.append("\(configuration.id.uuidString)|\(keyboard.id)")
            UserDefaults.standard.set(declined, forKey: declinedKey)
            AVMLog.write("AVM: KeyboardOffer — \(keyboard.name) stays on the Mac for \(configuration.name) (Not Now).")
            return
        }
        // Saved as Settings saves it, from the list's copy, so nothing else
        // in the machine's settings is overwritten.
        var saved = VMStore.shared?.configurations.first(where: { $0.id == configuration.id }) ?? configuration
        saved.windowsKeyboardID = keyboard.id
        saved.windowsKeyboardName = keyboard.name
        VMStore.shared?.save(saved)
        AVMLog.write("AVM: KeyboardOffer — \(keyboard.name) is now \(configuration.name)'s keyboard for Windows.")
        guard machine.state == .running else { return }
        WindowsKeyboard.shared.start(keyboardID: keyboard.id, name: keyboard.name, target: machine,
                                     appleISO: saved.windowsKeyboardAppleISO == true)
    }
}
