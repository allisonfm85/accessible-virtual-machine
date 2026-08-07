# AVM Roadmap

This is the working roadmap for AVM (Accessible Virtual Machine).
This is a living document — order and content will change as tester
feedback comes in.

**How this list is ordered:** quickest first. Items that can be
implemented and shipped soonest come before larger ones, because
frequent releases keep the project moving and get improvements into
testers' hands sooner. Two caveats. First, effort estimates are
provisional until an item gets a proper scoping pass, so items may
move as we learn more. Second, USB passthrough holds a protected
place in the order: it is the feature blind musicians are waiting
for, and it will not be indefinitely displaced by smaller items —
it begins after a fixed number of quick items ship, regardless of
what else comes up.

Have a request or want to influence priorities? Open an issue:
https://github.com/allisonfm85/accessible-virtual-machine/issues

## 1. Windows Insider program enrollment

Requested: the ability to enroll a virtual machine in the Windows
Insider program to receive preview builds. Enrollment happens inside
Windows itself, and AVM already provides the TPM that Insider builds
require, so this may be mostly a matter of verifying the VM meets
the requirements and documenting the process in the tester guide.
A scoping pass will confirm whether anything in AVM itself needs to
change.

## 2. Virtual machines on external drives

Requested by a tester: the ability to store virtual machines on an
external drive instead of the internal disk. Windows VMs are large
(80 GB recommended), and not everyone has that to spare internally.
The design work here is less about the storage itself and more about
what AVM announces when the drive is not attached — a missing drive
must produce a spoken, specific, actionable message, never a silent
failure.

## 3. Automatic updates for AVM

An auto-updater, so testers stop needing to download new builds by
hand. The update experience itself must pass the same accessibility
bar as the rest of AVM: every stage spoken, fully operable with
VoiceOver, no silent failures.

## 4. Audio latency

Testers report that audio latency in the guest is acceptable but
could be better. Parallels sets the benchmark here, and AVM should
meet or beat it. Latency matters more in AVM than in a typical VM
product because a screen reader's responsiveness *is* the interface:
every extra millisecond between a keystroke and JAWS, NVDA, or
Narrator speaking is felt on every single interaction.

This item is split in two. Measurement comes first and starts early:
quantifying keystroke-to-speech latency in AVM and in Parallels on
the same hardware, so there is a baseline number. The fix is scoped
only after the numbers exist — it may be buffer tuning, or it may be
deeper pipeline work, and the measurements will tell us which.

## 5. USB passthrough — protected slot

Currently, USB keyboards work through event forwarding, and headsets
work for audio output. But devices that need a direct connection to
Windows — audio interfaces, MIDI controllers, thumb drives — require
true USB passthrough.

This is the top feature request from blind musicians who need their
audio interfaces and MIDI controllers working in the REAPER/OSARA
ecosystem on Windows. It holds a protected place in this list: it
starts after the quick items above ship, and smaller requests will
not displace it.

## 6. ISO download assistant

A future version of AVM may fetch and verify the Windows ISO
directly, so the manual download step disappears. This is larger
than it sounds: the underlying tooling would need to be bundled and
signed, the sources involved are fragile in ways that become a
support burden, and a 30–90 minute download must produce real spoken
progress throughout. The tester guide's improved walkthrough of
Microsoft's download page (thanks to a contributed rewrite) covers
the need well for now, so this stays deliberately behind the items
above it.

## 7. Additional guest operating systems

Requested by a tester: support for guests beyond Windows 11 ARM64 —
other versions and editions of Windows, Linux distributions, and
other versions of macOS. Each guest OS brings its own accessibility
story (which screen reader runs during install, and how), so these
will be evaluated individually with the same standard AVM applies to
Windows: a blind user must be able to complete the entire install
without sighted assistance.
