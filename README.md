# AVM — Accessible Virtual Machine

AVM is a macOS application that lets blind and low-vision users install
and run Windows 11 ARM64 virtual machines entirely through VoiceOver —
no sighted assistance required at any step. Every failure produces a
spoken, specific, actionable announcement.

AVM is currently in early testing. It is distributed to testers as a
notarized DMG.

## For testers

Start with the tester guide: [AVM-TESTER-GUIDE.md](AVM-TESTER-GUIDE.md).
It covers everything from getting a Windows ISO to reporting problems.
Problems are reported through this repository's
[issues](../../issues) — and remember: if AVM fails silently, the
silence itself is a bug worth reporting.

## What's in this repository

The complete AVM application source (Swift/SwiftUI), the Xcode project,
and the install-media resources: the unattended-install answer file
template; the virtio ARM64 drivers for network, memory balloon, and
serial channel (vioserial), from the Fedora virtio-win project; and the
SPICE guest agent installer (the standalone spice-vdagent for Windows,
from the SPICE project), which new installs place inside the guest
during Windows setup so absolute mouse positioning works from the very
first out-of-box-experience screen. Like the other virtio drivers,
these are redistributed unmodified under their upstream licenses (GPL
family), matching this project's GPL v2.

Deliberately **not** in this repository: the binary dependencies —
QEMU, SPICE, GStreamer, and related frameworks, plus EFI firmware
images. These are staged at build time from the UTM project's
prebuilt sysroot, with one local patch (a GStreamer osxaudio deadlock
fix, backported from upstream). The staging steps live in
the Run Script build phase inside
`AVM.xcodeproj/project.pbxproj`. The SPICE display layer comes from a
pinned fork of CocoaSpice: https://github.com/allisonfm85/CocoaSpice

## Building from source

Building requires Xcode on Apple Silicon, the UTM sysroot, and macOS 13
Ventura or later as the deployment target. The sysroot location is one
build setting, `AVM_SYSROOT`. It defaults to
`$(HOME)/Developer/sysroot-macos-arm64/sysroot-macOS-arm64`. Keep the
sysroot there and the project builds as is. Keep it somewhere else and
override the setting, either in Xcode's build settings or on the
command line with `xcodebuild AVM_SYSROOT=/your/path`.
The bundled xorriso must be 1.5.8.pl02 or later — earlier versions
produce install ISOs the Windows boot loader cannot read.

## Privacy

AVM cannot capture what you type into Windows: the code path for
logging keystroke contents does not exist. The diagnostic log never
records your username — paths are sanitized at the point of writing.
These are design commitments, and this repository is where you can
verify them.

## License

GPL v2. See [LICENSE](LICENSE).
