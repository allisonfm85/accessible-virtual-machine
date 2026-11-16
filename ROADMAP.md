# AVM Roadmap

This is the working roadmap for AVM (Accessible Virtual Machine). It's a
living document. The order and content will change as tester feedback
comes in.

**How this list is ordered:** roughly in the order I expect to work on
things. Smaller items that help a lot can jump ahead, because frequent
releases get improvements to testers sooner. Effort estimates stay
provisional until an item gets a proper scoping pass, so items may move
as I learn more.

Have a request or want to influence priorities? Open an issue:
https://github.com/allisonfm85/accessible-virtual-machine/issues

## 1. Copy and paste between Windows and the Mac

Today AVM doesn't share the clipboard. Text copied in Windows never
reaches the Mac, and text copied on the Mac never reaches Windows.
That matters more for blind users than for most people. Copying an
error message or a command is often the easiest way to move text,
and retyping it by ear is slow and easy to get wrong. For now, a
shared file in a cloud folder works as a stopgap.

The pieces are already there. Every VM AVM installs gets the SPICE
agent, which is what carries clipboard text, and the library AVM uses
to talk to the VM supports it. AVM only needs to connect it to the
Mac clipboard.

One decision comes first, and it's about privacy. Sharing both ways
means Windows can read whatever is on the Mac clipboard, including
passwords copied from a password manager. The choices are both ways,
Windows to the Mac only, or a setting for each VM. Whatever the
answer, AVM will say clearly what's shared.

## 2. GPU acceleration in the guest

Reported by a tester (issue 7): games and other 3D applications in the
guest fall back to Windows' built-in software renderer, which crashes
some titles and makes others stutter. The cause is that AVM bundles no
guest display driver. Getting real graphics acceleration into the guest
is substantial work with real unknowns, so no version or date is
promised.

## 3. Importing virtual machines from other apps

Many blind Mac users already have a Windows VM in another app. AVM should
be able to bring it over instead of making them install Windows again.
UTM comes first, because it uses the same virtualization engine as AVM.
VMware Fusion and Parallels follow. Each import needs to be spoken from
start to finish, and it must never change or delete the original.

## 4. Virtual machines on external drives

Requested by a tester: the ability to store virtual machines on an
external drive instead of the internal disk. Windows VMs are large
(80 GB recommended), and not everyone has that to spare internally.
The design work is less about the storage itself and more about what
AVM says when the drive isn't attached. A missing drive must produce a
spoken, specific, actionable message, never a silent failure.

## 5. Audio latency

Testers report that audio latency in the guest is acceptable but could
be better. Parallels sets the benchmark here, and AVM should meet or beat
it. Latency matters more in AVM than in a typical VM product because a
screen reader's responsiveness is the interface. Every extra millisecond
between a keystroke and JAWS, NVDA, or Narrator speaking is felt on every
single interaction.

Measurement comes first: keystroke-to-speech latency in AVM and in
Parallels on the same hardware, so there's a baseline number. The fix is
scoped only after the numbers exist. It may be buffer tuning, or it may be
deeper work, and the measurements will tell which.

## 6. Shared folders

A folder on the Mac that Windows can open, so files move without a cloud
service in between (issue 19). AVM once had a shared folder setting that
never worked, and it was removed in 0.1.3. The real feature needs a
driver inside Windows and a clear, spoken way to choose the folder.

## 7. USB drives

USB passthrough works for braille displays, microphones, headsets,
keyboards and mice. Thumb drives and other USB storage don't reach
Windows yet, because macOS 27 blocks the way AVM captures them. I'm
working with Apple on a supported path. AVM tells you when you plug one
in.

## 8. ISO download assistant

A future version of AVM may fetch and verify the Windows ISO directly,
so the manual download step disappears. This is larger than it sounds.
The tooling would need to be bundled and signed, the sources involved
are fragile in ways that become a support burden, and a 30 to 90 minute
download must produce real spoken progress throughout. The tester
guide's walkthrough of Microsoft's download page covers the need well
for now.

## 9. More guest operating systems

Requested by a tester: guests beyond Windows 11 ARM64, such as other
Linux distributions and other versions of macOS. Each guest brings its
own accessibility story (which screen reader runs during install, and
how), so each is evaluated with the same standard AVM applies to
Windows: a blind user must be able to complete the entire install
without sighted help.

## Shipped

- **Display scaling and mouse input** (0.1.1, issues 3 and 4). The
  guest display fills the window, and the Windows pointer follows the
  Mac trackpad or mouse exactly.
- **Automatic updates** (0.1.2). AVM checks for updates and installs
  them, with every stage spoken.
- **Deleting a VM's files** (issue 5). Deleting a VM can move its files
  to the Trash, and AVM never deletes a VM that's still running.
- **USB passthrough** (0.1.3), except for USB drives (item 7 above).
- **Ubuntu Desktop for ARM** (0.1.3), the first guest beyond Windows.
  It installs with no questions, and Orca speaks from the first boot.
- **Secure Boot and a working TPM** (0.1.4, issues 16 and 17). Windows
  Update no longer blocks updates over its hardware checks. This also
  replaces the old Windows Insider item: the Insider program needed
  Secure Boot too, and whether to join it stays each tester's choice.
