// main.swift — audio-latency
// AVM — Accessible Virtual Machine
//
// Key-to-speech latency of a QEMU virtual machine, measured with no one at
// the screen (2026-10-26), so audio settings can be compared by number:
// Tools/measure-audio-latency.sh runs it once per setting.
//
// HOW IT MEASURES
//   - A key goes to the guest through QEMU's control socket (QMP
//     send-key), so nothing on the Mac's screen or keyboard is touched.
//     The default, Caps Lock+T, is Orca's "say the time" in the laptop
//     layout AVM sets up: a few words, spoken every time.
//   - It listens to ONE process's sound with a Core Audio process tap
//     (QEMU itself when QEMU plays to the Mac directly, or the SPICE client
//     that plays the guest's sound otherwise), so the Mac's own VoiceOver
//     and other apps aren't heard.
//   - The latency is from the key's send to the first sample louder than
//     the threshold, as the tapped process hands it to Core Audio. The
//     output device's own latency comes after that and is the same for
//     every setting, so it's left out; it's printed once for reference.
//
//   audio-latency --qmp PATH --pid PID [--keys caps_lock+t] [--count 20]
//                 [--interval 2.5] [--threshold -45] [--label TEXT]
//   audio-latency --output-rate    prints the Mac's output sample rate
//
// Needs the app running it to be allowed to record system audio (macOS
// asks once). Prints one line per press and a summary; exits 0.

import Foundation
import CoreAudio
import AudioToolbox

struct Options {
    var qmp = ""
    var pid: pid_t = 0
    var keys = ["caps_lock", "t"]
    var count = 20
    var interval = 2.5
    var thresholdDB = -45.0
    var quietMS = 500.0
    var timeout = 4.0
    var label = ""

    static func parse() -> Options {
        var o = Options()
        var args = Array(CommandLine.arguments.dropFirst())
        func value() -> String {
            guard !args.isEmpty else { fail("An option is missing its value.") }
            return args.removeFirst()
        }
        while !args.isEmpty {
            switch args.removeFirst() {
            case "--qmp": o.qmp = value()
            case "--pid": o.pid = pid_t(value()) ?? 0
            case "--keys": o.keys = value().split(separator: "+").map(String.init)
            case "--count": o.count = Int(value()) ?? o.count
            case "--interval": o.interval = Double(value()) ?? o.interval
            case "--threshold": o.thresholdDB = Double(value()) ?? o.thresholdDB
            case "--quiet-ms": o.quietMS = Double(value()) ?? o.quietMS
            case "--timeout": o.timeout = Double(value()) ?? o.timeout
            case "--label": o.label = value()
            case let other: fail("Unknown option \(other).")
            }
        }
        guard !o.qmp.isEmpty, o.pid > 0 else { fail("--qmp and --pid are required.") }
        return o
    }
}

func fail(_ message: String) -> Never {
    print("FAILED: \(message)")
    exit(1)
}

let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func seconds(_ hostTime: UInt64) -> Double { Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9 }

// MARK: QMP

final class QMP {
    private let fd: Int32
    init(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { fail("couldn't connect to QMP at \(path)") }
        _ = readLine()
        send(#"{"execute":"qmp_capabilities"}"#)
    }
    private func readLine() -> String {
        var line = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 10 { break }
            line.append(byte)
        }
        return String(decoding: line, as: UTF8.self)
    }
    /// Sends a command and waits for its reply (skipping events).
    @discardableResult func send(_ command: String) -> String {
        let bytes = Array((command + "\n").utf8)
        _ = write(fd, bytes, bytes.count)
        while true {
            let line = readLine()
            if line.isEmpty || line.contains("\"return\"") || line.contains("\"error\"") { return line }
        }
    }
}

// MARK: The tap

final class Listener {
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var loudTimes: [Double] = []      // host seconds of loud buffers' first loud sample
    private var lastLoud: Double = 0
    private let threshold: Float

    init(pid: pid_t, thresholdDB: Double) {
        threshold = Float(pow(10, thresholdDB / 20))
        var process = AudioObjectID(0)
        var p = pid
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &p, &size, &process) == noErr,
              process != 0 else { fail("process \(pid) has no audio object (has it played anything yet?)") }
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.isPrivate = true
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else { fail("couldn't create the audio tap") }
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, $0) }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AVM latency tap",
            kAudioAggregateDeviceUIDKey: "avm-latency-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid as String]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { fail("couldn't create the listening device") }
        var rate = Float64(48_000)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &rateSize, &rate)
        AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [self] _, input, inputTime, _, _ in
            let start = seconds(inputTime.pointee.mHostTime)
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for buffer in list {
                guard let data = buffer.mData else { continue }
                let channels = Int(max(1, buffer.mNumberChannels))
                let samples = Int(buffer.mDataByteSize) / 4
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0..<samples where abs(floats[i]) > threshold {
                    let t = start + Double(i / channels) / rate
                    lock.lock(); loudTimes.append(t); lastLoud = t; lock.unlock()
                    break
                }
            }
        }
        guard AudioDeviceStart(aggregateID, procID) == noErr else { fail("couldn't start listening") }
    }

    func firstLoud(after t: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return loudTimes.first { $0 >= t }
    }
    func quietFor(now: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return now - lastLoud
    }
    func stop() {
        AudioDeviceStop(aggregateID, procID)
        if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}

// MARK: Run

/// The Mac's default output's sample rate: QEMU's coreaudio output must
/// match it (AirPods in hands-free mode run at 24 000 Hz, 2026-10-27), and
/// the tap delivers at it.
func outputRate() -> Double {
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    var rate = Float64(48_000)
    size = UInt32(MemoryLayout<Float64>.size)
    address.mSelector = kAudioDevicePropertyNominalSampleRate
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
    return rate
}
if CommandLine.arguments.dropFirst().first == "--output-rate" {
    print(Int(outputRate()))
    exit(0)
}

let options = Options.parse()
let qmp = QMP(path: options.qmp)
let listener = Listener(pid: options.pid, thresholdDB: options.thresholdDB)
let keyList = options.keys.map { #"{"type":"qcode","data":"\#($0)"}"# }.joined(separator: ",")
let press = #"{"execute":"send-key","arguments":{"keys":[\#(keyList)],"hold-time":60}}"#

func now() -> Double { seconds(mach_absolute_time()) }
var results: [Double] = []
var missed = 0
Thread.sleep(forTimeInterval: 1)
for n in 1...options.count {
    // Silence first, so the speech found is this press's.
    let waitStart = now()
    while listener.quietFor(now: now()) < options.quietMS / 1000 && now() - waitStart < 10 {
        Thread.sleep(forTimeInterval: 0.05)
    }
    let sent = now()
    qmp.send(press)
    var found: Double?
    while now() - sent < options.timeout {
        if let t = listener.firstLoud(after: sent) { found = t; break }
        Thread.sleep(forTimeInterval: 0.01)
    }
    if let found {
        let ms = (found - sent) * 1000
        results.append(ms)
        print(String(format: "  %2d  %4.0f ms", n, ms))
    } else {
        missed += 1
        print(String(format: "  %2d  no speech within %.0f s", n, options.timeout))
    }
    fflush(stdout)
    Thread.sleep(forTimeInterval: options.interval)
}
listener.stop()
let sorted = results.sorted()
func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))] }
print(String(format: "RESULT %@: median %.0f ms, best %.0f, 90th %.0f, worst %.0f, %d heard, %d missed",
             options.label.isEmpty ? "run" : options.label, pct(0.5), sorted.first ?? 0, pct(0.9), sorted.last ?? 0, sorted.count, missed))
