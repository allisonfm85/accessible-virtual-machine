# AVM Roadmap

This is the working roadmap for AVM (Accessible Virtual Machine).
This is a living document: order and content will change as tester
feedback comes in.

**How this list is ordered:** quickest first. Items that can be
implemented and shipped soonest come before larger ones, because
frequent releases keep the project moving and get improvements into
testers' hands sooner. Effort estimates are provisional until an item
gets a proper scoping pass, so items may move as we learn more. Items
keep their original numbers, so earlier discussions still point at the
right one.

Have a request or want to influence priorities? Open an issue at the
repository:
https://github.com/allisonfm85/accessible-virtual-machine/issues

## Done

Shipped, and described in the README and the tester guide. The version
in brackets is the one it shipped in.

### 1. Guest display scaling and mouse input (0.1.1)

Field-reported by a tester: the guest display rendered very small, and
the mouse did not work in the guest (issues #3 and #4). The display now
fills the window, and the Windows pointer follows the Mac's exactly,
through the SPICE agent and the vioserial driver that Windows setup
installs. Machines made before 0.1.1 get them with the recipe at the
end of the tester guide's section 14.

### 2. Deleting a VM deletes its files (0.1.2)

Reported by a tester (issue #5). Delete asks first, with Cancel as the
default button, and moves the machine's folder, disk and all, to the
Trash. Reclaim Disk Space, in the Virtual Machine menu, finds machine
folders that are no longer in the list and offers to trash them too.

### 3. Virtual machines on external drives (0.2.0)

Requested by a tester. Choose a Folder or Drive in the Setup Wizard
keeps a machine on an external drive; the dashboard says which drive
each machine is on, and Start and Delete refuse, out loud, while that
drive isn't connected. Export and Import move a machine between Macs.

### 4. Automatic updates for AVM (0.1.2)

Sparkle, with this fork's own update feed and signing key (README,
Publishing an update). Every stage is a normal dialog that reads with
VoiceOver.

### 6. USB passthrough (0.1.3)

The feature blind musicians were waiting for. Devices go to Windows
automatically or after asking, as the machine's USB Devices setting
says; braille displays always ask; Bluetooth HID devices go through
AVM's helper with no USB port; and a second keyboard can belong to
Windows alone. USB storage is the exception: macOS 27 blocks it, and
the maintainer is working with Apple on it (README, USB devices).

### 8. Secure Boot, the rescoped Insider item (0.2.0)

The scoping pass found that Insider enrollment worked but preview
builds refused to install without Secure Boot. New machines now have
UTM's Secure Boot build of the firmware with Microsoft's keys, and an
older machine turns it on in Settings, with its firmware settings kept
in case it is turned off again. Whether to enroll a machine in preview
builds remains each tester's own choice.

## Open

### 5. Audio latency

Testers report that audio latency in the guest is acceptable but
could be better. Parallels sets the benchmark here, and AVM should
meet or beat it. Latency matters more in AVM than in a typical VM
product because a screen reader's responsiveness *is* the interface:
every extra millisecond between a keystroke and JAWS, NVDA, or
Narrator speaking is felt on every single interaction.

The measurement half exists: `Tools/measure-speech-latency.sh` times a
key press to the first sound, the same way for any VM app, and each
machine's Sound setting trades about 40 milliseconds against crackle
(README, Sound). What remains is the measured comparison with
Parallels on the same Mac, and whatever it points at: buffer tuning,
or deeper pipeline work.

### 7. GPU acceleration in the guest

Reported by a tester (issue #7): games and other 3D applications in
Windows fall back to its software renderer, which crashes some titles
and makes others stutter. Linux machines got OpenGL acceleration in
0.3.0, through virtio-gpu-gl with ANGLE and virglrenderer from UTM's
build. Windows is the open part: its virtio-gpu drivers give it no 3D,
so this needs work in the guest driver, not only in AVM. No version or
date is promised.

### 9. ISO download assistant

Download Windows 11 for ARM, in the Setup Wizard, now opens Microsoft's
page, watches the download, says how it is going every gigabyte, checks
the file and picks it as the installer (tester guide, section 6).
Fetching the image without Microsoft's page stays behind: the tooling
would need to be bundled and signed, and the sources involved are
fragile in ways that become a support burden.

### 10. Additional guest operating systems

Requested by a tester. Each guest brings its own accessibility story
(which screen reader runs during install, and how), and each is held to
the same standard as Windows: a blind user must be able to complete the
entire install without sighted assistance.

Done so far: Ubuntu Desktop for ARM (26.04 and later), Debian with GNOME,
and Fedora Workstation (44 and later), all installed with no questions
and Orca speaking from the first boot (tester guide, section 16); and
macOS, on Apple's Virtualization framework (section 17). Still open:
other versions and editions of Windows, and Linux desktops other than
GNOME.
