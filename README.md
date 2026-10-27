# AVM — Accessible Virtual Machine

AVM is a macOS application that lets blind and low-vision users install
and run Windows 11 ARM64 virtual machines entirely through VoiceOver —
no sighted assistance required at any step. Every failure produces a
spoken, specific, actionable announcement. It can also install Ubuntu
Desktop for ARM, Debian or Fedora Workstation with no installer
questions, with the Orca screen reader speaking from the first boot
(tester guide, section 16), and macOS itself, from Apple.

AVM is currently in early testing. It is distributed to testers as a
notarized DMG.

## For testers

Start with the tester guide: [AVM-TESTER-GUIDE.md](AVM-TESTER-GUIDE.md).
It covers everything from getting a Windows ISO to reporting problems.
Problems are reported through this repository's
[issues](../../issues) — and remember: if AVM fails silently, the
silence itself is a bug worth reporting. **Help > Report a Problem**
puts a report on the clipboard (versions and the end of the diagnostic
log, without your user name) and opens a new issue for you to paste it
into.

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

## Backing up and moving a virtual machine

Shut a machine down, then choose Export beside it on the dashboard, or
Export Virtual Machine… in the Virtual Machine menu, and pick a folder or
drive. AVM saves the whole machine there as one folder ending in .avmvm,
saying how big it is, how far along it is, and when it's done. Import
Virtual Machine… brings it back, on this Mac or another, as a new entry
in your list, so it never collides with the original. Passwords AVM kept
for setup are left out. A machine that is running, still installing, or
saved rather than shut down is refused, with the reason. On an ExFAT or
FAT drive a disk takes its full size; APFS or Mac OS Extended keeps it
small. An imported macOS machine keeps its identity, so it is the same
Mac to macOS as the original: run only one of them at a time.

## Secure Boot

New Windows machines have Secure Boot, with Microsoft's keys, so Windows
Update offers Insider preview builds. For an older machine, stop it, open
Settings, and turn on Secure Boot. AVM asks first, keeps a copy of the
old firmware settings, and puts them back if you turn Secure Boot off.
If BitLocker is on, Windows may ask for its recovery key after the switch.
The firmware is UTM's Secure Boot build of edk2; its licences ship with
it, in edk2-licenses.txt.

## Copying between the Mac and Windows

Copy something on the Mac, enter Windows, and paste: it's there. What you
copy in Windows is ready to paste on the Mac straight away. This works for
text, rich text and pictures, through the SPICE agent AVM installs in
Windows. AVM never records what is copied. To keep the two clipboards
apart, turn off Share the clipboard in that machine's Settings.

## Screen readers from the first sign-in

When you make a Windows machine, AVM can install NVDA and JAWS for ARM,
so a screen reader is talking the moment you first sign in. JAWS installs
during Windows setup; NVDA installs at your first sign-in, as you, which
is what its installer needs. Narrator speaks through setup itself. NVDA is chosen by default. JAWS is your choice, because it
needs your own license. Without one it runs for 40 minutes at a time;
activate it in Windows. If you choose both, NVDA starts at sign-in.

AVM doesn't ship either one. It downloads each from its maker: NVDA's
newest release from NV Access's own update feed, JAWS's from winget's
public package list, or a known version if those can't be reached. A
download is used only if it comes from the maker's own server and
matches the checksum its maker publishes. AVM keeps the downloads, so your next machine doesn't download
them again. If a download fails, AVM says so and Windows installs
without that screen reader.

## Windows in other languages

Windows Setup runs in the language of the ISO you give it: AVM reads the
language from the ISO, so a French or German ISO works as an English
one does.

## Answers for Windows Setup

The setup wizard asks what Windows Setup would otherwise ask on screens
you can only get through with Narrator, and writes the answers into that
machine's own answer file: region, keyboard, time zone, computer name,
privacy settings, and the account. Each answer is filled in from your
Mac. The account can be a Microsoft account, signed in during setup, or
a local account from a name and password you type, which skips the
sign-in screens and signs in once by itself. AVM keeps the password only
in Windows' scrambled form, only until the install disc is built, and
removes the answer file once Windows is installed. Once Windows is
installed, AVM also deletes its copy of the install disc, about 8.5 GB.

NVDA starts with its laptop keyboard layout, since a Mac keyboard has
no Insert key or number pad; the wizard has a checkbox for it. The first
time a machine starts after Windows is installed, AVM says what setup
installed, or names anything that didn't install and how to install it.

## A keyboard for Windows

If you have a second keyboard, USB or Bluetooth, you can give it to
Windows: choose it under **Keyboard for Windows** in the machine's
Settings. While Windows runs, that keyboard types only into Windows,
whichever app is in front, and your Mac's keyboard stays with the Mac
and VoiceOver, so there is nothing to switch. macOS lets only a
privileged process take a keyboard over, so AVM's helper (the one that
connects USB devices) holds it and passes its keys to AVM alone; it never
takes the built-in keyboard or your only keyboard, gives it back when
Windows stops or AVM quits, takes it again if it disconnects and comes
back, and never records a key.

## macOS virtual machines

**New macOS Virtual Machine…** on the dashboard makes a macOS machine:
AVM gets the newest macOS your Mac supports from Apple (or uses an IPSW
file you have), downloads and installs it, and says how far it has got
throughout. macOS runs on Apple's own Virtualization framework, in its
own window with sound and a shared folder (My Shared Files in its
Finder). macOS's Setup Assistant offers VoiceOver itself: press Escape
when it speaks. To use VoiceOver inside the machine, turn your Mac's
VoiceOver off with Command-F5 while you work there; Command-Tab returns
to your Mac's apps.

## Debian

Choose a Debian arm64 installer (the netinst from debian.org works) in
the setup wizard, and AVM installs Debian with GNOME and Orca exactly as
it installs Ubuntu: no questions, Orca speaking from the first boot.

## Fedora

Choose the Fedora Everything netinstall ISO for aarch64, Fedora 44 or
later, from fedoraproject.org, and AVM installs Fedora Workstation (GNOME
and Orca) the same way, downloading it from Fedora's mirrors during the
install. The Workstation live image is not used: AVM says so and names
the download it needs (tester guide, section 16).

## Sharing a folder with Windows

In a Windows machine's Settings, choose Choose Folder to Share. Windows
shows that Mac folder in File Explorer as a network drive. You can let
Windows only read it. The change takes effect the next time the machine
starts. AVM installs the service that does this, spice-webdavd, during
Windows setup. A Windows installed by an older AVM needs it installed
from spice-space.org first.

## When the Mac sleeps

Before the Mac sleeps, AVM pauses a running machine. When the Mac wakes,
AVM resumes it, sets Windows' clock to the Mac's through the QEMU guest
agent it installs with Windows, and tells you. A machine you paused
yourself stays paused. Windows installed by an older AVM has no guest
agent, so its clock catches up at its next time sync.

## Sound

If speech from Windows starts to lag behind your keys during a long
session, turn on Shorter speech delay in the machine's Settings. It
keeps less sound waiting on the Mac: 70 ms instead of 220 ms on the
Mac's side. It's experimental, so turn it off again if sound crackles.

## Restore points

A restore point saves a virtual machine as it is, so you can put it back
later: before a big Windows update, or before trying Insider builds. Shut
the machine down, open its Settings, and choose Save a Restore Point. To
go back, choose Restore beside the one you want; AVM asks first, because
everything since then is lost. A restore point keeps the disk, the
firmware settings and the TPM, so BitLocker and Windows Hello still match
afterwards. Each one takes more disk space as Windows changes after it,
so delete the ones you no longer need. AVM saves one called **Fresh
install** by itself, the first time a machine starts after Windows is set
up, so a clean Windows is always minutes away.

**Reinstall Windows**, also in Settings, erases Windows on a stopped
machine and installs it again at the next Start, from the same installer
and with the same setup answers. It asks first.

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
saved settings, the Ubuntu account checks, the root USB helper's socket
check, and the screen reader download checks. They need no sysroot, so
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
