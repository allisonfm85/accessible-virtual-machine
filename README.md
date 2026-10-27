# AVM — Accessible Virtual Machine

AVM is a macOS application that lets blind and low-vision users install
and run Windows 11 ARM64 virtual machines entirely through VoiceOver —
no sighted assistance required at any step. Every failure produces a
spoken, specific, actionable announcement. It can also install Ubuntu
Desktop for ARM with no installer questions, with the Orca screen reader
speaking from the first boot (tester guide, section 16).

AVM is currently in early testing. It is distributed to testers as a
notarized DMG.

## For testers

Start with the tester guide: [AVM-TESTER-GUIDE.md](AVM-TESTER-GUIDE.md).
It covers everything from getting a Windows ISO to reporting problems.
Problems are reported through this repository's
[issues](../../issues) — and remember: if AVM fails silently, the
silence itself is a bug worth reporting.

## Making a virtual machine's disk larger

A virtual machine's disk only takes up as much space on your Mac as
Windows has actually used. The disk size you choose is a ceiling. When
Windows starts running out of room, you can raise it.

1. Shut down Windows, so the virtual machine is stopped.
2. In AVM, find your virtual machine in the list and choose its Settings
   button.
3. Raise Disk Size with the Up Arrow key, then choose Save Settings. AVM
   makes the disk larger, checks that it worked, and tells you the new
   size. A disk can grow but never shrink.

Windows won't use the new space until you extend drive C:

1. Start the virtual machine.
2. Press Command-X, which Windows receives as Windows-X, then press A to
   open Terminal (Admin). When Windows asks whether to allow changes,
   press Option-Y, which Windows receives as Alt-Y.
3. Type this command and press Enter. It prints nothing when it works.

   ```
   Resize-Partition -DriveLetter C -Size (Get-PartitionSupportedSize -DriveLetter C).SizeMax
   ```

4. To check, type this command and press Enter. It shows drive C's size
   in gigabytes.

   ```
   [math]::Round((Get-Partition -DriveLetter C).Size / 1GB)
   ```

This works for virtual machines AVM created, because AVM puts drive C
last on the disk. If you installed Windows some other way and the command
reports an error, a recovery partition may be in the way. Please open an
issue rather than deleting partitions yourself.

## USB devices

When you plug in a USB device while Windows is running, AVM decides what to do based on the USB Devices setting for that virtual machine. You'll find it in Settings, under the USB Devices heading. Each virtual machine keeps its own setting and its own remembered devices.

There are three choices. From left to right, they are:

- **Ask each time.** AVM asks before sending a device to Windows.
- **Always use in Windows.** Devices go straight to Windows. Keyboards, braille displays, and other input devices still ask.
- **Keep on the Mac.** Devices stay on the Mac.

When AVM asks, you can check "Remember my choice for this device" so it won't ask about that device again.

You can also attach or detach a device yourself at any time. In the Virtual Machine menu, choose Attach USB Device or Detach USB Device. A device you detach goes back to the Mac.

### What to expect

AVM always tells you when it sends a device to Windows, even when it does it automatically, so you're never left wondering where a device went.

If you plug in a device while you're working in Windows, or while AVM is in the background, AVM lets you know it's there. It waits to ask until you're back in AVM on the Mac, so you aren't pulled out of what you're doing.

If Windows is paused, AVM holds on to the device and sends it as soon as Windows resumes.

Some devices disconnect and reconnect when you change their mode. If a device you sent to Windows comes back within a minute, AVM sends it right back to Windows without asking. The minute gives you time to make the switch without rushing.

When Windows starts, AVM sends the devices you've chosen to remember for Windows once Windows has finished starting up. During Windows setup, AVM waits until setup is almost done, since that's when most people are ready to use their devices.

**USB flash drives don't work yet.** macOS 27 blocks AVM from sending a USB storage device to Windows. I'm working with Apple on a fix.

## Keeping a virtual machine on an external drive

In the Setup Wizard, under Where to Store It, choose Choose a Folder or
Drive, then pick the drive. AVM keeps everything for that machine there,
in a folder named AVM Virtual Machines. The dashboard says which drive
each machine is on. If the drive isn't connected, the dashboard says so,
and Start and Delete refuse until you connect it, so a machine is never
quietly recreated on your Mac or forgotten while its files are on the
drive. While Windows installs, AVM still needs about 8 gigabytes free on
the Mac itself for a short while.

## Secure Boot

New Windows machines have Secure Boot, with Microsoft's keys, so Windows
Update offers Insider preview builds. For an older machine, stop it, open
Settings, and turn on Secure Boot. AVM asks first, keeps a copy of the
old firmware settings, and puts them back if you turn Secure Boot off.
If BitLocker is on, Windows may ask for its recovery key after the switch.
The firmware is UTM's Secure Boot build of edk2; its licences ship with
it, in edk2-licenses.txt.

## When the Mac sleeps

Before the Mac sleeps, AVM pauses a running machine. When the Mac wakes,
AVM resumes it and tells you. A machine you paused yourself stays
paused. Windows' clock may take a minute to catch up.

## Braille displays

When you plug in a USB device while Windows is running, AVM checks whether it's a braille display before doing anything with it. A braille display is never sent to Windows without asking, even when "Always use in Windows" is chosen in Settings. If you check "Remember my choice for this device," AVM will use your choice from then on.

AVM recognizes a braille display in three ways:

- It identifies itself as a braille display. Most newer displays, like the Monarch, do this.
- Its model is in the list of USB braille displays kept by the BRLTTY project.
- It comes from a company that makes braille and low-vision products: HumanWare, Freedom Scientific, Baum, Handy Tech, EuroBraille, or Optelec.

Some displays use common USB chips that other gadgets also use. AVM treats those as possible braille displays, so it asks about them too.

**If AVM doesn't recognize your display,** please open an issue and include the display's name and model. Also include its USB IDs, if you can: plug in the display while Windows is running, then in AVM choose File, then Save Diagnostic Log, and attach the log. AVM records the IDs of each device plugged in, but never what you type.

**Using a Monarch with Windows:** open Braille Terminal, choose USB, and then plug in the Monarch. After you detach it from Windows, you may need to restart the Monarch before the Mac can use it again.

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

Ubuntu needs nothing extra in the repository: its answer file is
written by `VM/UbuntuInstallPipeline.swift` and added to a copy of the
user's own Ubuntu ISO with the bundled xorriso, and the SPICE guest
agent comes from Ubuntu's own archive during the install.

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

## Tests

`swift test` runs the logic tests: password hashing, the log sanitizer,
saved settings, the Ubuntu account checks, and the root USB helper's socket
check. They need no sysroot, so
they run on any Mac with Xcode. If you
build in a folder under ~/Documents, add
`--scratch-path ~/Library/Caches/AVM-build/swiftpm`: file syncing adds
file attributes there that stop the tests from being signed.

## Privacy

AVM cannot capture what you type into Windows: the code path for
logging keystroke contents does not exist. The diagnostic log never
records your username — paths are sanitized at the point of writing.
These are design commitments, and this repository is where you can
verify them.

## License

GPL v2. See [LICENSE](LICENSE).
