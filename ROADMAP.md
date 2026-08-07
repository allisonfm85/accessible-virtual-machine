# AVM Roadmap

This is the working roadmap for AVM (Accessible Virtual Machine).
Items are listed in priority order: the first item is what gets
worked on next. This is a living document — order and content will
change as tester feedback comes in.

Have a request or want to influence priorities? Open an issue:
https://github.com/allisonfm85/accessible-virtual-machine/issues

## 1. Audio latency

Testers report that audio latency in the guest is acceptable but
could be better. Parallels sets the benchmark here, and AVM should
meet or beat it. Latency matters more in AVM than in a typical VM
product because a screen reader's responsiveness *is* the interface:
every extra millisecond between a keystroke and JAWS, NVDA, or
Narrator speaking is felt on every single interaction.

Planned work: investigate buffering through the SPICE audio
pipeline, measure end-to-end latency against Parallels on the same
hardware, and reduce it wherever the pipeline allows.

## 2. USB passthrough

Currently, USB keyboards work through event forwarding, and headsets
work for audio output. But devices that need a direct connection to
Windows — audio interfaces, MIDI controllers, thumb drives — require
true USB passthrough.

This is the top feature request from blind musicians who need their
audio interfaces and MIDI controllers working in the REAPER/OSARA
ecosystem on Windows, and it is the first major feature planned
after the tester build stabilizes.

## 3. Virtual machines on external drives

Requested by a tester: the ability to store virtual machines on an
external drive instead of the internal disk. Windows VMs are large
(80 GB recommended), and not everyone has that to spare internally.

## 4. Additional guest operating systems

Requested by a tester: support for guests beyond Windows 11 ARM64 —
other versions and editions of Windows, Linux distributions, and
other versions of macOS. Each guest OS brings its own accessibility
story (which screen reader runs during install, and how), so these
will be evaluated individually with the same standard AVM applies to
Windows: a blind user must be able to complete the entire install
without sighted assistance.
