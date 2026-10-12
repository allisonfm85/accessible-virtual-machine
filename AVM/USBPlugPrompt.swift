//
//  USBPlugPrompt.swift
//  AVM
//
//  USB increment 2b, piece 4 step 3: the plug-in alert and the spoken
//  lines. Step 3 only records the answer in the log. Step 4 acts on it.
//
//  Design of record (agreed with Allison 2026-10-11):
//  - A standard Mac alert, so VoiceOver reads it like any system alert.
//    No self-voicing when VoiceOver is off: users who need speech turn
//    VoiceOver on.
//  - Title "Send <name> to Windows?". Keep on Mac is the default for
//    both Return and Escape, so a quick key press never hands a device
//    to Windows. Sending always takes a deliberate choice.
//  - The Remember checkbox starts unchecked every time, and is absent
//    for always-ask devices.
//  - A device with no name is "a USB device from <maker>", or "an
//    unnamed USB device" when the maker isn't reported either.
//  - While the user is in Windows (focus lock on), or AVM is in the
//    background, the alert waits. AVM speaks one short line instead,
//    and shows the alert when the user is back. Alerts come one at a
//    time, in plug-in order.
//  - When the user comes back, the alert waits until Announcer has
//    finished speaking, so it doesn't talk over "Mac keyboard on".
//  - Unplugging a device with a question waiting is spoken, and the
//    question is dropped. Other unplugs stay quiet.
//  - The alert starts from the top (Allison, 2026-10-12). With keyboard
//    navigation on, a standard alert puts focus on its second button,
//    Send to Windows, where Space would send the device. AVM moves
//    focus to Keep on Mac once the alert is up. VoiceOver then reads
//    the title and message by itself. AVM once asked VoiceOver to read
//    them too, and they were heard twice, so AVM doesn't.
//
//  Run loop note: the alert runs modally from a run loop perform, not
//  from inside a main-queue block or Task. A modal loop started inside
//  a main-queue block stops that queue from draining, which would stall
//  the watcher's delayed class-code reads until the alert closed.
//

import AppKit
import Combine

/// One plugged-in device waiting for the user's answer.
struct USBPlugQuestion {
    let entryID: UInt64
    let vmID: UUID
    let identity: AVMUSBDeviceIdentity
    /// The maker's name the device reports, or nil.
    let vendorName: String?
    let kind: USBDeviceClassification.Kind
    let rememberOffered: Bool
}

final class USBPlugPrompt {
    static let shared = USBPlugPrompt()

    private var waiting: [USBPlugQuestion] = []
    private var onScreen: USBPlugQuestion?
    /// Why the open alert was closed by AVM rather than the user.
    private var closeReason: String?
    private var showScheduled = false

    private weak var watchedLock: FocusLockManager?
    private var lockWatch: AnyCancellable?
    private var activeWatch: NSObjectProtocol?
    private var escapeMonitor: Any?

    /// Pause before showing, so the focus change settles first.
    private static let firstPause: Duration = .milliseconds(600)
    private static let speechPoll: Duration = .milliseconds(200)
    /// Never wait longer than this for Announcer to go quiet.
    private static let longestSpeechWait: Duration = .seconds(6)

    private init() {}

    // MARK: Called by the watcher

    /// A device whose decision is "ask".
    func ask(_ question: USBPlugQuestion) {
        watchForReturn()
        let anotherIsOpen = onScreen != nil || showScheduled
        waiting.append(question)
        log("waiting: \(question.identity) as \(question.kind.rawValue), remember \(question.rememberOffered ? "offered" : "not offered"); \(waiting.count) waiting")

        let name = Self.sentenceName(question)
        if userIsInWindows {
            say("\(name) plugged in. AVM will ask about it when you're back on the Mac.")
        } else if NSApp.isActive == false {
            say("\(name) plugged in. AVM will ask about it when you switch back to AVM.")
        } else if anotherIsOpen {
            say("\(name) plugged in. AVM will ask about it next.")
        }
        scheduleShow()
    }

    /// A device went away. Speaks only when a question was waiting for it.
    func removed(entryID: UInt64) {
        if let current = onScreen, current.entryID == entryID {
            log("unplugged while its alert was open: \(current.identity); closing the alert")
            closeReason = "the device was unplugged"
            NSApp.abortModal()
            say("\(Self.sentenceName(current)) was unplugged.")
            return
        }
        if let index = waiting.firstIndex(where: { $0.entryID == entryID }) {
            let question = waiting.remove(at: index)
            log("unplugged before it was asked about: \(question.identity); question dropped")
            say("\(Self.sentenceName(question)) was unplugged.")
        }
    }

    /// The VM stopped. Its questions no longer mean anything.
    func vmStopped() {
        guard waiting.isEmpty == false || onScreen != nil else { return }
        log("VM stopped; dropping \(waiting.count) waiting \(waiting.count == 1 ? "question" : "questions")\(onScreen == nil ? "" : " and closing the open alert")")
        waiting.removeAll()
        if onScreen != nil {
            closeReason = "the VM stopped"
            NSApp.abortModal()
        }
    }

    // MARK: Showing

    private var userIsInWindows: Bool { FocusLockManager.shared?.isLocked == true }

    private func scheduleShow() {
        guard showScheduled == false, onScreen == nil, waiting.isEmpty == false,
              userIsInWindows == false, NSApp.isActive else { return }
        showScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: Self.firstPause)
            var waited: Duration = .zero
            while Announcer.shared.isSpeaking, waited < Self.longestSpeechWait {
                try? await Task.sleep(for: Self.speechPoll)
                waited += Self.speechPoll
            }
            // See the run loop note in the header.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    self.showScheduled = false
                    self.showNext()
                }
            }
        }
    }

    private func showNext() {
        guard onScreen == nil, waiting.isEmpty == false else { return }
        guard userIsInWindows == false, NSApp.isActive else {
            log("not showing yet: the user left the Mac or AVM before the alert could open")
            return
        }
        let question = waiting.removeFirst()
        onScreen = question
        closeReason = nil

        let alert = makeAlert(for: question)
        installEscape(for: alert)
        startFromTheTop(alert)
        log("alert open: \(question.identity)")
        let response = alert.runModal()
        removeEscape()
        onScreen = nil

        let remember = question.rememberOffered && alert.suppressionButton?.state == .on
        let rememberText = remember ? ", Remember checked" : ""
        switch response {
        case .alertFirstButtonReturn:
            log("chose keep on the Mac for \(question.identity)\(rememberText). Step 3 records this only.")
        case .alertSecondButtonReturn:
            log("chose send to Windows for \(question.identity)\(rememberText). Step 3 does not send yet.")
            say("AVM can't send devices to Windows yet. \(Self.sentenceName(question)) stays on the Mac for now.")
        default:
            log("alert closed by AVM: \(closeReason ?? "unknown reason")")
        }
        closeReason = nil
        scheduleShow()
    }

    private func makeAlert(for question: USBPlugQuestion) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Send \(Self.titleName(question)) to Windows?"
        alert.informativeText = Self.message(for: question.kind)
        // First button: Return. Escape is mapped to it in installEscape.
        _ = alert.addButton(withTitle: "Keep on Mac")
        _ = alert.addButton(withTitle: "Send to Windows")
        if question.rememberOffered {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Remember my choice for this device"
            alert.suppressionButton?.state = .off
        }
        return alert
    }

    /// Moves focus to Keep on Mac once the alert is up. Runs in the
    /// modal panel mode, so it fires inside runModal.
    private func startFromTheTop(_ alert: NSAlert) {
        alert.layout()
        let keep = alert.buttons.first
        alert.window.initialFirstResponder = keep
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated {
                guard let keep else { return }
                let moved = alert.window.makeFirstResponder(keep)
                self.log("focus moved to Keep on Mac: \(moved ? "yes" : "no")")
            }
        }
    }

    /// Escape picks Keep on Mac. NSAlert only maps Escape to a button
    /// named Cancel, so AVM catches it while this alert is the modal one.
    private func installEscape(for alert: NSAlert) {
        let alertWindow = alert.window
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { () -> NSEvent? in
                guard event.keyCode == 53, NSApp.modalWindow === alertWindow else { return event }
                NSApp.stopModal(withCode: .alertFirstButtonReturn)
                return nil
            }
        }
    }

    private func removeEscape() {
        if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor) }
        escapeMonitor = nil
    }

    // MARK: Coming back to the Mac

    /// Shows waiting alerts when focus lock turns off or AVM becomes
    /// the active app. Re-subscribes if a new FocusLockManager appeared.
    private func watchForReturn() {
        if let lock = FocusLockManager.shared, lock !== watchedLock {
            watchedLock = lock
            lockWatch = lock.$isLocked.sink { [weak self] locked in
                guard locked == false else { return }
                // @Published sends before the value changes, so check later.
                Task { @MainActor in self?.scheduleShow() }
            }
        }
        if activeWatch == nil {
            activeWatch = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleShow() }
            }
        }
    }

    // MARK: Words

    /// The name inside the alert title.
    static func titleName(_ question: USBPlugQuestion) -> String {
        if let product = productName(question) { return product }
        if let maker = makerName(question) { return "a USB device from \(maker)" }
        return "an unnamed USB device"
    }

    /// The name at the start of a spoken sentence. A product name is
    /// kept exactly as the device gives it.
    static func sentenceName(_ question: USBPlugQuestion) -> String {
        if let product = productName(question) { return product }
        if let maker = makerName(question) { return "A USB device from \(maker)" }
        return "An unnamed USB device"
    }

    private static func productName(_ question: USBPlugQuestion) -> String? {
        let name = question.identity.productString.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func makerName(_ question: USBPlugQuestion) -> String? {
        guard let name = question.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines),
              name.isEmpty == false else { return nil }
        return name
    }

    static func message(for kind: USBDeviceClassification.Kind) -> String {
        let macLoses = "If you send it to Windows, the Mac can't use it until you unplug it or shut down Windows."
        let voiceOverLoses = "If you send it to Windows, VoiceOver can't use it until you unplug it or shut down Windows. A Windows screen reader can use it instead."
        switch kind {
        case .ordinary:
            return "You plugged it in while Windows is running. \(macLoses)"
        case .brailleDisplay:
            return "This is a braille display. \(voiceOverLoses)"
        case .possibleBrailleDisplay:
            return "This might be a braille display. Some other devices use the same kind of connection. \(voiceOverLoses)"
        case .keyboard:
            return "This is a keyboard. \(macLoses)"
        case .mouse:
            return "This is a mouse or trackpad. \(macLoses)"
        case .soundOutput:
            return "Your Mac is playing sound through this device right now, including VoiceOver speech. If you send it to Windows, the Mac loses that sound until you unplug it or shut down Windows."
        case .unknownInput:
            return "This might be a keyboard, mouse, or other input device. \(macLoses)"
        }
    }

    // MARK: Helpers

    private func say(_ text: String) {
        Announcer.shared.announce(text, tone: .info)
    }

    private func log(_ message: String) {
        AVMLog.write("USBPlugPrompt: \(message)", category: "USBPlugPrompt")
    }
}
