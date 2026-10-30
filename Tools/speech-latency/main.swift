// main.swift — speech-latency
// AVM — Accessible Virtual Machine (roadmap item 5, measurement half)
//
// Measures keystroke-to-speech latency: how long after a key is pressed a
// screen reader inside a virtual machine starts speaking on the Mac's
// speakers. That gap is felt on every single key press, so it gets a
// number before anyone tunes buffers.
//
// HOW IT MEASURES
//   It presses a key through macOS (a CGEvent), exactly as a person would,
//   so the whole path is in the number: keyboard, the VM app's forwarding,
//   the guest's screen reader, the guest's audio, SPICE or the VM app's
//   own audio path, and CoreAudio. It listens to everything the Mac plays
//   through a CoreAudio process tap, and the latency is the time from the
//   key press to the first sample louder than the threshold. Because it
//   needs nothing from the VM app, the same run works for AVM, Parallels
//   or UTM on the same Mac: the comparison the roadmap asks for.
//
// BEFORE A RUN
//   - Put the VM window in front, with the keyboard in the guest (in AVM,
//     Enter Windows) and the guest's screen reader on, somewhere a key
//     makes it speak at once: a long list, or a document, for Down Arrow.
//   - Turn VoiceOver off on the Mac, and keep the Mac otherwise quiet:
//     every sound counts.
//   - The app running this (Terminal, say) needs two permissions, asked
//     for on the first run: Accessibility, to press keys, and Screen &
//     System Audio Recording, to hear the output.
//
// This tool says nothing while it measures, since its own speech would be
// measured; it prints results, and speaks only the summary at the end.
//
// Build and run: Tools/measure-speech-latency.sh (it compiles this file).

import Foundation
import CoreAudio
import AudioToolbox
import ApplicationServices

// MARK: - Options

struct Options {
    var keyName = "down"
    var count = 20
    var interval = 1.5
    var thresholdDB = -45.0
    var quietMS = 400.0
    var timeout = 3.0
    var startDelay = 5.0
    var label = "this VM"
    var csvPath: String?
    var speak = true

    static let keyCodes: [String: CGKeyCode] = [
        "down": 125, "up": 126, "left": 123, "right": 124,
        "space": 49, "tab": 48, "return": 36,
    ]

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func value() -> String {
            i += 1
            guard i < args.count else { fail("\(args[i - 1]) needs a value.") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--key": o.keyName = value().lowercased()
            case "--count": o.count = Int(value()) ?? o.count
            case "--interval": o.interval = Double(value()) ?? o.interval
            case "--threshold": o.thresholdDB = Double(value()) ?? o.thresholdDB
            case "--quiet-ms": o.quietMS = Double(value()) ?? o.quietMS
            case "--timeout": o.timeout = Double(value()) ?? o.timeout
            case "--start-delay": o.startDelay = Double(value()) ?? o.startDelay
            case "--label": o.label = value()
            case "--csv": o.csvPath = value()
            case "--no-speech": o.speak = false
            case "-h", "--help": usage(); exit(0)
            default: fail("Unknown option \(args[i]). Run with --help.")
            }
            i += 1
        }
        // Times must be positive: a negative one crashed the conversion to
        // host time (2026-10-25, code audit).
        guard o.interval > 0, o.timeout > 0, o.quietMS >= 0, o.startDelay >= 0 else {
            fail("--interval, --timeout, --quiet-ms and --start-delay can't be negative.")
        }
        guard keyCodes[o.keyName] != nil else {
            fail("Unknown key \(o.keyName). Use one of: \(keyCodes.keys.sorted().joined(separator: ", ")).")
        }
        guard o.count > 0 else { fail("--count must be at least 1.") }
        return o
    }
}

func usage() {
    print("""
    Usage: measure-speech-latency [options]

    Presses a key in the front window over and over and measures how long
    each press takes to be heard as speech.

      --key NAME         Key to press: down (default), up, left, right,
                         space, tab, return
      --count N          Presses to measure (default 20)
      --interval S       Seconds between presses (default 1.5)
      --threshold DB     Loudness that counts as speech, in dBFS
                         (default -45; raise it toward -30 in a noisy room)
      --quiet-ms MS      Silence needed before each press (default 400)
      --timeout S        Give up on a press after S seconds (default 3)
      --start-delay S    Seconds to bring the VM window forward (default 5)
      --label TEXT       Name for the report, e.g. "AVM 0.1.3" or "Parallels"
      --csv PATH         Also write one line per press to a CSV file
      --no-speech        Don't speak the summary at the end
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("Error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Host time

let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
}()

func hostTimeToSeconds(_ t: UInt64) -> Double {
    Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
}

func secondsToHostTime(_ s: Double) -> UInt64 {
    UInt64(s * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
}

// MARK: - Listening to the Mac's output

/// Taps everything the Mac plays and records, per IO buffer, the host time
/// of the first sample above the threshold. Written on CoreAudio's IO
/// thread, read on the main thread, behind a lock.
@available(macOS 14.2, *)
final class OutputTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let lock = NSLock()
    private var loudTimes: [UInt64] = []
    private var lastLoud: UInt64 = 0
    private var heardAnySample = false
    /// Behind the lock, like everything the IO thread writes.
    var heardAnything: Bool {
        lock.lock(); defer { lock.unlock() }
        return heardAnySample
    }
    private let threshold: Float
    private var sampleRate: Double = 48_000

    init(thresholdDB: Double) {
        threshold = Float(pow(10, thresholdDB / 20))
    }

    func start() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "create the audio tap")

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format), "read the tap's format")
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw ToolError("The audio tap delivers a format this tool doesn't read (\(format.mFormatID), \(format.mBitsPerChannel)-bit).")
        }
        sampleRate = format.mSampleRate

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Speech Latency Tap",
            kAudioAggregateDeviceUIDKey: "speech-latency-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the listening device")

        let channelsPerFrame = Int(max(format.mChannelsPerFrame, 1))
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { [weak self] _, input, inputTime, _, _ in
            self?.scan(input, at: inputTime.pointee, interleaved: interleaved, channels: channelsPerFrame)
        }, "listen to the tap")
        try check(AudioDeviceStart(aggregateID, procID), "start listening")
    }

    private func scan(_ list: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp,
                      interleaved: Bool, channels: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var firstLoudFrame: Int? = nil
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.assumingMemoryBound(to: Float.self)
            let stride = interleaved ? channels : 1
            for i in 0..<samples where abs(floats[i]) > threshold {
                let frame = i / stride
                if firstLoudFrame == nil || frame < firstLoudFrame! { firstLoudFrame = frame }
                break
            }
            if !heardAnySample {
                for i in 0..<samples where floats[i] != 0 {
                    lock.lock(); heardAnySample = true; lock.unlock()
                    break
                }
            }
        }
        guard let frame = firstLoudFrame, time.mFlags.contains(.hostTimeValid) else { return }
        let when = time.mHostTime + secondsToHostTime(Double(frame) / sampleRate)
        lock.lock()
        loudTimes.append(when)
        lastLoud = when
        if loudTimes.count > 4096 { loudTimes.removeFirst(2048) }
        lock.unlock()
    }

    /// Host time of the first loud sample after `t`, or nil.
    func firstLoud(after t: UInt64) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return loudTimes.first { $0 > t }
    }

    /// Seconds since the last loud sample (infinity if none yet).
    func quietFor(now: UInt64) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard lastLoud > 0, now > lastLoud else { return lastLoud == 0 ? .infinity : 0 }
        return hostTimeToSeconds(now - lastLoud)
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw ToolError("Could not \(step) (CoreAudio error \(status)).") }
    }
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Output latency

/// Seconds between the tap seeing a sample and the default output device
/// playing it: the device's latency, its safety offset and one IO buffer
/// (2026-10-25, code audit). The tap sees audio as it enters the system mix,
/// so without this the number left out 10–30 ms on built-in speakers and
/// 150 ms or more on Bluetooth or AirPlay, the part the listener hears.
func defaultOutputLatency() -> Double {
    func get(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : 0
    }
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
          device != kAudioObjectUnknown else { return 0 }
    var rate: Float64 = 0
    var rateSize = UInt32(MemoryLayout<Float64>.size)
    var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &rate) == noErr, rate > 0 else { return 0 }
    let frames = get(device, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
        + get(device, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
        + get(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
    return Double(frames) / rate
}

// MARK: - Pressing keys

func press(_ code: CGKeyCode) -> UInt64 {
    let source = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
    let t0 = mach_absolute_time()
    down?.post(tap: .cghidEventTap)
    up?.post(tap: .cghidEventTap)
    return t0
}

// MARK: - Statistics

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    let rank = p * Double(sorted.count - 1)
    let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - Double(lo))
}

func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }

// MARK: - Run

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

guard #available(macOS 14.2, *) else {
    fail("This tool needs macOS 14.2 or later, for CoreAudio process taps.")
}

let promptOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(promptOptions) else {
    fail("This app may not press keys yet. In System Settings, Privacy & Security, Accessibility, turn on the app running this tool (Terminal, for example), then run it again.")
}

let tap = OutputTap(thresholdDB: options.thresholdDB)
do {
    try tap.start()
} catch {
    fail("\(error)")
}
defer { tap.stop() }

let keyCode = Options.keyCodes[options.keyName]!
print("Measuring \(options.label): \(options.count) presses of \(options.keyName), threshold \(Int(options.thresholdDB)) dBFS.")
print("Bring the VM window to the front now, with the keyboard in the guest. Starting in \(Int(options.startDelay)) seconds.")
Thread.sleep(forTimeInterval: options.startDelay)

let outputLatency = defaultOutputLatency()
print(String(format: "The Mac's output device adds %.0f ms, which is included in every result.", outputLatency * 1000))

/// quiet: whether the Mac was quiet before the press. Presses made over
/// still-playing audio are shown but left out of the statistics
/// (2026-10-25, code audit): their "onset" is the old audio, so they read
/// as near zero and pulled the median down.
var results: [(trial: Int, latency: Double?, quiet: Bool)] = []
for trial in 1...options.count {
    // Wait for quiet, so the onset belongs to this press and not to the
    // tail of the last one. Up to 5 seconds; a press made without quiet
    // is still measured, and flagged.
    let quietDeadline = Date().addingTimeInterval(5)
    var wasQuiet = true
    while tap.quietFor(now: mach_absolute_time()) < options.quietMS / 1000 {
        if Date() > quietDeadline { wasQuiet = false; break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    let t0 = press(keyCode)
    let deadline = t0 + secondsToHostTime(options.timeout)
    var onset: UInt64? = nil
    while mach_absolute_time() < deadline {
        if let t = tap.firstLoud(after: t0) { onset = t; break }
        Thread.sleep(forTimeInterval: 0.005)
    }
    let latency = onset.map { hostTimeToSeconds($0 - t0) + outputLatency }
    results.append((trial, latency, wasQuiet))
    let note = wasQuiet ? "" : " (it wasn't quiet before this press, so it isn't counted)"
    print(String(format: "%3d  ", trial) + (latency.map(ms) ?? "no speech within \(options.timeout) s") + note)
    Thread.sleep(forTimeInterval: max(0, options.interval - (latency ?? options.timeout)))
}

let counted = results.filter(\.quiet)
let heard = counted.compactMap(\.latency).sorted()
let misses = counted.count - heard.count
let notQuiet = results.count - counted.count
print("")
print("\(options.label): \(heard.count) of \(counted.count) counted presses were heard." + (notQuiet > 0 ? " \(notQuiet) presses weren't counted, because audio was still playing." : ""))
var summary = ""
if heard.isEmpty {
    summary = tap.heardAnything
        ? "No press was heard within \(options.timeout) seconds. Check that a key makes the screen reader speak, or lower --threshold."
        : "The tool heard no sound at all. In System Settings, Privacy & Security, Screen & System Audio Recording, turn on the app running this tool, then run it again."
    print(summary)
} else {
    print("  median  \(ms(percentile(heard, 0.5)))")
    print("  10th    \(ms(percentile(heard, 0.1)))")
    print("  90th    \(ms(percentile(heard, 0.9)))")
    print("  fastest \(ms(heard.first!)), slowest \(ms(heard.last!))")
    summary = "\(options.label): median \(Int((percentile(heard, 0.5) * 1000).rounded())) milliseconds from key press to speech, over \(heard.count) presses."
    if misses > 0 { summary += " \(misses) presses weren't heard." }
}

if let path = options.csvPath {
    var csv = "label,trial,latency_ms,counted\n"
    for r in results {
        csv += "\"\(options.label)\",\(r.trial),\(r.latency.map { String(format: "%.1f", $0 * 1000) } ?? ""),\(r.quiet)\n"
    }
    do {
        try csv.write(toFile: path, atomically: true, encoding: .utf8)
        print("Wrote \(path)")
    } catch {
        print("Could not write \(path): \(error.localizedDescription)")
    }
}

if options.speak {
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = [summary]
    try? say.run()
    say.waitUntilExit()
}
exit(heard.isEmpty ? 1 : 0)
