//
//  USBPlugDecisionTests.swift
//  AVMTests
//
//  The plug-in rules of record in USBPlugDecision.swift. A wrong answer
//  here can take a blind user's keyboard or braille display away, so
//  every rule is pinned.
//

import Testing

@Suite("USB plug-in decision")
struct USBPlugDecisionTests {

    typealias Protection = USBDeviceClassification.Protection

    private func decide(_ mode: USBPlugMode, _ remembered: Bool?, _ protection: Protection) -> USBPlugDecision {
        USBPlugDecider.decide(mode: mode, remembered: remembered, protection: protection).decision
    }

    private func atStart(_ mode: USBPlugMode, _ remembered: Bool?, _ protection: Protection) -> USBPlugDecision {
        USBPlugDecider.decideAtStart(mode: mode, remembered: remembered, protection: protection).decision
    }

    // MARK: Plug-in

    @Test("rule 1: a protected device always asks, with no Remember", arguments: [USBPlugMode.ask, .always, .keepOnMac])
    func protectedAlwaysAsks(mode: USBPlugMode) {
        #expect(decide(mode, nil, .alwaysAsk) == .ask(rememberOffered: false))
        #expect(decide(mode, true, .alwaysAsk) == .ask(rememberOffered: false))
    }

    @Test("rule 1 exception: a remembered keep on the Mac is honored", arguments: [USBPlugMode.ask, .always, .keepOnMac])
    func protectedRememberedKeep(mode: USBPlugMode) {
        #expect(decide(mode, false, .alwaysAsk) == .keepOnMac)
    }

    @Test("rule 2: a remembered choice beats the mode", arguments: [USBPlugMode.ask, .always, .keepOnMac])
    func rememberedBeatsMode(mode: USBPlugMode) {
        #expect(decide(mode, true, .none) == .sendToWindows)
        #expect(decide(mode, false, .none) == .keepOnMac)
        #expect(decide(mode, true, .brailleDisplay) == .sendToWindows)
        #expect(decide(mode, false, .brailleDisplay) == .keepOnMac)
    }

    @Test("rule 3: keep on the Mac mode keeps unremembered devices")
    func keepMode() {
        #expect(decide(.keepOnMac, nil, .none) == .keepOnMac)
        #expect(decide(.keepOnMac, nil, .brailleDisplay) == .keepOnMac)
    }

    @Test("rule 4: Always mode never takes a braille display without asking")
    func brailleAsksInAlwaysMode() {
        #expect(decide(.always, nil, .brailleDisplay) == .ask(rememberOffered: true))
        #expect(decide(.ask, nil, .brailleDisplay) == .ask(rememberOffered: true))
    }

    @Test("rule 5: Always mode sends ordinary devices")
    func alwaysMode() {
        #expect(decide(.always, nil, .none) == .sendToWindows)
    }

    @Test("rule 6: Ask mode asks, with Remember offered")
    func askMode() {
        #expect(decide(.ask, nil, .none) == .ask(rememberOffered: true))
    }

    @Test("every decision explains itself for the log")
    func reasons() {
        let (_, why) = USBPlugDecider.decide(mode: .always, remembered: nil, protection: .brailleDisplay)
        #expect(why.hasPrefix("rule 4"))
    }

    // MARK: At start

    @Test("at start: remembered for Windows goes over")
    func startRememberedSend() {
        #expect(atStart(.ask, true, .none) == .sendToWindows)
        #expect(atStart(.keepOnMac, true, .brailleDisplay) == .sendToWindows)
    }

    @Test("at start: Always mode sends ordinary devices")
    func startAlways() {
        #expect(atStart(.always, nil, .none) == .sendToWindows)
    }

    @Test("at start: anything that would ask stays on the Mac quietly")
    func startQuietKeep() {
        #expect(atStart(.ask, nil, .none) == .keepOnMac)
        #expect(atStart(.always, nil, .brailleDisplay) == .keepOnMac)
        #expect(atStart(.ask, nil, .alwaysAsk) == .keepOnMac)
    }

    @Test("at start: a device remembered for Windows that is now protected still asks")
    func startProtectedRememberedAsks() {
        #expect(atStart(.ask, true, .alwaysAsk) == .ask(rememberOffered: false))
    }

    @Test("Ask is the default mode")
    func defaultMode() {
        #expect(USBPlugMode(rawValue: "ask") == .ask)
    }
}
