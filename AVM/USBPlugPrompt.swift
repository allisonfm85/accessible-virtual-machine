//
//  USBPlugPrompt.swift
//  AVM
//
//  USB increment 2b, piece 4: the plug-in alert, the spoken lines, and
//  acting on the answer (step 4): remembering it, and sending the device
//  to Windows through USBRedirectController, the same path the Attach
//  USB Device menu uses.
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
//  Step 4 design of record (agreed with Allison 2026-10-12):
//  - Sending goes through USBRedirectController.attach. USBHelperClient
//    speaks the outcome: "<name> is now in Windows." or the failure line
//    with its step and next action. Automatic sends (Always mode, a
//    remembered choice) are spoken the same way, never silent.
//  - A remembered "keep on the Mac" is silent. The watcher handles it.
//  - Remember saves this device's choice in this VM's settings, replacing
//    any earlier choice for the same device.
//  - Windows paused: the send is held. AVM says "Windows is paused. AVM
//    will send <name> when Windows resumes." On resume it is sent:
//    VMManager's state hook calls vmRunning(). If the
//    device is unplugged first, AVM says so and drops it. If Windows
//    stops instead, it is dropped quietly.
//  - Sends run one at a time, so two devices never race for a port.
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

    /// Devices waiting for Windows to resume before they are sent.
    private var heldForResume: [USBPlugQuestion] = []
    /// Devices already plugged in when Windows started, waiting for
    /// Windows to finish booting (USB 2c). A why of nil means the one
    /// start-time alert; otherwise it is a send.
    private var heldForWindows: [(question: USBPlugQuestion, why: String?)] = []
    /// True once Windows has booted in this run: the SPICE agent
    /// connected, or the fallback ran out.
    private var windowsHasBooted = false
    private var bootFallback: Task<Void, Never>?
    /// How long to wait for the agent when setup is finished. Only a VM
    /// without the agent should ever get this far.
    private static let bootFallbackWait: Duration = .seconds(120)
    /// The most recent send. Each send waits for the one before it.
    private var lastSend: Task<Void, Never>?

    /// Every automatic send goes through a gate for its physical device
    /// (USBRedirectController.followKey). A device can bounce while it is
    /// sent: macOS drops and re-adds it with a new address (log,
    /// 2026-10-18). The gate notes each bounce instead of reacting, waits
    /// until the device has been steady for settleQuiet seconds, then
    /// decides once: in Windows, retry once, give up with one line, or
    /// say nothing because it was really unplugged (Allison, 2026-10-18).
    /// Manual Attach USB Device does not use the gate.
    private struct SendGate {
        var question: USBPlugQuestion
        var attempts = 0
        var bounces = 0
        var lastActivity = Date()
    }
    private var gates: [String: SendGate] = [:]
    private static let settleQuiet: TimeInterval = 3
    private static let longestSettle: TimeInterval = 30
    private static let maxAttempts = 2

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
        // One question per physical device. macOS can drop and re-add a
        // device several times in a row, with a new address each time
        // (log, 2026-10-12), so a repeat replaces the older question.
        let key = Self.deviceKey(question.identity)
        if let index = waiting.firstIndex(where: { Self.deviceKey($0.identity) == key }) {
            waiting[index] = question
            log("arrived again while waiting: \(question.identity); replaced the older question for the same device")
            scheduleShow()
            return
        }
        if let current = onScreen, Self.deviceKey(current.identity) == key {
            onScreen = question
            log("arrived again while its alert is open: \(question.identity); the open alert now refers to it")
            return
        }
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

    // MARK: Start-time devices (USB 2c)

    /// A device already plugged in when Windows started. It waits until
    /// Windows has booted, because the firmware and Windows reset USB
    /// devices while booting, and a passed-through device then bounces
    /// on the Mac (log, 2026-10-18). why is nil for the start-time alert.
    func whenWindowsIsUp(_ question: USBPlugQuestion, sendBecause why: String?) {
        if windowsHasBooted {
            release(question, why: why)
            return
        }
        heldForWindows.append((question, why))
        log("held until Windows is up: \(question.identity) (\(why ?? "ask"))")
        if heldForWindows.count == 1 { startBootFallback() }
    }

    /// Windows has booted. Called when the SPICE agent connects, and by
    /// the fallback. Only the first call in a run does anything.
    func windowsIsUp(because reason: String) {
        guard windowsHasBooted == false else { return }
        windowsHasBooted = true
        bootFallback?.cancel()
        bootFallback = nil
        log("Windows is up: \(reason); releasing \(heldForWindows.count) held")
        let held = heldForWindows
        heldForWindows.removeAll()
        for item in held { release(item.question, why: item.why) }
    }

    private func release(_ question: USBPlugQuestion, why: String?) {
        if let why {
            send(question, because: why)
        } else {
            ask(question)
        }
    }

    /// During setup there is no fallback: setup restarts Windows several
    /// times, and each restart resets USB devices (Allison, 2026-10-18).
    private func startBootFallback() {
        guard bootFallback == nil else { return }
        guard VMManager.shared?.installCompleteAtStart == true else {
            log("Windows setup is not finished; held devices wait for the SPICE agent, with no fallback")
            return
        }
        bootFallback = Task { @MainActor [weak self] in
            try? await Task.sleep(for: USBPlugPrompt.bootFallbackWait)
            guard Task.isCancelled == false, let self else { return }
            self.windowsIsUp(because: "the SPICE agent did not connect within \(USBPlugPrompt.bootFallbackWait.components.seconds) seconds")
        }
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
            return
        }
        if let index = heldForResume.firstIndex(where: { $0.entryID == entryID }) {
            let question = heldForResume.remove(at: index)
            log("unplugged while held for resume: \(question.identity); dropped")
            say("\(Self.sentenceName(question)) was unplugged.")
            return
        }
        if let index = heldForWindows.firstIndex(where: { $0.question.entryID == entryID }) {
            let item = heldForWindows.remove(at: index)
            // Quiet: the user was never told about it.
            log("unplugged while held until Windows is up: \(item.question.identity); dropped")
        }
    }

    /// The VM stopped. Its questions no longer mean anything.
    func vmStopped() {
        for key in Array(gates.keys) { finishGate(key, .stopped) }
        windowsHasBooted = false
        bootFallback?.cancel()
        bootFallback = nil
        if heldForWindows.isEmpty == false {
            log("VM stopped; dropping \(heldForWindows.count) held until Windows is up")
            heldForWindows.removeAll()
        }
        if heldForResume.isEmpty == false {
            log("VM stopped; dropping \(heldForResume.count) held for resume")
            heldForResume.removeAll()
        }
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
        guard showScheduled == false, onScreen == nil, waiting.isEmpty == false else { return }
        // Why an alert waits is logged, to explain any delay before it.
        if userIsInWindows {
            log("alert held: the user is in Windows")
            return
        }
        if NSApp.isActive == false {
            log("alert held: AVM is not the active app")
            return
        }
        showScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: Self.firstPause)
            var waited: Duration = .zero
            while Announcer.shared.isSpeaking, waited < Self.longestSpeechWait {
                try? await Task.sleep(for: Self.speechPoll)
                waited += Self.speechPoll
            }
            if waited > .zero {
                self.log("alert waited \(waited) for AVM's speech to finish\(waited >= Self.longestSpeechWait ? " (gave up waiting)" : "")")
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
        var question = waiting.removeFirst()
        onScreen = question
        closeReason = nil

        let alert = makeAlert(for: question)
        installEscape(for: alert)
        startFromTheTop(alert)
        log("alert open: \(question.identity)")
        let response = alert.runModal()
        removeEscape()
        // The device may have re-arrived while the alert was open.
        if let latest = onScreen { question = latest }
        onScreen = nil

        let remember = question.rememberOffered && alert.suppressionButton?.state == .on
        let rememberText = remember ? ", Remember checked" : ""
        switch response {
        case .alertFirstButtonReturn:
            log("chose keep on the Mac for \(question.identity)\(rememberText)")
            if remember { self.remember(question, usesWindows: false) }
        case .alertSecondButtonReturn:
            log("chose send to Windows for \(question.identity)\(rememberText)")
            if remember { self.remember(question, usesWindows: true) }
            send(question, because: "chosen in the alert")
        default:
            log("alert closed by AVM: \(closeReason ?? "unknown reason")")
        }
        closeReason = nil
        scheduleShow()
    }

    private func makeAlert(for question: USBPlugQuestion) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Send \(Self.titleName(question)) to \(VMManager.currentGuestName)?"
        alert.informativeText = Self.message(for: question.kind)
        // First button: Return. Escape is mapped to it in installEscape.
        _ = alert.addButton(withTitle: "Keep on Mac")
        _ = alert.addButton(withTitle: "Send to \(VMManager.currentGuestName)")
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

    // MARK: Sending

    /// Sends a device to Windows: from the alert, a remembered choice,
    /// or Always mode. While Windows is paused, holds it until resume.
    func send(_ question: USBPlugQuestion, because why: String) {
        if let manager = VMManager.shared, case .paused = manager.state {
            heldForResume.append(question)
            log("send held: Windows is paused; \(question.identity) waits for resume (\(why))")
            let guest = VMManager.currentGuestName
            say("\(guest) is paused. AVM will send \(Self.titleName(question)) when \(guest) resumes.")
            return
        }
        log("sending \(question.identity) to Windows (\(why))")
        attachInOrder(question)
    }

    /// Opens a send gate for this device and runs gates one at a time.
    /// USBRedirectController picks a free port before it awaits QEMU, so
    /// two attaches at once could pick the same one.
    private func attachInOrder(_ question: USBPlugQuestion) {
        // USB drives can't go to Windows yet (USBRedirectController
        // header). Stop before a gate opens, so the gate never speaks a
        // misleading failure.
        if USBRedirectController.shared.refusesStorage(question.identity) { return }
        let key = USBRedirectController.followKey(question.identity)
        if gates[key] != nil {
            _ = gateAbsorbs(question)
            return
        }
        gates[key] = SendGate(question: question)
        USBHelperClient.shared.setQuiet(question.identity, true)
        log("send gate opened for \(question.identity)")
        let previous = lastSend
        lastSend = Task { @MainActor in
            await previous?.value
            await self.runGate(key)
        }
    }

    // MARK: Send gate (USB 2c)

    /// The watcher saw this device arrive. True when a gate is handling
    /// it: the gate takes the newest address and the watcher decides
    /// nothing.
    func gateAbsorbs(_ question: USBPlugQuestion) -> Bool {
        let key = USBRedirectController.followKey(question.identity)
        guard var gate = gates[key] else { return false }
        gate.question = question
        gate.bounces += 1
        gate.lastActivity = Date()
        gates[key] = gate
        log("send gate: \(question.identity) arrived again; noted (\(gate.bounces) so far)")
        return true
    }

    /// The watcher saw this device leave. Restarts the gate's quiet time.
    func gateNoteRemoval(_ identity: AVMUSBDeviceIdentity) {
        let key = USBRedirectController.followKey(identity)
        guard var gate = gates[key] else { return }
        gate.lastActivity = Date()
        gates[key] = gate
    }

    private func runGate(_ key: String) async {
        while var gate = gates[key] {
            gate.attempts += 1
            gate.lastActivity = Date()
            gates[key] = gate
            let device = gate.question.identity
            await USBRedirectController.shared.releaseStale(device)
            // To the machine the question was about (2026-10-27, several
            // machines at once), if it's still running.
            // A machine that has stopped meanwhile gets nothing; never the
            // current machine instead (2026-10-27, code audit).
            guard let machine = MachineSessions.shared.session(for: gate.question.vmID)?.manager else {
                finishGate(key, .stopped)
                return
            }
            let accepted = await USBRedirectController.shared.attach(device, to: machine, quiet: true)
            log("send gate: attempt \(gate.attempts) of \(Self.maxAttempts) for \(device): \(accepted ? "helper accepted" : "refused")")
            // This send asked for the helper's approval (2026-10-27, a
            // tester's keyboard): wait for it instead of using up the tries
            // 3 seconds later, while the user is still in System Settings,
            // and showing the approval dialog again. Then send it.
            if !accepted, USBHelperClient.shared.refreshStatus() == .requiresApproval {
                log("send gate: \(device) waits for the USB helper's approval")
                let approved = await USBHelperClient.shared.waitForApproval(while: {
                    gates[key] != nil && USBHotPlugWatcher.shared.isPresent(device) != false
                })
                guard gates[key] != nil else { return }
                if USBHotPlugWatcher.shared.isPresent(device) == false {
                    finishGate(key, .gone)
                    return
                }
                guard approved else {
                    finishGate(key, .notApproved)
                    return
                }
                log("send gate: helper approved; sending \(device) now")
                if var waiting = gates[key] {
                    waiting.attempts -= 1   // the refused try doesn't count
                    waiting.lastActivity = Date()
                    gates[key] = waiting
                }
                continue
            }
            await settle(key)
            guard let settled = gates[key] else { return }
            if USBRedirectController.shared.isInWindows(settled.question.identity) {
                finishGate(key, .inWindows)
                return
            }
            if USBHotPlugWatcher.shared.isPresent(settled.question.identity) == false {
                finishGate(key, .gone)
                return
            }
            if settled.attempts >= Self.maxAttempts {
                finishGate(key, .failed)
                return
            }
            log("send gate: \(settled.question.identity) settled on the Mac; trying once more")
        }
    }

    /// Waits until the device has been steady for settleQuiet seconds,
    /// or longestSettle has passed, or the gate was closed.
    private func settle(_ key: String) async {
        let started = Date()
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            guard let gate = gates[key] else { return }
            if Date().timeIntervalSince(gate.lastActivity) >= Self.settleQuiet { return }
            if Date().timeIntervalSince(started) >= Self.longestSettle {
                log("send gate: \(gate.question.identity) still bouncing after \(Int(Self.longestSettle)) seconds; deciding now")
                return
            }
        }
    }

    private enum GateOutcome { case inWindows, gone, failed, stopped, notApproved }

    /// Closes the gate and speaks its one outcome.
    private func finishGate(_ key: String, _ outcome: GateOutcome) {
        guard let gate = gates.removeValue(forKey: key) else { return }
        let device = gate.question.identity
        USBHelperClient.shared.setQuiet(device, false)
        USBRedirectController.shared.clearFollowThrough(device)
        let name = Self.titleName(gate.question)
        let tries = "\(gate.attempts) \(gate.attempts == 1 ? "attempt" : "attempts"), \(gate.bounces) \(gate.bounces == 1 ? "bounce" : "bounces")"
        switch outcome {
        case .inWindows:
            log("send gate closed: \(device) is in Windows (\(tries))")
            say("\(name) is now in \(VMManager.currentGuestName).", tone: .success)
        case .gone:
            log("send gate closed: \(device) is no longer on the Mac, so it was unplugged; nothing spoken (\(tries))")
        case .failed:
            let reason = gate.bounces > 0 ? "it kept disconnecting" : "\(VMManager.currentGuestName) didn't take it"
            log("send gate closed: \(device) not sent (\(tries))")
            say("AVM couldn't send \(name) to \(VMManager.currentGuestName). Reason: \(reason). Next: try Attach USB Device.", tone: .failure)
        case .stopped:
            log("send gate closed: \(device); the VM stopped")
        case .notApproved:
            log("send gate closed: \(device) not sent; the USB helper wasn't approved within 5 minutes")
            say("\(name) stayed on the Mac: AVM's USB helper hasn't been allowed. Next: in System Settings, General, Login Items and Extensions, allow AVM, then plug \(name) in again.", tone: .failure)
        }
    }

    /// Called by VMManager's state hook every time the VM reaches
    /// running, including after a resume. Sends anything held while
    /// Windows was paused. A stop instead drops them, through vmStopped.
    func vmRunning() {
        guard heldForResume.isEmpty == false else { return }
        let held = heldForResume
        heldForResume.removeAll()
        for question in held {
            log("Windows is running again; sending held \(question.identity)")
            attachInOrder(question)
        }
    }

    // MARK: Remembering

    /// Saves this device's choice in this VM's settings, replacing any
    /// earlier choice for the same device. Only called when the user
    /// checked Remember, so a braille display is never remembered
    /// without the user's own say.
    private func remember(_ question: USBPlugQuestion, usesWindows: Bool) {
        guard let store = VMStore.shared,
              var config = store.configurations.first(where: { $0.id == question.vmID }) else {
            log("remember failed: saved settings for VM \(question.vmID.uuidString) are not available")
            say("AVM could not remember your choice for \(Self.titleName(question)). Reason: this virtual machine's settings could not be read. Next: choose again the next time you plug it in.", tone: .failure)
            return
        }
        let id = question.identity
        var list = config.usbRememberedDevices ?? []
        list.removeAll { $0.matches(vendorID: Int(id.vendorID), productID: Int(id.productID), serialNumber: id.serialNumber) }
        list.append(RememberedUSBDevice(name: Self.titleName(question),
                                        vendorID: Int(id.vendorID),
                                        productID: Int(id.productID),
                                        serialNumber: id.serialNumber,
                                        decision: usesWindows ? "windows" : "mac"))
        config.usbRememberedDevices = list
        store.save(config)
        log("remembered \(usesWindows ? "use in Windows" : "keep on the Mac") for \(id) in VM \(question.vmID.uuidString)")
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

    /// The same physical device across re-arrivals: vendor, product, and
    /// serial number. The bus address can change when macOS re-adds a
    /// device. Devices with no serial share one key per vendor and product.
    static func deviceKey(_ identity: AVMUSBDeviceIdentity) -> String {
        "\(identity.vendorID):\(identity.productID):\(identity.serialNumber ?? "")"
    }

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
        let guest = VMManager.currentGuestName
        let macLoses = "If you send it to \(guest), the Mac can't use it until you unplug it or shut down \(guest)."
        let voiceOverLoses = "If you send it to \(guest), VoiceOver can't use it until you unplug it or shut down \(guest). A screen reader in \(guest) can use it instead."
        switch kind {
        case .ordinary:
            return "You plugged it in while \(guest) is running. \(macLoses)"
        case .brailleDisplay:
            return "This is a braille display. \(voiceOverLoses)"
        case .possibleBrailleDisplay:
            return "This might be a braille display. Some other devices use the same kind of connection. \(voiceOverLoses)"
        case .keyboard:
            return "This is a keyboard. \(macLoses)"
        case .mouse:
            return "This is a mouse or trackpad. \(macLoses)"
        case .soundOutput:
            return "Your Mac is playing sound through this device right now, including VoiceOver speech. If you send it to \(guest), the Mac loses that sound until you unplug it or shut down \(guest)."
        case .unknownInput:
            return "This might be a keyboard, mouse, or other input device. \(macLoses)"
        }
    }

    // MARK: Helpers

    private func say(_ text: String, tone: Announcer.Tone = .info) {
        Announcer.shared.announce(text, tone: tone)
    }

    private func log(_ message: String) {
        AVMLog.write("USBPlugPrompt: \(message)", category: "USBPlugPrompt")
    }
}
