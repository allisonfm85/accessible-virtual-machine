# AVM Tester Guide

AVM (Accessible Virtual Machine) lets you install and run Windows 11 on your
Mac entirely with VoiceOver. No sighted help is needed at any step. This
guide covers what you need, what you will hear, and what to do when
something seems wrong.

This is a tester build. It works end to end on my own hardware, but you are
the first people to run it anywhere else. Everything you notice is worth
reporting, especially anything that happens silently.

AVM is free software under the GNU General Public License, version 2. The
project lives at https://github.com/allisonfm85/accessible-virtual-machine

---

## 1. What you need before you start

- **An Apple Silicon Mac.** AVM runs Windows 11 for ARM64 using Apple's
  hardware virtualization. Intel Macs cannot run it.
- **macOS 13 Ventura or later.**
- **At least 80 GB of free disk space.** A Windows 11 installation grows to
  roughly 40 GB, the virtual disk needs room to grow beyond that, and the
  install process needs working room of its own. The virtual disk file
  starts small and grows as Windows uses it, so choosing a large disk size
  does not spend that space up front.
- **A Windows 11 ARM64 installation disc image (ISO).** You supply this
  yourself. See section 2.
- **Time and quiet.** Plan on an uninterrupted stretch for your first
  install. Most of the work happens without speech, and you will want to be
  listening.

---

## 2. Getting the Windows 11 ISO

Microsoft distributes Windows 11 disc images from its own download page. You
need the **ARM64** image, not the x64 one. AVM cannot use an x64 image, and
it will tell you so instead of failing quietly.

Downloading the ISO is the one step of the process that happens outside AVM.
The page works with a screen reader, but the controls appear in stages.
Each one you use reveals the next, so it helps to know what is coming.

### The download page

Go to:

    https://www.microsoft.com/software-download/windows11arm64

Work through it in this order:

1. Find the combo box labeled **Select Download** and choose
   **Windows 11 (multi-edition ISO for Arm64)**. It is the only choice.
2. Activate the **Download Now** button.
3. A new section appears, headed "Select the product language". Find the
   combo box labeled **Choose one** and pick your language. For most
   testers that is **English (United States)**.
4. Activate the **Confirm** button.
5. After a few seconds a link appears reading
   **Download - Windows 11 Arm64 English** (the language will match what you
   chose), followed by a second **Download Now** button. Activate that button
   to start the download.

**A warning about step 5.** At that point there are two buttons on the page
called "Download Now". One is the button you already used in step 2, and
the real one is at the bottom. If you navigate by button, the first one you
land on is the old one, and activating it again just shows the language
picker again. The one you want is the last "Download Now" on the page. The
quickest way to land on it is to go to the end of the page and work
backwards.

### What you should end up with

A single `.iso` file of about eight gigabytes. The English 25H2 image is
7,994,415,104 bytes, so budget more than the "about 5 GB" figure that
circulates in older write-ups.

The build I validated during development was:

    Win11_25H2_English_Arm64_v2.iso
    Windows 11, version 25H2, build 26200

At the time of writing, the download page serves this same version. Other
ARM64 images are expected to work. If yours does not, that is exactly the
kind of thing to report.

Note that this is a *multi-edition* image. It contains Home, Pro and the
rest, and the edition is settled during installation, not by which file you
download. You do not need to hunt for a Pro-specific ISO.

**Checking you got the ARM64 one.** The filename is the first clue: it
should have `Arm64` in it. If the file has been renamed, or you want to be
certain before starting an install, open Terminal and run:

    file ~/Downloads/Win11_25H2_English_Arm64_v2.iso

Adjust the path to match yours. The reply includes a volume name. If it
reads `A64FRE`, you have the ARM64 image. If it reads `X64FRE`, that is the
x64 one and AVM will refuse it.

### The link expires

The download link Microsoft builds for you is good for **24 hours** from the
moment you press Confirm. The page states the exact expiry time. If your
download is interrupted and the link has gone stale, go back to the page and
walk through the steps again. You will get a fresh link. Nothing is wrong,
and you have not used anything up.

Put the ISO somewhere you can find it again. Your Downloads folder is fine.

### If the page gives you trouble

There is a second route. **CrystalFetch** is a free Mac app that builds a
Windows 11 ARM64 ISO for you, from the same Microsoft sources, without the
staged web form. It comes from Turing Software, the people behind UTM, and
lives at:

    https://github.com/TuringSoftware/CrystalFetch

It is a native Mac application instead of a web page, which some testers
may find easier. I have not tested CrystalFetch with VoiceOver yet, so this
is an alternative to try, not a recommendation. If you use it, please
report which of the two routes worked better for you. That report will
decide what this section says in the future.

A future version of AVM may fetch and verify the image for you directly, so
that none of this is necessary.

*This section was substantially improved by a detailed walkthrough and
proposed rewrite contributed by Kelly Ford. Thank you, Kelly!*

---
## 3. Installing AVM

AVM arrives as a disk image. Open it, put AVM in your Applications
folder, and eject the disk image. Launch AVM the way you launch anything
else.

The first time Windows starts, your Mac will ask whether AVM can find
devices on your local network. This is macOS asking, because Windows needs
a network connection. Choose Allow. If VoiceOver is off when the question
appears, AVM will announce that another window took the keyboard. Turn
VoiceOver on, read the dialog, choose Allow, and you'll hear "Keyboard
back in Windows."

**Updates.** When AVM first wants to check for updates, it asks your
permission. Say yes and this is the last version you'll ever install by
hand: when a new version is ready, AVM offers it, downloads it, and
relaunches itself. You can also check any time with Check for Updates in
the AVM menu. Everything is a normal dialog and reads with VoiceOver.

---

## 4. Before your first install: three Mac keyboard settings

Windows needs keys that macOS normally keeps for itself. Three settings,
all in System Settings, make sure your keystrokes actually reach Windows.
Set them once before your first install.

1. **Use F1, F2, and so on as standard function keys: ON.** In System
   Settings, go to Keyboard, and turn on "Use F1, F2, etc. keys as
   standard function keys." Windows screen readers lean on the function
   keys, and this setting hands them over cleanly.
2. **Mission Control's Control-arrow shortcuts: OFF.** In System
   Settings, go to Keyboard, then Keyboard Shortcuts, then Mission
   Control, and turn off the shortcuts for "Move left a space" and "Move
   right a space." Otherwise the Mac grabs Control with the arrow keys,
   which in Windows is how you move word by word through text.
3. **The Show Desktop shortcut: OFF.** In the same Keyboard Shortcuts
   window, under Mission Control, turn off "Show Desktop." Otherwise the
   Mac takes F11, which your Windows screen reader needs.

**Here's the general rule, and it's worth remembering past these three:**
if Windows never reacts to a key, no matter how many times you press it,
the Mac probably took it first. Check System Settings, Keyboard, Keyboard
Shortcuts for a shortcut using that key, and turn it off.

---

## 5. The dashboard

The first thing you meet is the dashboard. With VoiceOver's heading
navigation it reads in this order:

- **AVM** is the app title, a level-one heading.
- **Each virtual machine's name** is a level-two heading. Under each name is
  a plain line of specifications (cores, memory, disk size) and two buttons,
  Start and Delete, each labeled with that machine's name.
- **Status** is a level-three heading, below the machine list. It describes
  what AVM is currently doing.

The dashboard also has a **Setup Wizard** button. That is how you create a
new virtual machine. See section 6. If you have no machines yet, the list is
empty and that button is your first stop.

**Delete asks first.** Deleting a virtual machine moves its disk — and
everything on it — to the Trash, so AVM puts up a confirmation. Cancel is
the default button, so pressing Return backs out safely. You have to
deliberately choose Delete. If you change your mind afterward, the
machine's folder is in the Trash until you empty it.

**Reclaim Disk Space.** The Virtual Machine menu has a Reclaim Disk Space
command. It looks for machine folders on disk that no longer appear in
your list, tells you how much space each one holds, and moves the ones you
pick to the Trash.

Your machines live in your Library folder, under Application Support, in a
folder named AVM. You do not need to go there, but that is where the space
is going.

---

## 6. Creating your first virtual machine

Press the **Setup Wizard** button on the dashboard. When the wizard opens,
your cursor is placed in the name field for you.

The window reads top to bottom:

- **Setup Wizard** is the title, a heading.
- **Virtual machine name** is a text field. Any name you like. The suggested
  example is "My Windows 11".
- **CPU cores** is a stepper, starting at 4. Adjust it with the arrow keys.
  The minimum is 2, and the maximum is half the cores your Mac has.
- **Memory** is a stepper, starting at 8 gigabytes, moving in steps of 2.
  The minimum is 4, and the maximum is half your Mac's memory.
- **Disk size** is a stepper, starting at 64 gigabytes, moving in steps of
  10. The minimum is 40. The maximum is based on your free disk space, and
  it always leaves your Mac roughly 20 gigabytes of headroom. Remember, the
  disk file starts small and grows as Windows uses it.
- **Windows installer image** reads "No installer selected" until you
  choose one. The **Choose Installer Image** button opens a standard file
  picker. Navigate to your ISO and choose it. The wizard then reads back
  the file's name so you know what it took.
- **Cancel** and **Create Virtual Machine**. Escape cancels, and
  Command-Return creates. While the machine is being created the button
  reads "Creating virtual machine, please wait". It takes a moment,
  because AVM builds the machine's disk file right then.

If you press Create before the form is complete, the wizard tells you, on
screen and out loud, what is still needed. That is guidance, not an error.
Nothing is broken. The form just isn't finished yet.

When creation finishes, the wizard closes and you are back on the
dashboard, where the new machine now has its own heading, its
specifications, and its Start and Delete buttons.

---

## 7. The install: what you will hear

Start the machine (section 8 covers the keyboard steps, so read it first).
AVM begins by opening your ISO and reading the list of Windows editions
inside it. If that check fails, you get a spoken explanation of what was
wrong with the file. That is on purpose. A bad ISO caught in seconds is
much kinder than one caught forty minutes into an install.

Then AVM builds custom installation media on your disk and starts the
virtual machine. The build is fast, just seconds on a fast Mac.

**First announcement, spoken in the system voice:**

> Install media ready. Starting the virtual machine.

These announcements use the Mac's system voice instead of VoiceOver, on
purpose. You will hear them whether VoiceOver is on or off, and whether or
not AVM is the frontmost app.

**A few minutes later, the milestone announcement:**

> Windows Setup is underway and will restart the virtual machine a few times.
> This takes a while. Windows will not speak on its own. When Setup is done,
> enter Windows and press Control Command Return to turn on Narrator.

Read that last sentence carefully, because it is the part people get wrong:
**Windows does not start talking by itself.** Silence after this point is
normal and expected. It does not mean the install failed. Your Mac's fans
may run hard the whole time. That is also normal.

**How long is "a while"?** It varies a lot between Macs. On fast hardware
it has been under a minute. On slower machines it can be much longer. Do
not treat any particular length of time as wrong.

**You may hear a Windows startup sound.** When Setup reaches the setup
screen, the guest sometimes plays Windows' own startup chime. If you hear
it, that is your cue. But it does not play every time, so its absence
proves nothing. Either way the steps are the same: wait, then try the
Narrator shortcut. If nothing happens, leave Windows, wait longer,
re-enter, and try again.

---

## 8. The keyboard model: when to turn VoiceOver off

This is the most important section in the guide. Please read it before your
first install, not after.

Here's the main idea. While your keyboard is in Windows, you are a Windows
user. VoiceOver should be off. If two screen readers are running at once,
they fight over the same keystrokes, and neither one works right.

### Starting a machine

1. On the AVM dashboard, press **Command-F5** to turn VoiceOver off first,
   while the keyboard still belongs to the Mac.
2. Press **Command-Shift-S** to start the virtual machine, or use the
   machine's Start button.
3. As soon as the Windows view appears, your keyboard is in Windows. You
   don't have to do anything else. You will hear the system voice say
   **"Windows keyboard on."** You'll hear it even with VoiceOver off —
   that's how you know the handover happened.

From here, every keystroke goes to Windows.

### Leaving Windows

1. Press **Control-Command-Escape**. This is the escape hatch.
2. You will hear **"Mac keyboard on."**
3. Press **Command-F5** to turn VoiceOver back on.

### Going back into Windows

Turn VoiceOver off, then press **Command-Shift-E** (Enter Windows). That's
the only thing Command-Shift-E does: it sends your keyboard back to a
running machine after the escape hatch brought it to the Mac. You never
need it when starting a machine, because starting puts you in Windows on
its own.

### Two rules that follow from this

**The escape hatch only goes one way, and that's on purpose.**
Control-Command-Escape always brings the keyboard back to the Mac. It never
sends it to Windows. Going into Windows is always something you do on
purpose, either by starting a machine or by pressing Enter Windows. AVM
will never hand your keyboard to Windows without you asking.

**Never use Control-Option in a shortcut.** That's VoiceOver's own
modifier, so AVM stays away from it everywhere.

### Two quirks worth knowing in advance

**Command-F5 while your keyboard is in Windows may open the Start menu.**
Windows sees part of the shortcut as a plain tap of the Windows key. If
that happens, press Escape to close Start. This is also why the steps
above turn VoiceOver off *before* the keyboard changes sides.

**The Windows key toggles Start. It doesn't just open it.** If you leave
Windows with the Start menu open, it's still open when you come back, and
your first tap of the Windows key will close Start instead of opening it.
A sighted person would glance at the screen and catch this, but blind
users can't. So if a tap seems to do nothing, it may have actually done
the opposite of what you expected.

---

## 9. Screen readers in Windows

Most people's journey looks the same: use Narrator to get through Windows
setup, because it is built in and needs no download. Then install JAWS or
NVDA once Windows is yours. Both work in AVM. Use whichever screen reader
you use.

### Narrator

Once your keyboard is in Windows, press:

**Control-Command-Return**

On a Mac keyboard, Command acts as the Windows key, so this is Windows'
standard Narrator toggle. Narrator will introduce itself. From that point
Windows speaks for itself and you are using Narrator, not VoiceOver. The
same shortcut turns Narrator back off.

### Windows setup and your account

Windows setup will ask you to sign in with a Microsoft account. In this
build of Windows, that is the supported path. The earlier tricks for
creating an offline local account were removed by Microsoft in this
release, and this guide will not send you down a road that no longer
works. Sign in with a Microsoft account, or create one during setup.

### JAWS and NVDA

**Set your screen reader to laptop layout, unless your keyboard really
has the keys for desktop layout.** Desktop layout leans on the number pad
and the Insert key. MacBook keyboards and most Apple keyboards have
neither, and laptop layout is made for exactly that. If you use a full
PC-style USB keyboard that does have a number pad and an Insert key,
desktop layout should work too. If you are coming from a PC, this is easy
to forget, so please check it before you blame anything else.

### Caps Lock

In Windows, Caps Lock does everything it does on a PC, including acting
as your screen reader's key, whichever screen reader you use. AVM makes
this work by asking macOS to stop handling Caps Lock itself while your
keyboard is in Windows, which macOS otherwise insists on doing. When you
take your keyboard back to the Mac, Caps Lock goes back to normal Mac
behavior.

The change is temporary. It disappears when you leave Windows or quit
AVM. In the unlikely event it ever seems stuck, restarting your Mac
undoes it completely.

On the Mac side, Caps Lock behaves the way it always does on a Mac. With
VoiceOver running, press it twice quickly to toggle caps. With VoiceOver
off, a single press works. macOS also has a built-in short delay on
engaging Caps Lock, so a firm press works better than a quick tap. None
of this is AVM.

---

## 10. Keyboard reference

### AVM's own commands (Mac side)

- **Command-Shift-S** starts the virtual machine. Your keyboard is in
  Windows automatically once the machine's view appears.
- **Command-Shift-E** is Enter Windows. It returns the keyboard to a
  running machine after the escape hatch.
- **Command-Shift-D** sends Control-Alt-Delete to Windows.
- **Command-Shift-R** resets the virtual machine (see section 13).
- **Control-Command-Escape** is the escape hatch. It brings the keyboard
  back to the Mac.
- **Command-F5** turns VoiceOver on and off. This is macOS, not AVM, but
  it is half the routine.

Note on Command-Shift-S: in this build it starts a machine only when you
have exactly one machine configured and nothing is running. With no
machines, or more than one, you get a beep and an explanation instead of a
guess. Use the dashboard's Start button in that case.

### Mac keys inside Windows

- **Command** acts as the **Windows key**.
- **Caps Lock** is your screen reader key. See section 9.
- **Control-Escape** opens Start, a useful alternative route.
- **Function-Delete** is **forward delete**.
- **Shift-Delete** is **permanent delete**. It deletes without going to
  the Recycle Bin.
- **Shift-F10** opens the **context menu** in Windows applications.
- **Control-Command-Return** toggles **Narrator**.
- **Control-Alt-Delete** cannot be typed directly. Use Command-Shift-D
  from the Mac side, which injects it into the virtual hardware.

---

## 11. Connecting devices

- **USB keyboards work now.** Type on whatever keyboard you like. AVM
  forwards keys the same way no matter which keyboard you use.
- **Mice and trackpads work now.** On machines installed with AVM 0.1.1
  or later, the Windows pointer follows your finger exactly and clicks
  land where the pointer is, from the very first boot. Machines
  installed with an earlier AVM need two small pieces of software added
  inside Windows first. That is a one-time job of about ten minutes,
  described at the end of section 14.
- **Headsets and speakers work for listening.** Windows audio plays
  through whatever output your Mac is using.
- **Microphones are unverified, so please test yours.** The plumbing for
  audio input exists but has never been confirmed end to end. If you get
  Windows to hear your microphone, or you can't, either way that's a
  valuable report.
- **Thumb drives and other USB storage do not reach Windows yet.** That
  arrives with the USB passthrough work described in section 15.

---

## 12. Sounds and announcements

AVM speaks in the Mac's system voice and plays three sounds:

- **Glass** means something succeeded.
- **Basso** means something failed.
- **Tink** is a neutral change of state, or guidance. It is not a verdict,
  just information: the keyboard changed sides, or a form needs one more
  field.

The sound always plays immediately. Speech may wait its turn. If two
announcements land within a second of each other, the second one queues
instead of cutting off the first. Failures are the exception. A failure
interrupts whatever is being spoken and discards anything still waiting,
because a stale success announcement after a failure would mislead you.

Announcements you may hear, and what they mean:

- **"Install media ready. Starting the virtual machine."** The media
  build finished, and the VM is booting.
- **"Windows Setup is underway…"** The milestone in section 7.
- **"Windows keyboard on." / "Mac keyboard on."** The keyboard changed
  sides.
- **"Another window took the keyboard. Turn VoiceOver on to check."** See
  section 13.
- **"Keyboard back in Windows."** The window that took the keyboard went
  away. You will usually *not* hear this one, because by then VoiceOver is
  normally back on, and this cue stays quiet while VoiceOver is running.
- **A Basso alarm with recovery guidance** means AVM's watchdog believes
  the virtual machine is stuck during installation. See section 13.

---

## 13. When something seems wrong

### Your keystrokes stop reaching Windows

Some other window on your Mac has taken the keyboard, commonly a dialog
that appeared behind AVM's back. With VoiceOver off, you have no way to
notice it, so AVM tells you:

> Another window took the keyboard. Turn VoiceOver on to check.

What to do:

1. Press **Command-F5** to turn VoiceOver on.
2. Find the window that took the keyboard and deal with it: read it,
   answer it, or close it. It already has your keystrokes, so you can
   type into it directly.
3. Press **Control-Command-Escape** to bring the keyboard back to the
   Mac, and check that nothing else is waiting.
4. Turn VoiceOver off, then enter Windows again with **Command-Shift-E**.
5. One cleanup note: turning VoiceOver on in step 1 may have opened the
   Start menu in Windows. Once you are back in Windows, press Escape to
   close it.

Even if you hear no announcement, apply the same reasoning: **dead keys
are much more likely to be a Mac-side window stealing focus than a crashed
virtual machine.** Check the Mac before assuming the worst.

AVM announces this instead of fixing it, on purpose. It will not fight
another application for your keyboard. A program that fights for your
keyboard is a program you can't escape from.

### One key never reaches Windows, everything else works

The Mac took it. See the general rule at the end of section 4: find the
macOS keyboard shortcut using that key and turn it off.

### Caps Lock stopped working on my Mac

Quit and relaunch AVM, or restart your Mac. Either one fully restores
normal Mac Caps Lock behavior. See section 9 for what AVM does with Caps
Lock and why.

### Frozen, silent, and the fans are roaring

**This is very often Windows working, not Windows dying.** Windows
performs update and repair passes with no video output and no sound at
all. One of those passes during development ran for roughly an hour,
black and silent and pegging the processor the whole time, and then
finished perfectly normally.

So please **do not reset a machine just because it has gone quiet.** Give
a silent stretch up to an hour before you conclude anything. AVM's
watchdog applies the same rule internally. It checks whether the virtual
disk is still being written to, and stays quiet when it is, exactly so
that it never nudges you into interrupting a healthy repair.

If AVM does raise the alarm, it has already established that the disk is
not moving either.

### Windows is silent and does not respond, but the machine seems alive

Windows recovery screens, like Startup Repair and the recovery
environment, have no screen reader at all. Silence there is not a dead
machine. It is a screen you cannot hear. If you suspect you are on one, a
phone camera app that reads text out loud (Seeing AI and similar) pointed
at the screen will tell you what is there. Report what you find. A
machine stranded in recovery is something I want to know about.

### The Windows window looks black but Windows is clearly running

If sound works and Windows responds to keys, but a sighted person would
see a black window, report it. This was a real bug. Windows sometimes
rendered to a display output the window wasn't watching. It was found and
fixed before your build, and it should not happen anymore, which is
exactly why any recurrence is worth hearing about.

### If the virtual machine is completely frozen

Before you force-quit anything, capture the evidence. It only exists
while the freeze is happening. Paste this into Terminal and press Return:

    sample $(pgrep qemu-system) 10 -file ~/Desktop/avm-freeze-sample.txt

It runs for about ten seconds and writes a file called
avm-freeze-sample.txt on your Desktop. Attach it to your report along with
the diagnostic log. If AVM itself is frozen too (no speech, no response to
its own commands), run it a second time with AVM in place of qemu-system.

Then force-quit and report what happened.

### Resetting a virtual machine

**Command-Shift-R** resets the machine. It is the equivalent of the reset
button on a physical PC. A confirmation appears with Cancel as the
default, so Return backs out.

Three things to know:

1. **Reset is a last resort, not a troubleshooting step.** During
   development, a reset issued at an apparently idle desktop is what
   *triggered* the hour-long repair pass described above. Resetting is a
   dice roll even when things look calm.
2. **After a reset, the keyboard does not automatically return to
   Windows.** The focus lock does not survive a guest reboot. Use
   Command-Shift-E again.
3. **Silence after a reset is expected.** See above.

### A known upstream problem

Once in a while a virtual machine can hang at firmware startup after one
of Windows Setup's own restarts. No display, no progress, no sound. This
is a confirmed bug in the underlying virtualization firmware, not in AVM,
and it is not fixed upstream yet. It is uncommon and unpredictable. If you
hit it, Command-Shift-R is the recovery attempt, and please report it.

---

## 14. Starting Windows again after the install

Start the machine as normal. AVM checks whether that machine's Windows
installation already completed. If it has, it boots straight from the
disk. It does not rebuild installation media or reattach the ISO. You do
not have to do anything to make this happen, and you cannot accidentally
reinstall over a working Windows.

Remember the routine each time: turn VoiceOver off, then start. The
keyboard is in Windows automatically.

### Adding mouse support to a machine installed before version 0.1.1

Machines created with AVM 0.1.1 or later get working mouse support
automatically. The installer adds two small pieces of software during
Windows Setup, and there is nothing for you to do. A machine installed
with an earlier AVM is missing those two pieces. Adding them takes about
ten minutes, happens entirely inside Windows with your screen reader, and
is a one-time job. They are the same two pieces, the same versions, that
AVM installs automatically on fresh installs.

One warning before the steps, because it is the one way this goes wrong:
the driver disc you are about to download also contains an installer
called virtio-win-guest-tools. Do not run it. On ARM64 Windows it fails
partway through and rolls itself back, leaving you where you started. The
two-step order below is the path that works.

1. **Download two files in Windows.** In your browser inside Windows,
   download the driver disc image (about 700 MB):
   https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.285-1/virtio-win-0.1.285.iso
   and the agent installer (about 2 MB):
   https://www.spice-space.org/download/windows/vdagent/vdagent-win-0.10.0/spice-vdagent-x64-0.10.0.msi
2. **Mount the disc image.** In your Downloads folder, press Enter on
   virtio-win-0.1.285.iso. Windows mounts it as a DVD drive.
3. **Install the driver first. The order matters.** Open Device Manager
   (press Windows+X, then M). Under "Other devices" you will find a
   device named "PCI Simple Communications Controller" with a warning.
   That is the mouse channel waiting for its driver. Open its context
   menu, choose "Update driver," then "Browse my computer for drivers."
   Browse to the folder vioserial\w11\ARM64 on the mounted DVD drive. So
   if Windows gave the disc the letter D, the full path is
   D:\vioserial\w11\ARM64. Continue, and Windows installs the VirtIO
   serial driver from that folder.
4. **Install the agent.** In Downloads, press Enter on
   spice-vdagent-x64-0.10.0.msi and let it complete. It has no questions
   to ask.
5. **Restart Windows.**

That's the whole job. After the restart, the Windows pointer follows your
Mac trackpad or mouse exactly, and a click lands where the pointer is.
The mounted disc image does not survive the restart, and both downloaded
files can be deleted afterward.

---

## 15. Known limitations, and what's next

- **You can have more than one machine.** The dashboard handles any
  number, and each machine has its own Start button. The limit is only
  in the Command-Shift-S shortcut: it starts a machine only when exactly
  one is configured, because with several it would have to guess which
  one you meant. With more than one machine, use the dashboard's Start
  buttons. A smarter shortcut is planned.
- **Windows edition.** The installer selects a single edition. Choosing
  between Home, Home Single Language and Pro is planned but not exposed
  yet.
- **Out-of-box setup is stock Windows.** AVM does not script your account
  creation. You go through Microsoft's own setup with Narrator.
- **No ISO downloader.** You supply the Windows image yourself.

The next piece of work is USB passthrough, which means connecting USB
devices directly to Windows. The motivating case is audio hardware: audio
interfaces and MIDI controllers reaching Windows recording software. I
can't promise timing or say which devices will work, because that
investigation hasn't happened yet, and I would rather not publish guesses.
But it is next, and you can shape it. When you report, mention the USB
hardware you'd want working in Windows, even if everything else in your
session went perfectly.

---

## 16. The diagnostic log, your privacy, and reporting a problem

### What AVM records, and what it never records

AVM keeps a diagnostic log of what *AVM* did: machines starting and
stopping, install stages completing, the keyboard changing sides, failures
and their reasons. **It never records what you type.** There is no code
path in AVM that captures your keystrokes into any file. Not filtered, not
scrubbed. The code just isn't there. Your Mac user name is replaced with a
tilde wherever a file path would have contained it. You can check both
claims by reading the log yourself. It is plain text, and you are
encouraged to.

One honest exception exists: a diagnostic keyboard mode used during
development, off by default, that can only be switched on deliberately
with a Terminal command. Turning it on announces itself in the log. If you
never run that command, it never runs.

During installation, AVM also samples the guest's screen image, but only
to detect a frozen installer. No image is kept. Each frame is reduced to a
checksum and deleted. A frame is kept only if the watchdog declares a
failure, and the log says so when that happens.

One cosmetic note: if your Mac user name happens to be an ordinary English
word, the privacy scrubber may occasionally replace that word with a tilde
inside unrelated text in the log. That is over-caution, not an error.

### Saving the log

In AVM, choose **File**, then **Save Diagnostic Log**. A standard save
dialog asks where to put it. The result is a plain folder, never an
archive, named "AVM Diagnostic Log" with the date. Inside are AVM's own
recent activity logs and a short firmware startup log for each virtual
machine. Every file is plain text. Read anything you like with VoiceOver
before you send it. The folder exists so you can inspect exactly what you
are sharing.

If there is nothing to save yet, AVM says so: "There is no diagnostic log
to save yet." That is information, not an error.

### Reporting

File issues at:

https://github.com/allisonfm85/accessible-virtual-machine/issues

The most useful report is a plain story of what you heard and when. The
issue form will prompt you for:

- What you were doing, in order.
- **What AVM said, as close to word for word as you can manage.** Just as
  important, **tell me where you expected speech and got silence.** In
  this project, silence is always a bug.
- Whether VoiceOver was on or off at the time.
- Roughly what time it happened, so it can be matched against the log.
- Your Mac model and macOS version.
- The diagnostic log folder, compressed and attached.

Thank you for testing! Every problem you catch now is one that future
users will never have to deal with.
