# AVM Tester Guide

AVM (Accessible Virtual Machine) lets you install and run Windows 11 on your
Mac entirely with VoiceOver — no sighted help at any step. This guide covers
what you need, what you will hear, and what to do when something seems wrong.

This is a tester build. It has been proven end to end on the developer's
hardware, but you are the first people outside that machine. Everything you
notice is worth reporting, especially anything that happens silently.

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
  starts small and grows as Windows uses it — choosing a large disk size
  does not spend that space up front.
- **A Windows 11 ARM64 installation disc image (ISO).** You supply this
  yourself — see section 2.
- **Time and quiet.** Plan on an uninterrupted stretch for your first
  install. Most of the work happens without speech, and you will want to be
  listening.

---

## 2. Getting the Windows 11 ISO

Microsoft distributes Windows 11 disc images from its own download page. You
need the **ARM64** image, not the x64 one. AVM cannot use an x64 image, and
it will tell you so rather than failing quietly.

Downloading the ISO is the one step of the process that happens outside AVM.
The page is usable with a screen reader, but the controls appear in stages —
each one you use reveals the next — so it helps to know what is coming.

### The download page

Go to:

    https://www.microsoft.com/software-download/windows11arm64

Work through it in this order:

1. Find the combo box labelled **Select Download** and choose
   **Windows 11 (multi-edition ISO for Arm64)**. It is the only choice.
2. Activate the **Download Now** button.
3. A new section appears, headed "Select the product language". Find the
   combo box labelled **Choose one** and pick your language — for most
   testers that is **English (United States)**.
4. Activate the **Confirm** button.
5. After a few seconds a link appears reading
   **Download - Windows 11 Arm64 English** (the language will match what you
   chose), followed by a second **Download Now** button. Activate that button
   to start the download.

**A warning about step 5.** At that point there are two buttons on the page
called "Download Now" — the one you already used in step 2, and the real one
at the bottom. If you navigate by button, the first one you land on is the
old one, and activating it again just re-shows the language picker. The one
you want is the last "Download Now" on the page. Navigating to the end of
the page and working backwards is the quickest way to land on it.

### What you should end up with

A single `.iso` file of about eight gigabytes — the English 25H2 image is
7,994,415,104 bytes, so budget more than the "about 5 GB" figure that
circulates in older write-ups.

The build validated during development was:

    Win11_25H2_English_Arm64_v2.iso
    Windows 11, version 25H2, build 26200

At the time of writing, the download page serves this same version. Other
ARM64 images are expected to work. If yours does not, that is exactly the
kind of thing to report.

Note that this is a *multi-edition* image — it contains Home, Pro and the
rest, and the edition is settled during installation rather than by which
file you download. You do not need to hunt for a Pro-specific ISO.

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
walk through the steps again — you will get a fresh link. Nothing is wrong,
and you have not used anything up.

Put the ISO somewhere you can find it again — your Downloads folder is fine.

### If the page gives you trouble

There is a second route. **CrystalFetch** is a free Mac app that builds a
Windows 11 ARM64 ISO for you, from the same Microsoft sources, without the
staged web form. It comes from Turing Software, the people behind UTM, and
lives at:

    https://github.com/TuringSoftware/CrystalFetch

It is a native Mac application rather than a web page, which some testers
may find easier. We have not tested CrystalFetch with VoiceOver yet, so this
is an alternative to try rather than a recommendation — and if you use it,
please report which of the two routes worked better for you. That report
will decide what this section says in the future.

A future version of AVM may fetch and verify the image for you directly, so
that none of this is necessary.

*This section was substantially improved by a detailed walkthrough and
proposed rewrite contributed by Kelly Ford — thank you, Kelly.*

---
## 3. Installing AVM

AVM arrives as a disk image. Open it, place AVM in your Applications
folder, and eject the disk image. Launch AVM the way you launch anything
else.

The first time Windows starts, your Mac will ask whether AVM can find
devices on your local network. This is macOS asking, because Windows needs
a network connection. Choose Allow. If VoiceOver is asleep when it
appears, AVM will announce that another window took the keyboard — wake
VoiceOver, read the dialog, choose Allow, and you'll hear "Keyboard back
in Windows."

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
   right a space." Otherwise the Mac eats Control with the arrow keys —
   which in Windows is how you move word by word through text.
3. **The Show Desktop shortcut: OFF.** In the same Keyboard Shortcuts
   window, under Mission Control, turn off "Show Desktop." Otherwise the
   Mac takes F11, which your Windows screen reader needs.

**The general rule, worth remembering past these three:** if Windows
never reacts to a key, no matter how many times you press it, the Mac
probably took it first. Check System Settings, Keyboard, Keyboard
Shortcuts for a shortcut using that key, and turn it off.

---

## 5. The dashboard

The first thing you meet is the dashboard. With VoiceOver's heading
navigation it reads in this order:

- **AVM** — the app title, a level-one heading.
- **Each virtual machine's name** — a level-two heading. Under each name is a
  plain line of specifications (cores, memory, disk size) and two buttons,
  Start and Delete, each labelled with that machine's name.
- **Status** — a level-three heading, below the machine list, describing what
  AVM is currently doing.

The dashboard also has a **Setup Wizard** button. That is how you create a
new virtual machine — section 6. If you have no machines yet, the list is
empty and that button is your first stop.

**Delete asks first.** Deleting a virtual machine destroys its disk and
everything on it, so AVM puts up a confirmation. Cancel is the default
button — pressing Return backs out safely. You have to deliberately choose
Delete.

Your machines live in your Library folder, under Application Support, in a
folder named AVM. You do not need to go there, but that is where the space
is going.

---

## 6. Creating your first virtual machine

Press the **Setup Wizard** button on the dashboard. When the wizard opens,
your cursor is placed in the name field for you.

The window reads top to bottom:

- **Setup Wizard** — the title, a heading.
- **Virtual machine name** — a text field. Any name you like; the suggested
  example is "My Windows 11".
- **CPU cores** — a stepper, starting at 4. Adjust it with the arrow keys.
  The minimum is 2; the maximum is half the cores your Mac has.
- **Memory** — a stepper, starting at 8 gigabytes, moving in steps of 2.
  The minimum is 4; the maximum is half your Mac's memory.
- **Disk size** — a stepper, starting at 64 gigabytes, moving in steps of
  10. The minimum is 40; the maximum is based on your free disk space,
  always leaving your Mac roughly 20 gigabytes of headroom. Remember: the
  disk file starts small and grows as Windows uses it.
- **Windows installer image** — this reads "No installer selected" until
  you choose one. The **Choose Installer Image** button opens a standard
  file picker; navigate to your ISO and choose it. The wizard then reads
  back the file's name so you know what it took.
- **Cancel** and **Create Virtual Machine**. Escape cancels;
  Command-Return creates. While the machine is being created the button
  reads "Creating virtual machine, please wait" — it takes a moment,
  because AVM builds the machine's disk file right then.

If you press Create before the form is complete, the wizard tells you —
on screen and aloud — what is still needed. That is guidance, not an
error: nothing is broken, the form just isn't finished.

When creation finishes, the wizard closes and you are back on the
dashboard, where the new machine now has its own heading, its
specifications, and its Start and Delete buttons.

---

## 7. The install: what you will hear

Start the machine (section 8 covers the keyboard ritual — read it first).
AVM begins by opening your ISO and reading the list of Windows editions
inside it. If that check fails, you get a spoken explanation of what was
wrong with the file. That is deliberate — a bad ISO caught in seconds is
much kinder than one caught forty minutes into an install.

Then AVM builds custom installation media on your disk and starts the
virtual machine. The build is fast — seconds on a fast Mac.

**First announcement, spoken in the system voice:**

> Install media ready. Starting the virtual machine.

These announcements use the Mac's system voice rather than VoiceOver, on
purpose: you will hear them whether VoiceOver is awake or asleep, and whether
or not AVM is the frontmost app.

**A few minutes later, the milestone announcement:**

> Windows Setup is underway and will restart the virtual machine a few times.
> This takes a while. Windows will not speak on its own. When Setup is done,
> enter Windows and press Control Command Return to turn on Narrator.

Read that last sentence carefully, because it is the part people get wrong:
**Windows does not start talking by itself.** Silence after this point is
normal and expected. It does not mean the install failed. Your Mac's fans may
run hard the whole time — also normal.

**How long is "a while"?** It varies enormously between Macs. On fast
hardware it has been under a minute. On slower machines it can be
considerably longer. Do not treat any particular duration as wrong.

**You may hear a Windows startup sound.** When Setup reaches the setup
screen, the guest sometimes plays Windows' own startup chime. If you hear it,
that is your cue. But it does not play every time — its absence proves
nothing. Either way the procedure is the same: wait, try the Narrator chord.
If nothing happens, leave Windows, wait longer, re-enter, and try again.

---

## 8. The keyboard model: sleeping VoiceOver

This is the most important section in the guide. Read it before your first
install, not after.

**While your keyboard is in Windows, you are a Windows user.** VoiceOver
should be asleep. Two screen readers awake at once fight over the same
keystrokes, and you lose.

### Starting a machine

1. On the AVM dashboard, press **Command-F5** to sleep VoiceOver first, while
   the keyboard still belongs to the Mac.
2. Press **Command-Shift-S** to start the virtual machine, or use the
   machine's Start button.
3. The moment the Windows view appears, your keyboard is in Windows —
   automatically. You will hear the system voice say **"Windows keyboard
   on."** That announcement is audible without VoiceOver — it is how you
   know the handover happened. There is no separate step to take.

From here every keystroke goes to Windows.

### Leaving Windows

1. Press **Control-Command-Escape**. This is the escape hatch.
2. You will hear **"Mac keyboard on."**
3. Press **Command-F5** to wake VoiceOver.

### Going back into Windows

Sleep VoiceOver, then press **Command-Shift-E** (Enter Windows). That is
the only job Command-Shift-E has: returning your keyboard to a running
machine after the escape hatch brought it back to the Mac. You never need
it when starting a machine — starting puts you in Windows by itself.

### Two rules that follow from this

**The escape hatch is one-way by design.** Control-Command-Escape always
takes the keyboard back to the Mac. It never sends it to Windows. Going
the other way is always something you do on purpose — starting a machine,
or pressing Enter Windows. Nothing ever hands your keyboard to Windows
without you asking.

**Never use Control-Option as a shortcut.** That is VoiceOver's own modifier.
AVM deliberately avoids it everywhere.

### Two quirks worth knowing in advance

**Command-F5 while your keyboard is in Windows may open the Start menu.**
Windows sees part of the chord as a bare Windows-key tap. Press Escape to
close Start. This is why the ritual above sleeps VoiceOver *before* the
keyboard changes sides.

**The Windows key toggles Start — it does not just open it.** If you leave
Windows with the Start menu open, nothing closes it while you are away, and
your first Windows-key tap after coming back will *close* Start rather than
open it. Sighted users glance and see this. You cannot. If a tap seems to do
nothing, consider that it may have done the opposite of what you expected
rather than nothing at all.

---

## 9. Screen readers in Windows

Most people's journey looks the same: use Narrator to get through Windows
setup, because it is built in and needs no download — then install JAWS or
NVDA once Windows is yours. Both work in AVM. Use whichever screen reader
you use.

### Narrator

Once your keyboard is in Windows, press:

**Control-Command-Return**

On a Mac keyboard, Command acts as the Windows key, so this is Windows'
standard Narrator toggle. Narrator will introduce itself. From that point
Windows speaks for itself and you are using Narrator, not VoiceOver. The
same chord turns Narrator back off.

### Windows setup and your account

Windows setup will ask you to sign in with a Microsoft account. In this
build of Windows, that is the supported path — earlier tricks for creating
an offline local account were removed by Microsoft in this release, and
this guide will not send you down a road that no longer works. Sign in
with a Microsoft account, or create one during setup.

### JAWS and NVDA

**Set your screen reader to laptop layout.** This is not optional on a
Mac: there is no number pad and no Insert key, so desktop layout's
commands have nowhere to live. A JAWS user arriving from a PC will not
think to switch — switch.

### Caps Lock

In Windows, Caps Lock does everything it does on a PC — including acting
as your screen reader's key, whichever screen reader you use. AVM makes
this work by asking macOS to stop handling Caps Lock itself while your
keyboard is in Windows, which macOS otherwise insists on doing. When you
take your keyboard back to the Mac, Caps Lock goes back to normal Mac
behavior.

The change is temporary. It disappears when you leave Windows or quit
AVM, and in the unlikely event it ever seems stuck, restarting your Mac
undoes it completely.

On the Mac side, Caps Lock behaves as it always does on a Mac: with
VoiceOver running, press it twice quickly to toggle caps; with VoiceOver
off, a single press works. macOS also has a built-in short delay on
engaging Caps Lock — a firm press works better than a quick tap. None of
this is AVM.

---

## 10. Keyboard reference

### AVM's own commands (Mac side)

- **Command-Shift-S** — Start Virtual Machine. Your keyboard is in Windows
  automatically once the machine's view appears.
- **Command-Shift-E** — Enter Windows: return the keyboard to a running
  machine after the escape hatch.
- **Command-Shift-D** — Send Control-Alt-Delete to Windows.
- **Command-Shift-R** — Reset Virtual Machine (see section 13).
- **Control-Command-Escape** — the escape hatch: keyboard back to the Mac.
- **Command-F5** — VoiceOver on and off. This is macOS, not AVM, but it is
  half the ritual.

Note on Command-Shift-S: in this build it starts a machine only when you have
exactly one machine configured and nothing is running. With no machines, or
more than one, you get a beep and an explanation rather than a guess. Use the
dashboard's Start button in that case.

### Mac keys inside Windows

- **Command** acts as the **Windows key**.
- **Caps Lock** is your screen reader key — see section 9.
- **Control-Escape** opens Start — a useful alternative route.
- **Function-Delete** is **forward delete**.
- **Shift-Delete** is **permanent delete** — deletes without going to the
  Recycle Bin.
- **F10** opens the **context menu** in Windows applications.
- **Control-Command-Return** toggles **Narrator**.
- **Control-Alt-Delete** cannot be typed directly — use Command-Shift-D from
  the Mac side, which injects it into the virtual hardware.

---

## 11. Connecting devices

- **USB keyboards work now.** Type on whatever keyboard you like; AVM
  forwards keys the same way regardless of the keyboard.
- **Headsets and speakers work for listening.** Windows audio plays
  through whatever output your Mac is using.
- **Microphones are unverified — please test yours.** The plumbing for
  audio input exists but has never been confirmed end to end. If you get
  Windows to hear your microphone, or fail to, either way that's a
  valuable report.
- **Thumb drives and other USB storage do not reach Windows yet.** That
  arrives with the USB passthrough work described in section 15.

---

## 12. Sounds and announcements

AVM speaks in the Mac's system voice and plays three sounds:

- **Glass** — something succeeded.
- **Basso** — something failed.
- **Tink** — a neutral change of state, or guidance. Not a verdict, just
  information: the keyboard changed sides, or a form needs one more field.

The sound always plays immediately. Speech may wait its turn: if two
announcements land within a second of each other, the second one queues
rather than cutting off the first. Failures are the exception — a failure
interrupts whatever is being spoken and discards anything still waiting,
because a stale success announcement after a failure would mislead you.

Announcements you may hear, and what they mean:

- **"Install media ready. Starting the virtual machine."** — the media
  build finished; the VM is booting.
- **"Windows Setup is underway…"** — the milestone in section 7.
- **"Windows keyboard on." / "Mac keyboard on."** — the keyboard changed
  sides.
- **"Another window took the keyboard. Wake VoiceOver to check."** — see
  section 13.
- **"Keyboard back in Windows."** — the thief went away. You will usually
  *not* hear this one, because by then VoiceOver is normally awake and this
  cue is suppressed while VoiceOver runs.
- **A Basso alarm with recovery guidance** — AVM's watchdog believes the
  virtual machine is stuck during installation. See section 13.

---

## 13. When something seems wrong

### Your keystrokes stop reaching Windows

Some other window on your Mac has taken the keyboard — commonly a dialog that
appeared behind AVM's back. With VoiceOver asleep, you have no way to perceive
it, so AVM tells you:

> Another window took the keyboard. Wake VoiceOver to check.

What to do:

1. Press **Command-F5** to wake VoiceOver.
2. Find and deal with whatever appeared. (If waking VoiceOver opened the Start
   menu in Windows, press Escape.)
3. Press **Control-Command-Escape** to take the keyboard back to the Mac.
4. Resolve whatever it was.
5. Enter Windows again with **Command-Shift-E**.

Even if you hear no announcement, apply the same reasoning: **dead keys are
much more likely to be a Mac-side window stealing focus than a crashed
virtual machine.** Check the Mac before assuming the worst.

AVM announces this rather than fixing it, deliberately. It will not fight
another application for your keyboard — that way lies a program you cannot
escape from.

### One key never reaches Windows, everything else works

The Mac took it. See the general rule at the end of section 4: find the
macOS keyboard shortcut using that key and turn it off.

### Caps Lock stopped working on my Mac

Quit and relaunch AVM, or restart your Mac. Either fully restores normal
Mac Caps Lock behavior. See section 9 for what AVM does with Caps Lock and
why.

### Frozen, silent, and the fans are roaring

**This is very often Windows working, not Windows dying.** Windows performs
update and repair passes with no video output and no sound at all. One such
pass observed during development ran for roughly an hour, black and silent
and pegging the processor the entire time, and then finished perfectly
normally.

So: **do not reset a machine just because it has gone quiet.** Give a silent
stretch up to an hour before you conclude anything. AVM's watchdog applies the
same rule internally — it checks whether the virtual disk is still being
written to, and stays quiet when it is, precisely so that it never nudges you
into interrupting a healthy repair.

If AVM does raise the alarm, it has already established that the disk is not
moving either.

### Windows is silent and does not respond, but the machine seems alive

Windows recovery screens — Startup Repair, the recovery environment — have
no screen reader at all. Silence there is not a dead machine; it is a
screen you cannot hear. If you suspect you are on one, a phone camera app
that reads text aloud (Seeing AI and similar) pointed at the screen will
tell you what is there. Report what you find — a machine stranded in
recovery is something the developer wants to know about.

### The Windows window looks black but Windows is clearly running

If sound works and Windows responds to keys but a sighted person would
see a black window, report it. This was a real bug — Windows sometimes
rendered to a display output the window wasn't watching — and it was
found and fixed before your build. It should not happen anymore, which
is exactly why any recurrence is worth hearing about.

### If the virtual machine is completely frozen

Before you force-quit anything, capture the evidence — it only exists
while the freeze is happening. Paste this into Terminal and press Return:

    sample $(pgrep qemu-system) 10 -file ~/Desktop/avm-freeze-sample.txt

It runs for about ten seconds and writes a file called
avm-freeze-sample.txt on your Desktop. Attach it to your report along with
the diagnostic log. If AVM itself is frozen too (no speech, no response to
its own commands), run it a second time with AVM in place of qemu-system.

Then force-quit and report what happened.

### Resetting a virtual machine

**Command-Shift-R** resets the machine — the equivalent of the reset button on
a physical PC. A confirmation appears with Cancel as the default, so Return
backs out.

Three things to know:

1. **Reset is a last resort, not a troubleshooting step.** During development,
   a reset issued at an apparently idle desktop is what *triggered* the
   hour-long repair pass described above. Resetting is a dice roll even when
   things look calm.
2. **After a reset, the keyboard does not automatically return to Windows.**
   The focus lock does not survive a guest reboot. Use Command-Shift-E again.
3. **Silence after a reset is expected.** See above.

### A known upstream problem

Occasionally a virtual machine can hang at firmware startup after one of
Windows Setup's own restarts — no display, no progress, no sound. This is a
confirmed bug in the underlying virtualization firmware, not in AVM, and it
is not fixed upstream yet. It is uncommon and unpredictable. If you hit it,
Command-Shift-R is the recovery attempt, and please report it.

---

## 14. Starting Windows again after the install

Start the machine as normal. AVM checks whether that machine's Windows
installation already completed, and if it has, it boots straight from the
disk — it does not rebuild installation media or reattach the ISO. You do not
have to do anything to make this happen, and you cannot accidentally
reinstall over a working Windows.

Remember the ritual each time: sleep VoiceOver, then start — the keyboard
is in Windows automatically.

---

## 15. Known limitations, and what's next

- **One machine at a time from the menu.** Command-Shift-S only acts when
  exactly one machine is configured. Multi-machine handling is a later piece
  of work.
- **Windows edition.** The installer selects a single edition. Choosing
  between Home, Home Single Language and Pro is planned but not exposed yet.
- **Out-of-box setup is stock Windows.** AVM does not script your account
  creation; you go through Microsoft's own setup with Narrator.
- **No ISO downloader.** You supply the Windows image yourself.

The next piece of work is USB passthrough — connecting USB devices
directly to Windows. The motivating case is audio hardware: audio
interfaces and MIDI controllers reaching Windows recording software. No
promises about timing or about which devices will work — that
investigation hasn't happened yet, and this project doesn't publish
guesses. But it is next, and you can shape it: when you report, mention
the USB hardware you'd want working in Windows, even if everything else
in your session went perfectly.

---

## 16. The diagnostic log, your privacy, and reporting a problem

### What AVM records, and what it never records

AVM keeps a diagnostic log of what *AVM* did: machines starting and
stopping, install stages completing, the keyboard changing sides, failures
and their reasons. **It never records what you type.** There is no code
path in AVM that captures your keystrokes into any file — not filtered,
not scrubbed: absent. Your Mac user name is replaced with a tilde wherever
a file path would have contained it. Both claims are checkable by reading
the log yourself — it is plain text, and you are encouraged to.

One honest exception exists: a diagnostic keyboard mode used during
development, off by default, that can only be switched on deliberately
with a Terminal command — and doing so announces itself in the log. If you
never run that command, it never runs.

During installation, AVM also samples the guest's screen image solely to
detect a frozen installer. No image is kept — each frame is reduced to a
checksum and deleted. A frame is retained only if the watchdog declares a
failure, and the log says so when that happens.

One cosmetic note: if your Mac user name happens to be an ordinary English
word, the privacy scrubber may occasionally replace that word with a tilde
inside unrelated text in the log. That is over-caution, not an error.

### Saving the log

In AVM, choose **File**, then **Save Diagnostic Log**. A standard save
dialog asks where to put it; the result is a plain folder — never an
archive — named "AVM Diagnostic Log" with the date. Inside are AVM's own
recent activity logs and a short firmware startup log for each virtual
machine. Every file is plain text. Read anything you like with VoiceOver
before you send it — the folder exists so you can inspect exactly what
you are sharing.

If there is nothing to save yet, AVM says so: "There is no diagnostic log
to save yet." That is information, not an error.

### Reporting

File issues at:

https://github.com/allisonfm85/accessible-virtual-machine/issues

The most useful report is a plain narrative of what you heard and when.
The issue form will prompt you for:

- What you were doing, in order.
- **What AVM said, as close to word for word as you can manage** — and just
  as important, **where you expected speech and got silence.** Silence is a
  bug in this project, not an absence of one.
- Whether VoiceOver was awake or asleep at the time.
- Roughly what time it happened, so it can be matched against the log.
- Your Mac model and macOS version.
- The diagnostic log folder, compressed and attached.

Thank you for testing. Every silent failure you catch is one a future user
never meets.
