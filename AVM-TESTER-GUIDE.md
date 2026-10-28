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

- **Accessible Virtual Machine** is the app title, a level-one heading.
- **Each virtual machine's name** is a level-two heading. Under each name is
  a plain line of specifications (cores, memory, disk size) and its
  buttons, each labeled with that machine's name: Start, Settings, Export
  and Delete while it's shut down. While it runs, the row says how it is
  ("Running", "Running, keyboard in Windows", "Paused", "Shutting down")
  and has **Enter** and **Shut Down** instead. macOS machines' rows also
  say **"Saved"** when the machine was saved with Save and Quit (section
  17).
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

**Export and Import: backing a machine up, or moving it.** Shut the
machine down, then press its **Export** button, or choose **Export Virtual
Machine…** in the Virtual Machine menu (with several machines it is a
submenu of their names). Pick a folder or an external drive; AVM saves
the machine there as one folder named after it, ending in **.avmvm**. AVM
says how big the copy is when it starts, how far along it is every 10
percent for anything over 2 gigabytes, and when it has finished. To bring
it back, on this Mac or another, choose **Import Virtual Machine…** in
the same menu, or the button of that name on the dashboard, and pick the
.avmvm folder. The machine comes back as a new entry in your list, so
importing next to the original, or twice, is safe; if the name is taken,
AVM adds a number and says so.

Things to know:

- AVM refuses, and says why, if the machine is running, if a macOS machine
  is **saved** rather than shut down (start it and shut it down from
  macOS first), if Windows or Linux hasn't finished installing (start it
  once, let it reach the desktop, shut it down), or if the drive doesn't
  have room. It checks the space before it copies anything.
- No passwords travel. The Windows account password AVM kept for setup,
  and the Ubuntu or Debian password, are left out.
- On an external drive formatted **ExFAT** or **MS-DOS (FAT)**, a disk
  takes its full size, even the parts Windows or macOS haven't used, so
  the copy can be much bigger than the machine is on your Mac. A drive
  formatted **APFS** or **Mac OS Extended** keeps it small.
- For a macOS machine with restore points, AVM asks whether to include
  them: on another drive each one is a full copy of the disk.
- An imported macOS machine is the same Mac to macOS as the original.
  AVM says so if the original is on this Mac too: run only one of them at
  a time.
- While the copy runs, that machine's Start, Settings and Delete say to
  wait. Quitting AVM asks first.

Your machines live in your Library folder, under Application Support, in a
folder named AVM, unless you chose another folder or drive for one in the
Setup Wizard. You do not need to go there, but that is where the space
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
- **Where to Store It** is a heading, followed by where the machine will
  live: "On this Mac" unless you change it. **Choose a Folder or Drive**
  opens a folder picker, so you can keep the machine on an external drive
  instead. AVM makes a folder called "AVM Virtual Machines" there. The
  dashboard then says which drive each machine is on, and, if that drive
  isn't connected, says so; Start and Delete refuse, out loud, until you
  connect it. During installation AVM still needs about 8 gigabytes free
  on your Mac for a short while, to build the install disc.
- **Windows installer image** reads "No installer selected" until you
  choose one. The **Choose Installer Image** button opens a standard file
  picker. Navigate to your ISO and choose it. The wizard then reads back
  the file's name so you know what it took.
- **Download Windows 11 for ARM** opens a window that opens Microsoft's
  download page in your browser. You still choose the download on
  Microsoft's page (section 2 walks through it), and AVM watches your
  Downloads folder: it says how the download is going every gigabyte,
  checks the file when it's done, and **Use This Installer** picks it for
  you. **Speak Progress**, Command-P, says how far it has got at any time.
- **Windows Edition** appears once you've chosen a Windows ISO: Pro, Home,
  or Home Single Language, in a pop-up button. VoiceOver says "Windows
  edition, Windows 11 Pro, pop-up button": press VoiceOver-Space to open
  it, then choose the edition your Windows license is for. Pro is chosen
  to start with.
- **Screen Readers**: checkboxes for NVDA (checked to start with) and
  JAWS for ARM. AVM downloads them from their makers and installs them
  with Windows. With NVDA checked, **NVDA uses its laptop keyboard
  layout** is checked too: on a Mac keyboard, NVDA's key is then Caps
  Lock.
- **Windows Setup Answers**: what Windows Setup won't ask you, because
  AVM writes it into this machine's answer file. Each one is filled in
  from your Mac; choose **Let Windows ask** on any of them to answer it in
  Windows instead.
  - **Region**, **Keyboard** and **Time zone** are pop-up menus. Type a
    few letters to jump to a choice.
  - **Computer name** is a text field. Leave it empty to use the name
    shown, made from the machine's name.
  - **Privacy**: a pop-up button with the most private choice (the
    default) or Windows' recommended settings.
  - **Windows account**: a pop-up button. **Microsoft account** means you
    sign in during setup, as before. **Local account on this PC** asks
    for your name, a user name and a password (it can be empty), and
    Windows then skips its sign-in screens and signs in by itself the
    first time, so NVDA installs and starts with nothing for you to do.
    You can add a Microsoft account later in Windows' Settings.
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

> Install media ready. Windows Setup is starting, and it runs by itself:
> about 20 to 40 minutes, with a few restarts. Windows doesn't speak while
> it installs, so long silences are normal. AVM will tell you how it's
> going every 10 minutes.

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

**Every 10 minutes AVM says how it's going**, for example "Windows is
still installing, 20 minutes so far." With a Microsoft account, Windows
stops at its sign-in pages and waits for you, so once Setup is underway
those updates also say to enter Windows and turn on Narrator to hear
where it is. When Windows reaches its first sign-in, AVM says "Windows is
installed and signed in," and then either that NVDA is talking, or how
to turn on Narrator.

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
   **"Entering Windows"**, after two rising notes. You'll hear it even
   with VoiceOver off — that's how you know the handover happened.

From here, every keystroke goes to Windows.

### Leaving Windows

1. Press **Control-Command-Escape**. This is the escape hatch.
2. You will hear two falling notes and **"Entering Mac."**
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

Narrator gets you through Windows setup, because it is built in. When
you make the machine, AVM can also install NVDA, JAWS for ARM, or both,
so one of them is talking when you first sign in. NVDA is on by default.
JAWS needs your own license; without one it runs for 40 minutes at a
time. If you choose both, NVDA starts at sign-in, and you can start JAWS
yourself. You can also install either one yourself later. Use whichever
screen reader you use.

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
- **Command-Shift-I** is Speak Status. AVM says which machine is
  running, paused, or stopped, whether your keyboard is on the Mac or in
  Windows, and which USB devices are attached. It speaks in the system
  voice, so it works with VoiceOver off.
- **Command-Shift-D** sends Control-Alt-Delete to Windows.
- **Command-Shift-R** resets the virtual machine (see section 13).
- **Control-Command-Escape** is the escape hatch. It brings the keyboard
  back to the Mac.
- **Command-F5** turns VoiceOver on and off. This is macOS, not AVM, but
  it is half the routine.

Commands that can't do anything right now are dimmed in the Virtual
Machine menu, and VoiceOver reads them as "dimmed": Enter Windows when
nothing is running, Send Control-Alt-Delete and Reset when Windows isn't
running, Detach USB Device when nothing is attached. Pressing a dimmed
command's keys only beeps. Speak Status is never dimmed, so it can always
tell you why. While Windows is installing, Speak Status also says how
long Setup has been running and how much it has written to the disk so
far.

**Copying and pasting.** Copy on the Mac, enter Windows, and paste. What
you copy in Windows is ready to paste on the Mac at once. Each machine's
Settings has a Share the clipboard switch to turn this off.

**Force Stop asks first,** with Cancel as the default, wherever you find
it, because it turns Windows off at once. It is also offered while Windows
is shutting down, in case Windows stops answering.

**Quitting with Windows running.** If you quit AVM, or close its window,
while Windows is running, AVM asks first. Cancel is the default, so Return keeps you where
you are. **Shut Down Windows and Quit** shuts Windows down properly and
quits AVM when it has finished; you can keep using AVM meanwhile. **Quit
Now** turns Windows off at once, like pulling the plug. Either way, any
USB devices go back to your Mac first.

Note on Command-Shift-S: in this build it starts a machine only when you
have exactly one machine configured and nothing is running. With no
machines, or more than one, you get a beep and an explanation instead of a
guess. With more than one machine, the Virtual Machine menu has a Start
submenu that lists each machine by name; choose the one you want. The
dashboard's Start buttons work too.

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
- **A keyboard for Windows.** In a Windows machine's Settings, Keyboard for
  Windows, you can choose a second keyboard, USB or Bluetooth, that types
  only into Windows while it runs, whichever app is in front. Your Mac's
  own keyboard stays with the Mac and VoiceOver, so there's nothing to
  switch. AVM never takes the Mac's built-in keyboard or its only one,
  and gives the keyboard back if your Mac's other keyboard goes away.
  Pause works, and on an Apple keyboard, Fn with Backspace, the arrows or
  Return gives Delete, Page Up and Down, Home, End and keypad Enter, as on
  a Mac. For an Apple keyboard with a § key, turn on "It's an Apple
  keyboard with a § key (ISO)", so § and ` come out where they're
  printed.
- **Mice and trackpads work now.** On machines installed with AVM 0.1.1
  or later, the Windows pointer follows your finger exactly and clicks
  land where the pointer is, from the very first boot. Machines
  installed with an earlier AVM need two small pieces of software added
  inside Windows first. That is a one-time job of about ten minutes,
  described at the end of section 14.
- **Headsets and speakers work for listening.** Windows audio plays
  through whatever output your Mac is using.
- **Other USB devices can go straight to Windows.** When you plug one in
  while Windows is running, AVM sends it or asks first, depending on your
  USB Devices setting. Braille displays and USB microphones work this way.
  The README's USB devices section explains the choices.
- **The first time a device goes to Windows, AVM sets up its USB helper.**
  macOS may ask you to allow it, or it may not. If it asks, the request
  reads fine with VoiceOver. If you aren't an administrator on your Mac,
  allowing it may need an administrator's name and password.
- **Your Mac's own microphone and camera can reach Windows.** Turn each
  on in the machine's Settings, under Microphone and Camera; they take
  effect at the next Start. Each is only on while an app in Windows uses
  it, and AVM says when the camera turns on and off. In Windows the
  camera is called Mac Camera. macOS asks once for permission for each.
- **Thumb drives and other USB storage don't reach Windows yet.** macOS 27
  blocks it, and I'm working with Apple on a fix. AVM tells you when you
  plug one in.

---

### Sharing a folder

To open a Mac folder in Windows, open the machine's Settings and choose
Choose Folder to Share. The next time Windows starts, the folder is a
network drive in File Explorer. Turn on the read-only option if Windows
should only read it.

### When the Mac sleeps

If the Mac sleeps with Windows running, AVM pauses Windows first and
resumes it when the Mac wakes, and tells you. Give Windows' clock a
minute to catch up.

## 12. Sounds and announcements

AVM speaks in the Mac's system voice and plays these sounds:

- **Glass** means something succeeded.
- **Basso** means something failed.
- **Tink** is a neutral change of state, or guidance. It is not a verdict,
  just information: a form needs one more field, say.
- **Two rising notes** mean the keyboard just went to a virtual machine.
- **Two falling notes** mean it just came back to the Mac. These two are
  AVM's own, so you can tell where the keyboard is even while a screen
  reader is talking over the words.

The sound always plays immediately. Speech may wait its turn. If two
announcements land within a second of each other, the second one queues
instead of cutting off the first. Failures are the exception. A failure
interrupts whatever is being spoken and discards anything still waiting,
because a stale success announcement after a failure would mislead you.

Announcements you may hear, and what they mean:

- **"Install media ready. Windows Setup is starting…"** The media
  build finished, and the VM is booting.
- **"Windows Setup is underway…"** The milestone in section 7.
- **"Windows is still installing, 20 minutes so far."** Said every 10
  minutes until Windows is installed, so a silent install never sounds
  like a stuck one.
- **"Windows is installed and signed in."** Windows reached its first
  sign-in.
- **"Entering Windows" / "Entering Mac"** (or the name of the machine's
  system: "Entering Ubuntu", "Entering macOS"). The keyboard changed
  sides; the rising or falling notes say which way.
- **"Another window took the keyboard. Turn VoiceOver on to check."** See
  section 13.
- **"Keyboard back in Windows."** The window that took the keyboard went
  away. You will usually *not* hear this one, because by then VoiceOver is
  normally back on, and this cue stays quiet while VoiceOver is running.
- **A Basso alarm with recovery guidance** means AVM's watchdog believes
  the virtual machine is stuck during installation. See section 13.

---

### If speech lags behind your keys

Turn on Shorter speech delay in the machine's Settings, then start the
machine again. It keeps less sound waiting on the Mac. It is
experimental: if the sound crackles, turn it off, and please tell us.

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

### Secure Boot and Insider builds

Machines made with this version have Secure Boot, with Microsoft's keys,
which Windows needs before it offers Insider preview builds. For a machine
made earlier, stop it, open its Settings, turn on **Secure Boot**, and
choose Save Settings. AVM asks first, because it resets the machine's
firmware settings, keeping a copy. Windows normally starts again on its
own. If BitLocker or device encryption is on in Windows, it may ask for
your recovery key, so have it ready. Turning Secure Boot off again puts
the old settings back. If Windows doesn't start after the switch, turn
Secure Boot off and report it, with a diagnostic log.

### Restore points

Before something risky, such as a big update or Insider builds, shut the
machine down, open its Settings, and choose **Save a Restore Point**. Give
it a name you'll recognize. If things go wrong, shut down again and
choose **Restore** beside it. AVM asks first, with Cancel as the default,
because everything since that restore point is lost. The disk, the
firmware settings and the TPM all go back together, so BitLocker and
Windows Hello keep working. A restore point made with Secure Boot on can
only be restored with Secure Boot on, and the other way round; AVM says
so if they differ.

AVM saves a restore point called **Fresh install** by itself, the first
time you start a machine after Windows is set up. Restoring it gives you a
brand-new Windows in a minute or two.

AVM also saves an **Automatic** restore point by itself, at most once a
week, as the machine starts, and keeps the two newest; your own restore
points are never touched. If a Windows update breaks something, a
screen reader most often, the automatic point from before it is at most a
week old. (Restore points need Windows shut down, and Windows installs
updates while it runs and as it shuts down, so AVM can't take one at the
exact moment before an update. A point taken at Start is always from
before the updates installed after it.)

To start over completely, choose **Reinstall Windows…** in Settings while
the machine is shut down. AVM asks first (it erases everything in Windows
on that machine), asks for the Windows password again if you chose a
local account, and installs Windows again from the same installer the
next time you choose Start.

### Telling us about a problem

Choose **Report a Problem…** from the Help menu. AVM copies a short report
to the clipboard (your AVM, macOS and Mac versions, and the end of the
diagnostic log, which never has your user name or anything you typed) and
opens a new GitHub issue. Write what happened, paste the report with
Command-V, and submit. Nothing is sent until you do.

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
  one you meant. With more than one machine, use the Start submenu in
  the Virtual Machine menu, which names each machine, or the dashboard's
  Start buttons.
- **Out-of-box setup is stock Windows.** AVM does not script your account
  creation. You go through Microsoft's own setup with Narrator.
- **The ISO download is still yours to start.** AVM opens Microsoft's
  page and does everything around it, but Microsoft's page itself is
  where you choose the download.

USB passthrough is here, except for USB drives. New machines now have
Secure Boot, and existing ones can turn it on in Settings (see section
13). Next is the rest of the firmware work: stopping Windows Update from
blocking updates over the TPM and processor checks (issues 16 and 17).
After that comes graphics
acceleration. If a USB device you need doesn't work in Windows, please
report it, with its name and a diagnostic log.

---

## 16. Ubuntu instead of Windows

AVM can also install **Ubuntu Desktop for ARM**, version 26.04 LTS or later.
26.04 is the version this has been tested with. Everything
else in this guide (the dashboard, the keyboard model, Caps Lock,
Control-Command-Escape, the announcements) works the same way. Where
the guide says "Windows", the app says "Ubuntu" for an Ubuntu machine:
**Enter Ubuntu**, **Stop Ubuntu**, "Ubuntu keyboard on".

### Getting the Ubuntu ISO

Download **Ubuntu Desktop for ARM** from ubuntu.com. The file is named
like `ubuntu-26.04.1-desktop-arm64.iso` and is about 4 GB. Two other
Ubuntu downloads look similar and will not work: the version for Intel
and AMD PCs (its name ends in `amd64.iso`), and Ubuntu Server. If you
choose either, AVM tells you which one you picked and which one it
needs.

### Creating the machine

In the Setup Wizard, choose the Ubuntu ISO as the installer image. AVM
reads it and says:

> Ubuntu 26.04.1 LTS desktop installer selected. Fill in the Ubuntu
> account below.

An **Ubuntu Account** section then appears below the installer, because
Ubuntu installs with no questions and needs your account up front:

- **Your name**, filled in from your Mac account. It is shown at the
  Ubuntu login screen.
- **User name**, filled in from your Mac's short user name. Lower-case
  letters, digits, hyphens and underscores, starting with a letter.
- **Password** and **Confirm password.** You will use it to sign in and
  to make changes to Ubuntu.
- **Sign in automatically**, on to begin with. Ubuntu then starts
  straight to the desktop with no password prompt.

AVM never stores the password itself. It keeps only a scrambled form
(the hash Ubuntu's installer asks for), first in the machine's own
folder and then inside the install media it builds, and it deletes the
install media once Ubuntu is installed.

### The install: what you will hear

Start the machine. AVM builds the install media in a few seconds, then
says:

> Install media ready. Ubuntu is installing now, with no questions. This
> takes about 15 to 40 minutes, and Ubuntu doesn't speak until it's done,
> so long silences are normal. AVM will tell you how it's going every 10
> minutes, and when Ubuntu is installed.

Silence between those updates is expected. The installer runs with no screen reader,
because there is nothing to answer. When it finishes, the virtual machine
turns itself off, and AVM says:

> Ubuntu is installed. Starting it now. Orca will speak when the desktop
> is ready, in about a minute. Orca's key is Caps Lock.

AVM then starts the machine again by itself, and Orca, Ubuntu's screen
reader, speaks at the login screen or, with Sign in automatically, on
the desktop.

If the install fails, the machine turns off and AVM says so:

> Ubuntu's install stopped with an error, and the virtual machine turned
> off. Next: press Start to try the install again. If it stops again,
> report it with the diagnostic log.

### Orca

- **Orca is on from the start**, at the login screen and after.
- **Orca's key is Caps Lock.** AVM sets Orca's laptop layout, whose Orca
  key is Caps Lock, because a Mac keyboard has no Insert key. AVM hands
  Caps Lock to Ubuntu the same way it does for Windows (section 9).
- Press **Caps Lock and H** for Orca's learn mode, and Escape to leave it.

### What AVM sets up in Ubuntu

- No screen lock and no automatic suspend. A locked or sleeping machine
  is silent, and silence reads as broken.
- No first-run welcome screens or welcome tour, and no crash-report
  prompts.
- AVM's small UNATTEND disk, which stays attached to the machine, is
  hidden from the desktop, so it doesn't show up as a USB drive.
- Your Mac's time zone, US English, and a US keyboard layout.
- The SPICE guest agent, for the mouse.
- Ubuntu's sound tuned for AVM: the same sample rate as AVM's audio and a
  larger buffer, which removed crackling in Orca's speech.

### Known limitations for Ubuntu

- **ARM desktop images only**, Ubuntu 26.04 or later.
- **English and a US keyboard only** for now.
- **A larger disk is not used automatically.** After you make the disk
  larger in Settings, Ubuntu's main partition has to be made larger too.
- **Stop** shuts Ubuntu down normally, which has taken about 15 seconds.
- **One of the first seven test installs stalled** early in the installer's
  start-up, before anything was written to the disk. Stopping and
  starting the machine again ran the install normally. AVM watches for
  this: if nothing changes for 15 minutes, it says:

  > Ubuntu's install seems to have stopped. Nothing has changed for 15
  > minutes. Next: save the diagnostic log from the File menu, then stop
  > the virtual machine and start it again.

  Save the log while the machine is still running (section 18): for
  Ubuntu, the machine's startup log records the installer's own start-up
  messages, and the next start replaces it. Then please report it.

### Fedora Workstation

AVM can install **Fedora Workstation** the same way, Fedora 44 or later:
the same account section (titled **Fedora Account**), the same
announcements with "Fedora" in place of "Ubuntu", Orca on at the login
screen and after with Caps Lock as its key, and everything listed under
What AVM sets up in Ubuntu. Fedora 44 is the version this has been
tested with, so far with AVM's unattended install test only: it
installed and signed in to the desktop by itself, but Orca's speech has
not yet been listened to in the app. Please report what you hear.

**Getting the Fedora ISO.** On fedoraproject.org, go to Fedora
Everything (under Other downloads, or Fedora's alternative downloads),
choose **aarch64**, and download the **Netinstall ISO**. The file is
named like `Fedora-Everything-netinst-aarch64-44-1.7.iso` and is about
1.2 GB. Two other downloads look similar and will not work: the
Workstation live image (its name has `Live` in it) and the version for
Intel and AMD PCs (`x86_64`). If you choose either, AVM tells you which
one you picked and which one it needs. The Fedora Server netinstall for
aarch64 also works.

**The install downloads Fedora.** The netinstall disc holds only the
installer; the Workstation desktop, about 2 GB, comes from Fedora's
mirrors with that day's updates. The Mac needs a working internet
connection, and AVM says the install takes about 20 to 60 minutes.

**How Fedora differs from Ubuntu:**

- Your account can make changes with your password (it is in Fedora's
  wheel group, Fedora's administrators); the root account is locked.
- Fedora's welcome tour is not installed, and its first-run screens are
  skipped.
- SELinux stays on, as Fedora ships it.
- A larger disk is not used automatically, as for Ubuntu.

---

## 17. macOS instead of Windows

AVM can run macOS too, on Apple's own virtualization. Choose **New macOS
Virtual Machine…** on the dashboard. AVM downloads the newest macOS your
Mac supports from Apple (about 26 GB, kept for the next one), or uses an
installer file (IPSW) you have, and installs it in a few minutes, saying
how far it has got.

### The keyboard

A macOS machine opens in its own window, with a bar VoiceOver can read
above the machine's screen: where the keyboard is, **Give macOS the
Keyboard**, **Turn On VoiceOver in macOS**, and **Shut Down**.

- **Command-Shift-E** (Virtual Machine > Enter macOS) gives macOS the
  keyboard; you hear the rising notes and "Entering macOS".
- **Control-Command-Escape** gives it back to the Mac.
- Command-Tab and Command-F5 stay your Mac's.

**Your Mac's VoiceOver and macOS's.** With both on, they fight over your
keys. When you enter macOS with your Mac's VoiceOver on, AVM asks you to
press Command-F5 to turn it off; AVM can't do that for you (macOS starts
VoiceOver again by itself if a program stops it). When you return to the
Mac, AVM turns your Mac's VoiceOver back on by itself, and if AVM ever
quits unexpectedly while you're in macOS, it turns it back on the next
time it opens.

### Turning on VoiceOver inside macOS

Command-F5 is your Mac's, so to start macOS's own VoiceOver, use **Turn On
VoiceOver in macOS** on the bar, or **Command-Option-Shift-V**. AVM asks
you to press Command-F5 and sends that one to macOS. For those few
seconds every key goes to macOS, so Control-Command-Escape waits until
AVM says Command-F5 is your Mac's again, within 10 seconds. A new
machine's first start does this by itself, about three minutes in, when
Setup Assistant is up. macOS keeps VoiceOver on afterwards.

### Saving, restore points and the clipboard

- **Save and Quit / Save and Close.** Quitting AVM, or closing the
  machine's window, offers to save the machine as it is, open apps and
  all. Its next Start carries on from there in seconds instead of a
  three-minute start.
- **Restore points.** In a macOS machine's Settings, with it shut down:
  **Take Restore Point**, then **Restore** or **Delete** beside each one.
  They are instant and use space only for what changes afterwards. Every
  new machine has a **Fresh install** point.
- **Copy and paste.** With Share the clipboard on in its Settings (it is
  by default), text copied on the Mac can be pasted in macOS and the other
  way round. Once, in macOS: open Finder, Locations, My Shared Files, AVM
  Clipboard, and open **Install Clipboard Sharing**. It says when it's
  on. Text only, for now.
- **Shared folder.** A folder shared in Settings appears in macOS's Finder
  under Locations, My Shared Files.

---

## 18. The diagnostic log, your privacy, and reporting a problem

### What AVM records, and what it never records

AVM keeps a diagnostic log of what *AVM* did: machines starting and
stopping, install stages completing, the keyboard changing sides, failures
and their reasons. **It never records what you type.** There is no code
path in AVM that captures your keystrokes into any file. Not filtered, not
scrubbed. The code just isn't there. Your Mac user name is replaced with a
tilde wherever a file path would have contained it. You can check both
claims by reading the log yourself. It is plain text, and you are
encouraged to.

A diagnostic keyboard mode exists for development, but only in developer
builds of AVM. In the build you are testing it does not exist at all, and
no setting or command can turn it on.

During installation, AVM also samples the guest's screen image, but only
to detect a frozen installer. Each sample replaces the previous one in the
machine's folder, and the last one is deleted when the watching ends. No
sample goes into the diagnostic log.

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
