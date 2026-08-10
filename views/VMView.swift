// VMView.swift
// AVM — Accessible Virtual Machine
//
// Displays the SPICE output from QEMU using CocoaSpice and Metal, and
// captures keyboard input, forwarding it to the Windows guest via CSInput.
//
// AUTO-LOCK MODEL:
//   When this view appears (i.e. the VM has reached running/paused and
//   SessionGate switches to it), focus lock engages AUTOMATICALLY. The moment
//   Windows is running, the keyboard goes to Windows — no separate "enter"
//   step. Control-Command-Escape (owned by FocusLockManager's global Carbon
//   hotkey) is the way back to the Mac. Cmd-Shift-E (Enter Windows) exists
//   ONLY for RE-ENTERING Windows after the user has returned to the Mac — it
//   is never a step that follows starting the VM on its own. (Recorded
//   2026-08-03 after the run-17 protocol briefly described it as a
//   freestanding sequence step; tester docs must state the model this way.)
//   The on-screen "Return to Mac" and "Force Stop" controls in the overlay
//   are VoiceOver-reachable and do NOT depend on the hotkey, so the user can
//   always get out.
//
// AUTHORITATIVE ROUTING (2026-07-19): while locked, FocusLockManager defends
//   first responder for SPICEKeyCaptureView (KVO on the window's
//   firstResponder — see the manager's header for the full model). This view
//   participates by REGISTERING itself in viewDidMoveToWindow. VO-cursor
//   navigation over the overlay no longer moves keyboard focus off the guest;
//   overlay buttons remain activatable via VO-Space (accessibility press
//   action — bypasses the responder chain).
//
// Focus-lock ownership:
//   - The Control-Command-Escape escape hatch is owned SOLELY by
//     FocusLockManager's global Carbon hotkey (registerHotKey -> toggle).
//   - This view's keyboard handling does exactly one thing: while locked,
//     forward keys to the Windows guest via CSInput.
//   - On any unlock, the coordinator observes focusLock.isLocked going
//     true->false and queues a guest-key flush (releaseKeys) on the SPICE
//     context so no modifier is left stuck-down.
//
// THREAD/CONTEXT RULE (the unlock-freeze fix, 2026-07-11, PROVEN by sample
// 2026-07-12):
//   NOTHING on the main thread may wait on CocoaSpice's GLib worker — not
//   direct calls (CSDisplay add/removeRenderer, CSInput releaseKeys/send),
//   and not object DEALLOCS. The hang sample of freeze #3 caught the exact
//   chain: dismantleNSView -> disconnect() -> `connection = nil` ->
//   -[CSConnection dealloc] -> -[CSMain syncWith:] (CSConnection.m:404) ->
//   dispatch_group_wait, blocked forever. The worker could not answer
//   because it was DEADLOCKED inside GStreamer's osxaudiosink teardown
//   (playback_stop -> AudioOutputUnitStop -> CoreAudio HALB_Mutex) against
//   CoreAudio's IO thread (gst_core_audio_remove_render_callback ->
//   recursive_mutex) — a CocoaSpice/GStreamer audio bug, triggered when the
//   guest stops its audio stream (observed at OOBE's PIN screen; the
//   "channel->thread_id != pthread_self" QEMU warnings are the same
//   subsystem). That upstream wedge is a SEPARATE issue; the rule here is
//   that a wedged worker must never capture the main thread.
//   Therefore: the unlock observer, disconnect(), and spiceDisplayDestroyed()
//   CAPTURE strong references on the main thread and QUEUE all CocoaSpice
//   work — INCLUDING the connection's final release, so its dealloc's
//   internal syncWith: runs on the SPICE context — onto CSMain.shared.async.
//   If the worker is wedged the block never runs and the objects leak until
//   app exit; that is the correct trade for a live main thread (VoiceOver,
//   overlay buttons, and QMP-based Stop all keep working).
//   NOTE: the hot typing path (handleKey / handleFlagsChanged) still sends on
//   the main thread deliberately — it is exercised on every keystroke of every
//   session without incident and is outside the audit's findings.
//   If a freeze recurs: `sample <AVM pid> 5 -file ~/Desktop/avm_hang_sample.txt`
//   WHILE frozen, BEFORE force-quitting.
//
// STUCK-KEY HANDLING (the Narrator-toggle fix):
//   macOS does NOT deliver keyUp to a view while Command is held — the Command
//   key "eats" the keyUp. So a chord like Win+Ctrl+Enter (Ctrl+Cmd+Return)
//   forwards Return's PRESS but never its RELEASE, leaving Return stuck-down in
//   the guest. After that, all navigation is polluted and the toggle misfires.
//   Command combos also route through performKeyEquivalent, which has no "up"
//   counterpart at all. To fix both, the coordinator TRACKS every held
//   non-modifier scancode and force-releases any still held whenever the
//   modifier set changes (i.e. the chord is being released). This guarantees no
//   non-modifier key is left stuck after a Command chord, without relying on a
//   keyUp that AppKit may never deliver.
//
// Keyboard model while locked (full Windows immersion):
//   - Every key, INCLUDING Control-Option, is forwarded to Windows so the
//     guest screen reader receives unmolested modifier combos.
//   - Caps Lock is a SPECIAL CASE — see the next block.
//
// CAPS LOCK / THE F19 COURIER (2026-07-26):
//   macOS handles Caps Lock down in the HID driver: it flips the lock state
//   and the LED itself, and hands the application only a flagsChanged
//   notification describing the RESULTING STATE — never a press followed by a
//   release. A HELD Caps Lock therefore cannot be expressed at all. The legacy
//   fallback in handleFlagsChanged synthesizes an instantaneous press+release
//   on each toggle, which can deliver a TAP and can never deliver a HOLD.
//
//   That is fatal for guest screen readers. JAWS and NVDA in LAPTOP LAYOUT use
//   Caps Lock as their modifier key, and Narrator's DEFAULT modifier is "Caps
//   lock or Insert" — so this breaks all three, including the one AVM itself
//   documents. No Mac keyboard has an Insert key and a MacBook has no numeric
//   keypad, so there is no fallback modifier available to a Mac user.
//
//   LIVE-PROVEN 2026-07-25 (Notepad, JAWS laptop layout): Caps Lock+T typed a
//   bare "t"; a lone Caps Lock appeared to do nothing (JAWS consuming a bare
//   modifier); a DOUBLE-TAP worked and JAWS announced caps on. The double-tap
//   works precisely because it is built only out of taps — it is not evidence
//   that anything is healthy. Meanwhile the HOST's caps state kept toggling
//   underneath, because the driver had already acted before any event existed.
//
//   THE FIX: a hidutil UserKeyMapping remaps Caps Lock to F19 at the DRIVER
//   level. macOS then stops treating the key as a lock key and delivers
//   ordinary keyDown/keyUp with real duration, and this file translates F19 to
//   CAPS LOCK'S OWN SCANCODE (0x3A) so the GUEST receives a genuine, held Caps
//   Lock. F19 is a COURIER ONLY: the user never presses it and the guest never
//   sees it. F19 was chosen because no Mac keyboard has one, macOS assigns it
//   no meaning, and it has no press-and-hold accent menu to intercept the hold
//   (proven the hard way — the accent palette appearing on a remapped 'z' was
//   in fact the first evidence that hold duration had been restored).
//   Side benefit: while the mapping is active, the host's caps state can no
//   longer drift while the user is working in Windows — a silent hazard for a
//   user with VoiceOver asleep.
//
//   REJECTED ALTERNATIVE: latch the guest's Caps Lock DOWN on toggle-on and
//   release it on toggle-off. Requires no remap and no system-wide change, but
//   it changes the interaction model to tap/type/tap-again (which is not how
//   JAWS or NVDA behave on real hardware), breaks double-tap pass-through, and
//   leaves the host caps leak unfixed.
//
//   WHO APPLIES THE REMAP (updated 2026-07-26 evening — Stage 2 SHIPPED):
//   This file owns the TRANSLATION only (kVK_F19 -> 0x3A, below). The remap
//   itself is applied and restored automatically by CapsLockRemapper, driven
//   from FocusLockManager's lock/unlock lifecycle, from the app delegate's
//   terminate hook, and by launch recovery after a crash. It merges with (and
//   restores) any pre-existing UserKeyMapping the user has of their own.
//   Nothing here needs to be applied by hand any more.
//     Escape hatch, if a mapping is ever stranded:
//     hidutil property --set '{"UserKeyMapping":[]}'
//   (An earlier version of this header described Stage 2 as "not yet written"
//   and told the reader to apply the mapping by hand in Terminal. That was
//   true when written and became false the day Stage 2 shipped. Same failure
//   mode as the four false claims catalogued in Handoff 18 §1: a description
//   of INTENT surviving into a moment where it reads as a statement of FACT.)
//
//   AUTO-REPEAT SUPPRESSION (2026-07-26, MEASURED — see handleKey):
//   Because the courier arrives as an ordinary function key, macOS applies
//   normal typematic repeat to it. Suppressed for F19 only. The measurement
//   and the reasoning are recorded at the guard itself rather than here.
//
//   The legacy flagsChanged synthesis below is DELIBERATELY RETAINED: with no
//   mapping applied, behavior is exactly what it was before this change.
//
// DETERMINISTIC DISPLAY BINDING (2026-08-03, Handoff 25 queue item 1 — THE
// BLACK-WINDOW FIX):
//   THE MECHANISM, finally proven (runs 8/9/10 + CocoaSpice source read):
//   the guest exposes two display heads by design (ramfb + virtio-gpu-pci —
//   required as a PAIR; the run-phase single-device matrix is COMPLETE and
//   both single-device cells are FALSIFIED, Handoff 25 §3 — do not reopen).
//   The virtio-gpu-pci head is the 800x600 head that firmware and Windows
//   actually draw through (driverless Windows renders Basic Display against
//   the firmware EFI framebuffer). The ramfb head NEVER initializes: it
//   receives ONE OR TWO blank 640x480 fills at attach (the "exactly one"
//   signature from the twelve-generation proof was refined by run 17, which
//   observed two on one generation; "at most a couple, at attach only" is the
//   accurate statement), then holds texture=set, vertices=set, isVisible=1
//   forever while receiving zero further fills — a convincing impostor to
//   every gate the renderer checks.
//
//   In the pinned CocoaSpice fork, CSDisplay.isPrimaryDisplay is literally
//   `monitorID == 0`, and monitorID is assigned as the SPICE CHANNEL-ID —
//   i.e. "primary" is QEMU's enumeration order and NOTHING ELSE. Enumeration
//   is unstable across launches (slot inversion observed live: mon=0
//   carrying slot=1). The old policy here — "channel 0 always wins the slot"
//   — therefore bound the renderer to the impostor on some launches and the
//   live head on others. That coin flip IS the stochastic black window
//   (black runs 5/7 vs lit run 8). The transfer machinery below was always
//   correct; it faithfully delivered the renderer to whatever QEMU happened
//   to call channel 0.
//
//   THE POLICY NOW: the primaryDisplay slot belongs to the display with the
//   LARGEST displaySize area, evaluated at every spiceDisplayCreated AND
//   spiceDisplayUpdated. Strictly larger takes the slot (renderer transfers,
//   same detach-then-attach machinery); ties keep the incumbent; an empty
//   slot takes any display. Enumeration order and the isPrimaryDisplay flag
//   play NO role in binding any more.
//
//   PROVEN: six consecutive clean runs (11–16), twelve display generations,
//   zero wrong binds (Handoff 26). Run 17 (nudge removal confirmation) added
//   a thirteenth-through-fifteenth generation, including the first live
//   observation of the mode-set-resize path: monitor 0 created at 640x480,
//   DECLINED against the incumbent, then WON the slot when its update
//   arrived at 800x600 — the exact scenario the spiceDisplayUpdated
//   evaluation was built for, previously designed-for but never observed.
//
//   WHY SIZE IS A VALID KEY (and its honest limits): Handoff 25 §4 sanctions
//   two discriminators — ongoing fills, and the GOP resolution. Fill
//   liveness is not exposed by CocoaSpice's public API (the FILL stream is
//   fork-internal NSLog), so this fix keys on size: the impostor never
//   initializes and holds its 640x480 attach size; the live head carries the
//   GOP's 800x600, and a driverless guest on an EFI framebuffer cannot
//   change resolution. Re-evaluating on spiceDisplayUpdated covers the case
//   where the live head is still small at creation and grows at mode-set —
//   verified in the fork source: CSConnection connects its monitors handler
//   with g_signal_connect_after, so CSDisplay's own size update runs FIRST
//   and displaySize is already current at every delegate callback. STATED
//   ASSUMPTION, recorded per the head-identity rule (Handoff 25 §6 #3): size
//   is a PROXY for liveness, deterministic in the observed world; if a
//   future configuration lets the impostor report an area >= the live head,
//   this policy needs the fill-liveness fork change instead (Handoff 25
//   queue — the held-in-reserve Option 2). The proof protocol verified the
//   proxy against ground truth in every generation: the slot holder's
//   pointer was always the pointer carrying the ongoing FILL stream.
//
//   DESTROY SIDE, changed to match: the destroy path is now IDENTITY-ONLY.
//   Only the display that IS the current slot holder detaches the renderer
//   and clears the slot; any other display's destroy leaves the slot alone
//   and logs the event. The old `guard isPrimaryDisplay` pre-check is GONE —
//   under the new policy the holder can be any monitor ID, and that guard
//   would have early-returned past the detach, leaving a stale holder (the
//   exact cycle-2 anomaly class the 2026-07-29 identity guard was built to
//   catch). A non-holder display's destroy is now a NORMAL lifecycle event
//   (the impostor dies at every generation teardown), so the log line for it
//   is informational, not an anomaly flag.
//
// SINGLE-ATTACHMENT RULE (2026-07-29, evidence in Handoff 21; policy portion
// SUPERSEDED 2026-08-03 — see DETERMINISTIC DISPLAY BINDING above):
//   The INVARIANT here remains fully in force: a renderer is attached to at
//   most ONE display at all times, and winning the primaryDisplay slot
//   TRANSFERS the renderer — detach from the previous holder (queued on the
//   SPICE context, same rule as all CocoaSpice ops) before attaching to the
//   winner. What is superseded is the SELECTION policy that decided who wins
//   the slot: it was "isPrimaryDisplay (channel 0) always wins, nil fallback
//   otherwise", and is now largest-displaySize (above). The historical
//   record: the old code let the first-arriving head win via the nil
//   fallback, registered the renderer with it, then registered the SAME
//   renderer with channel 0 when it arrived — one CSMetalRenderer attached
//   to two displays, never detached from the dead head. Screenshot evidence
//   (first ever taken of the window, 2026-07-29): solid black while
//   draw(in:) ran at 60fps with a valid drawable.
//   DESTROY-SIDE GUARD (2026-07-29, Handoff 21 §4 cycle-2 anomaly): only the
//   display that CURRENTLY HOLDS the primaryDisplay slot may clear it on
//   destroy. (2026-07-29 evening: a stale destroy was caught LIVE by the
//   guard's log line — hypothesis confirmed; the guard is load-bearing. It
//   survives, strengthened, as the identity-only destroy path above.)
//
// DISPLAY INVESTIGATION STATE (2026-07-31, Handoff 24; RESOLVED 2026-08-03,
// Handoff 25 — kept for the record):
//   The investigation this section coordinated is CLOSED with a mechanism:
//   wrong-head binding, documented in DETERMINISTIC DISPLAY BINDING above.
//   For the archaeology: the ATTACH NUDGE theory ("initial full-frame push
//   fires while vertices are nil") was FALSIFIED by run 7 (2026-07-31,
//   seven-marker instrument, 2094 [AVM-EV] lines): at a screenshot-verified
//   BLACK window, `drawRegion FILL ... renderers=1 rect=800x600` had already
//   COMPLETED on the actively-filling display, a renderer WAS attached, and
//   there was NOT ONE `BAIL` anywhere in the log. Across seven instrumented
//   runs the CocoaSpice fork's two hunks fired ZERO times. The isVisible-
//   snapshot hypothesis that followed is likewise retired: run 8's ~260 gate
//   readings (all isVisible=1) plus runs 9/10's head identification showed
//   the gates were ALWAYS green — on both heads — and the discriminator was
//   WHICH head held the renderer, not any gate state. The "second display
//   generation" mystery is also resolved: it is host-side lifecycle (Enter
//   Windows recreates the SPICE view/connection), proven in run 9.
//   THE NUDGE BLOCK ITSELF WAS REMOVED 2026-08-03 (Handoff 26 queue item 1),
//   after the twelve-generation binding proof, as its own single-variable
//   change, and run 17 confirmed no regression: three generations, all
//   bindings correct, window lit, fill-stream ground truth intact. Initial
//   delivery rides solely on addRenderer's own rebuild-and-push — the path
//   that carried every lit window across all instrumented runs.
//
//   INSTRUMENT TEARDOWN (2026-08-03, Handoff 26 queue item 2, after run 17):
//   the DEBUG machinery the investigation built — the draw-gate heartbeat,
//   the canvas probe (which captured guest screen content to disk; its
//   removal is a PRIVACY item, decision of record 2026-07-29), the display
//   roster both shared, and the logging MTKView wrapper (the MTKView's
//   delegate is now the CSMetalRenderer directly again) — was REMOVED. What
//   SURVIVES, permanently: avmPublicLog and the binding/lifecycle
//   announcement stream (see the next section header). Field diagnosis of
//   any future display issue keys on: the binding decision lines, the
//   display created/destroyed lines, the renderer transfer lines, and the
//   fork's FILL stream (while the fork pin retains its markers), plus
//   screencapture for window state. STAGE C (2026-08-03, later the same
//   day): the one piece of scaffolding the teardown deliberately left —
//   the pre-binding-work DEBUG NSLog in spiceDisplayUpdated — was removed
//   under its banked Stage C disposition; see the note at that callback.
//
//   NOTE ON WHY THERE IS NO "which display is the renderer drawing" LOG: there
//   cannot be one. CSMetalRenderer stores a _CSRendererSourceData, a
//   field-by-field SNAPSHOT COPY (texture, vertices, isVisible, offset) taken
//   at blit time; the source's identity is erased at snapshot, and the
//   CSRenderer protocol exposes no source property. The binding announcement
//   stream is the available substitute: it names the display AVM attached
//   the renderer to.
//
// VIEWPORT SCALING (2026-08-07, issue #3 — the "extremely small display"
// fix):
//   FIELD REPORT (Zach Bennoui, issue #3, first post-release feedback): the
//   guest picture occupies a small fraction of the AVM window — bad for
//   sighted testers and equally bad for blind users' OCR and AI image
//   description workflows.
//   ROOT CAUSE, MEASURED (2026-08-07): the driverless guest draws at the
//   firmware framebuffer's 800x600 (confirmed in-guest: empty Display device
//   class; .NET Screen bounds 800x600), and CSMetalRenderer's DEFAULT
//   viewportScale of 1.0 blits those pixels ONE-TO-ONE into the Retina
//   drawable (measured 1800x1264 for a 900x632-point window). The image
//   lands at 400x300 points — under a fifth of the window area.
//   THE FIX: aspect-fit. scale = min(drawableWidth/guestWidth,
//   drawableHeight/guestHeight), applied to the renderer whenever geometry
//   can change: at every binding decision that touches the slot
//   (considerForPrimarySlot win/empty/holder paths), and at view
//   frame/backing changes (SPICEKeyCaptureView overrides below).
//   viewportOrigin stays (0,0): the fork builds display vertices CENTERED
//   (quad spans ±width/2 — read in CSDisplay.m rebuildDisplayVertices,
//   2026-08-07), so origin zero already means centered in the drawable and
//   aspect-fit needs no origin arithmetic.
//   THREADING: renderer.viewportScale is set on the APPLE MAIN THREAD only.
//   The guest size is CAPTURED BY VALUE on the SPICE context — where the
//   binding code already reads displaySize — and passed into the main hop;
//   no new cross-context property reads. lastAppliedGuestSize is
//   MAIN-THREAD-ONLY state, so view-geometry changes can recompute without
//   touching CSDisplay at all.
//   Every scale application is announced via avmPublicLog — it is a
//   configuration choice, and it joins the binding-decision evidence stream.
//   NOTE FOR ISSUE #4 (pointer input — BUILT 2026-08-08, see MOUSE INPUT
//   below): the mouse path's view->guest coordinate conversion derives from
//   the SAME formula as this transform — Self.aspectFitScale, the shared
//   single source of truth — so render and input cannot drift apart and
//   clicks land where the picture shows them. Grep anchor:
//   applyViewportScale.
//
// MOUSE INPUT (2026-08-08, issue #4 — field-reported by Zach Bennoui):
//   Not a bug fix: AVM had NO pointer path at all (audited 2026-08-07 — zero
//   mouse handlers, zero position sends anywhere in this file). Built this
//   session.
//   THE MODEL: absolute positioning. VMManager already attaches usb-tablet
//   (the guest's absolute pointing device — its args, ~line 1332), and
//   spiceInputAvailable has always requested client (absolute) mode via
//   requestMouseMode(false) — the two halves the fork's sendMousePosition
//   documentation requires. Events: SPICEKeyCaptureView forwards
//   move/drag/button/scroll to the coordinator exactly as it forwards keys;
//   an NSTrackingArea (.mouseMoved, .activeInKeyWindow, .inVisibleRect)
//   supplies mouseMoved, and .inVisibleRect keeps its rect current across
//   resizes without manual bookkeeping.
//   COORDINATES, one source of truth: viewPointToGuestPoint converts
//   locationInWindow -> view -> backing pixels, flips Y (this view is an
//   UNFLIPPED NSView — bottom-left origin — while the guest is top-left),
//   subtracts the centering offset (drawable − guest×scale)/2 per axis —
//   which is exactly the geometric meaning of the fork's centered quad at
//   viewportOrigin zero — and divides by Self.aspectFitScale, the SAME
//   formula the render transform uses. The result is clamped to guest
//   bounds so edge events never send out-of-range coordinates.
//   GATING: identical to keys — pointer events forward only while LOCKED.
//   Gated BUTTON events log like gated keys; gated or unconvertible MOVES
//   are deliberately silent (they arrive hundreds of times a second — the
//   same sanctioned-silence class as the F19 repeat suppression, and for
//   the same reason: volume without meaning).
//   BUTTONS: pressedMouseButtons (MAIN-THREAD-ONLY, like pressedScancodes)
//   mirrors the guest's held-button state. The position is sent BEFORE the
//   button event so the click lands where the pointer is. Held buttons are
//   flushed on unlock and on teardown exactly like stuck keys — an
//   interrupted drag must not strand a held button in the guest.
//   SCROLL: DISCRETE SPICE TICKS for both device classes. The fork's
//   Up/Down cases are proven (source read 2026-08-08): each is a
//   press+release of SPICE buttons 4/5 — the wire protocol's only scroll
//   vocabulary. Mouse wheels (hasPreciseScrollingDeltas == false) deliver
//   line-unit deltas; trackpads deliver point-unit deltas plus momentum
//   events. One accumulator, kept in point units at 10 points per tick;
//   wheel line deltas are converted to point units on entry so both device
//   classes share it and residue on device switch is sub-tick.
//   scrollingDeltaY already carries the user's natural-scrolling
//   preference, so the direction the user configured is the direction the
//   guest gets (positive delta = scroll up = SPICE button UP).
//   (kCSInputScrollSmooth was deliberately NOT used: its implementation
//   body was not captured in the source read — the capture window ended
//   before it — and the discrete path produces equivalent wire traffic.
//   Evidence over assumption.)
//   SILENCE IS A BUG, the pointer edition: if the SPICE server refuses the
//   absolute-mode request, serverModeCursor stays true and every position
//   send is silently ignored — invisible by construction. So the state is
//   CHECKED at every button press and a refusal is announced via
//   avmPublicLog exactly once per transition (and the recovery announced
//   likewise).
//   MODE RETRY (2026-08-08, probe run 1): the first field probe caught the
//   silent-refusal state LIVE — guest tablet enumerated and healthy
//   (VID 0627 PID 0001, HID mouse Status OK, verified in-guest), our
//   client-mode request transmitted (fork source verified: spiceMain is
//   back-filled for either channel-arrival order, so the request did not
//   hit the nil early-return), yet the server still reported SERVER mode
//   13 s into a freshly rebuilt Enter-Windows connection. The one-shot
//   request at spiceInputAvailable fires within ~20 ms of the channel
//   appearing — early enough to lose to negotiation timing on a young
//   connection, and nothing ever asked again. THE FIX:
//   warnIfRelativeCursorMode RE-REQUESTS client mode every time it detects
//   server mode at a button press. Self-healing for any transient cause,
//   idempotent, costs nothing in the healthy state (the request only fires
//   while the mode is wrong), and the once-per-transition announcements
//   narrate the recovery. Known limit: the click that triggers a recovery
//   may itself land nowhere (its position was discarded before the grant);
//   acceptable, and a tester-doc note if it survives field testing.
//
// THE REDACTION TRAP (2026-07-31, cost: one full evening — READ THIS)
//   Swift's NSLog("...\(x)...") compiles the interpolated result into a SINGLE
//   %@ object argument, and the unified log redacts %@ as <private>. So EVERY
//   NSLog in this file — all of them, for the whole life of this project —
//   lands in `log show` as:
//       AVM: (Foundation) <private>
//   ObjC's NSLog(@"literal %p %d", ptr, n) does NOT redact, because the format
//   is a literal and the arguments are scalars. THAT is why the CocoaSpice
//   fork's [AVM-EV] markers were readable in runs 5–7 while AVM's own lines
//   never were. It is a property of the CALL, not of the machine, not of the
//   launch path, and not of the build.
//
//   The trap is that a grep for a Swift log line returns ZERO — which reads
//   exactly like "the code never ran." An entire evening was spent concluding,
//   four separate times and wrongly, that the heartbeat was absent, that no
//   displays existed, that SPICE had never connected, and that the build was
//   stale. All four were redaction.
//
//   `sudo log config --mode private_data:on` DOES NOT WORK — removed in
//   Catalina; a configuration profile is the only system-wide route, and
//   Apple's own DTS advises against enabling it on a production Mac.
//
//   THE FIX USED HERE: avmPublicLog() below, which emits via os_log with the
//   %{public}@ specifier — the one form that survives redaction. Any log line
//   that must be READABLE FROM `log show` has to go through it. Plain NSLog is
//   fine for lines only ever read from Xcode's console (which shows them
//   unredacted) and is deliberately left in place everywhere else.
//
//   STANDING RULE EARNED: before drawing ANY conclusion from a grep count of
//   zero, grep for something KNOWN to be present. A zero from an instrument
//   with no positive control is not evidence of absence.
import SwiftUI
import Combine
import MetalKit
import Carbon.HIToolbox
import os
import CocoaSpiceNoUsb

// MARK: - Redaction-proof public logging (PERMANENT — promoted 2026-08-03)

/// PERMANENT INSTRUMENT, not debug scaffolding. Promoted from "remove before
/// ship" status during the Handoff 26 queue item 2 teardown: the display
/// binding decisions and display lifecycle events announced through this
/// helper are configuration-choice announcements (the standing principle:
/// every configuration choice must be announced in a readable log), and they
/// are the field-diagnosis stream for any future display issue. They cannot
/// be promoted to the FILE log instead, because this file must stay 100%
/// file-logger-free (Handoff 19 §6 — the mechanical privacy check greps this
/// file for the file logger's name and must return nothing). The unified log
/// via %{public}@ is the correct sink: readable from `log show`, no file I/O
/// from this file, trivial volume (display events only — a handful per
/// generation). The file-log side of the announcement principle is satisfied
/// by VMManager's display-configuration file-log line.
///
/// The subsystem/category are arbitrary but stable; `log show --predicate
/// 'process == "AVM"'` picks these up exactly as it does NSLog lines. The
/// value of os_log here is solely the %{public}@ specifier — see THE
/// REDACTION TRAP in the file header.
///
/// PRIVACY BOUNDARY, unchanged and load-bearing: under NO circumstances may
/// a key-naming line be routed through this helper. Key identities stay on
/// plain NSLog behind the KeyEventLogging gate.
private let avmPublicLogHandle = OSLog(subsystem: "com.alllisonmeloy.AVM", category: "instrument")

/// Emit a log line that is READABLE FROM `log show` rather than redacted to
/// <private>. The "AVM: " prefix is preserved so existing greps keep working.
@inline(__always)
private func avmPublicLog(_ message: String) {
    os_log("%{public}@", log: avmPublicLogHandle, type: .default, "AVM: " + message)
}

// MARK: - Key Event Logging Gate (Stage B, 2026-07-26)
/// PRIVACY: AVM must not be CAPABLE of capturing what users type (Handoff 19
/// §6). The FILE log achieves that by ABSENCE — no code path from a keystroke
/// to the log file exists in this file, and none may ever be added. (The file
/// logger's name is deliberately not written anywhere in this file, even in
/// comments: Handoff 19 §6's mechanical check greps this file for that name
/// and must return nothing.) But the `vk=` NSLogs in this file land in the
/// UNIFIED log, where `log show` recovers every character typed in the guest
/// — including passwords. This gate closes that: every NSLog that names a key
/// runs ONLY when the flag below is set, so a build with defaults untouched
/// logs no key identities ANYWHERE.
///
/// NOTE (2026-07-31, THE REDACTION TRAP): the key-naming lines are Swift
/// NSLogs, so in practice they land as <private> in `log show` anyway. That is
/// an ACCIDENT OF THE CALL, NOT A PRIVACY CONTROL, and must never be treated
/// as one — they are fully visible in Xcode's console, and a configuration
/// profile would unredact them system-wide. The gate below remains the actual
/// control. Under NO circumstances should a key-naming line be routed through
/// avmPublicLog().
///
/// To enable for a diagnostic session (Terminal, then RELAUNCH AVM):
///   defaults write com.alllisonmeloy.AVM AVMKeyEventLogging -bool YES
/// To return to the default-off state:
///   defaults delete com.alllisonmeloy.AVM AVMKeyEventLogging
/// (The bundle ID really has three L's — deliberate; do not "fix" it.)
///
/// SNAPSHOT SEMANTICS, deliberate: `isEnabled` is a `static let`, evaluated
/// exactly once on first access and frozen for the life of the launch. A
/// whole launch is either logging key identities or it isn't — never a mix
/// mid-session — and the hot typing path pays for a Bool read per keystroke,
/// not a UserDefaults lookup. Toggling therefore requires a relaunch; for a
/// diagnostic flag, that determinism is a feature. VMView.onAppear touches
/// this so the snapshot (and the ENABLED self-declaration below) land before
/// focus lock engages — i.e. before any keystroke can be forwarded.
///
/// SELF-DECLARATION: when the flag is ON, one line is logged so a captured
/// unified log states its own provenance — no ambiguity later about whether a
/// given capture ran with the flag set. When OFF, nothing is logged about the
/// flag at all: absence, again.
enum KeyEventLogging {
    static let isEnabled: Bool = {
        let on = UserDefaults.standard.bool(forKey: "AVMKeyEventLogging")
        if on {
            NSLog("AVM: key event logging is ENABLED for this session (AVMKeyEventLogging is set). Key identities will appear in the unified log until the flag is removed and AVM is relaunched.")
        }
        return on
    }()
}

// MARK: - SwiftUI Entry Point
struct VMView: View {
    let session: VMSession
    @EnvironmentObject var focusLock: FocusLockManager

    var body: some View {
        ZStack {
            SPICEDisplayView(spiceSocketPath: session.spiceSocketPath,
                             focusLock: focusLock)
                .ignoresSafeArea()
            VStack {
                Spacer()
                accessibilityOverlay
            }
            .padding(24)
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            // Stage B: freeze the key-event-logging snapshot (and emit its
            // ENABLED self-declaration, when on) BEFORE the lock engages —
            // i.e. before any keystroke can reach the guest. See
            // KeyEventLogging above.
            _ = KeyEventLogging.isEnabled
            // Auto-lock: the VM is running and this view is on screen, so engage
            // focus lock now and send the keyboard straight to Windows.
            // PUBLIC: this line is a lifecycle landmark used to tell "the view
            // never appeared" apart from "the view appeared and something else
            // failed" — a distinction that cost an evening on 2026-07-31.
            avmPublicLog("VMView onAppear — auto-locking focus.")
            focusLock.lock()
        }
        .onDisappear {
            // Safety: if the VM view goes away while still locked (e.g. the VM
            // stopped), make sure we don't leave the Mac in a locked state.
            if focusLock.isLocked {
                NSLog("AVM: VMView onDisappear — unlocking focus (view went away while locked).")
                focusLock.unlock()
            }
        }
    }

    private var accessibilityOverlay: some View {
        VStack(spacing: 12) {
            Text("Windows is running. Press Control Command Escape to return to Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityLabel("Windows is running. Press Control Command Escape to return to Mac.")
            HStack(spacing: 16) {
                Button("Return to Mac") {
                    focusLock.unlock()
                }
                .keyboardShortcut(.escape, modifiers: [.control, .command])
                .accessibilityHint("Unlocks focus and returns keyboard control to macOS")
                Button("Stop Windows") {
                    Task {
                        do { try await session.stop() }
                        catch {}
                        focusLock.unlock()
                    }
                }
                .accessibilityHint("Shuts down the Windows virtual machine")
                Button("Force Stop") {
                    session.forceStop()
                    focusLock.unlock()
                }
                .accessibilityHint("Immediately kills the virtual machine. Use only if Stop is unresponsive.")
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .cornerRadius(12)
    }
}

// MARK: - NSViewRepresentable
struct SPICEDisplayView: NSViewRepresentable {
    let spiceSocketPath: String
    let focusLock: FocusLockManager

    func makeCoordinator() -> SPICECoordinator {
        SPICECoordinator(focusLock: focusLock)
    }

    func makeNSView(context: Context) -> SPICEKeyCaptureView {
        let mtkView = SPICEKeyCaptureView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.framebufferOnly = false
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.coordinator = context.coordinator
        context.coordinator.attach(mtkView: mtkView, socketPath: spiceSocketPath)
        return mtkView
    }

    func updateNSView(_ nsView: SPICEKeyCaptureView, context: Context) {}

    static func dismantleNSView(_ nsView: SPICEKeyCaptureView, coordinator: SPICECoordinator) {
        coordinator.disconnect()
    }
}

// MARK: - Key- and mouse-capturing MTKView
/// An MTKView that becomes first responder and forwards keyboard AND mouse
/// events to the SPICE guest via the coordinator. The coordinator owns the
/// CSInput channel and the focus-lock gate. The Control-Command-Escape escape
/// hatch is NOT handled here — FocusLockManager's global Carbon hotkey owns
/// it. While locked, FocusLockManager DEFENDS this view's first-responder
/// status (registration happens in viewDidMoveToWindow below).
final class SPICEKeyCaptureView: MTKView {
    weak var coordinator: SPICECoordinator?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSLog("AVM: focus — viewDidMoveToWindow, window=\(window != nil ? "present" : "nil")")
        // AUTHORITATIVE ROUTING: register with the focus-lock manager the
        // moment view+window are valid. Repeat registrations are safe (window
        // changes re-register). If auto-lock already fired, the manager starts
        // enforcement from here.
        if window != nil {
            FocusLockManager.shared?.registerCaptureView(self)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else {
                NSLog("AVM: focus — deferred makeFirstResponder skipped (no window).")
                return
            }
            let ok = window.makeFirstResponder(self)
            NSLog("AVM: focus — deferred makeFirstResponder returned \(ok); isFirstResponder=\(self.window?.firstResponder === self)")
        }
    }

    // VIEWPORT SCALING (issue #3 — see the file header section): view
    // geometry changes must recompute the renderer's aspect-fit scale. Frame
    // resizes and backing-scale changes (window moved to a different-density
    // screen) both change drawableSize; MTKView resizes its drawable
    // automatically (autoResizeDrawable defaults true), and the coordinator's
    // recompute hops through the main queue precisely so that automatic
    // resize has settled before drawableSize is read.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        coordinator?.viewGeometryChanged()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        coordinator?.viewGeometryChanged()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        NSLog("AVM: focus — becomeFirstResponder -> \(ok)")
        return ok
    }

    override func resignFirstResponder() -> Bool {
        NSLog("AVM: focus — resignFirstResponder (losing focus).")
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Stage B: keyCode is key identity — same information as the vk= line
        // — so this is gated. See KeyEventLogging at the top of the file.
        if KeyEventLogging.isEnabled {
            NSLog("AVM: focus — keyDown received, keyCode=\(event.keyCode), locked=\(coordinator?.isLocked ?? false)")
        }
        // Do NOT call super — that would beep/forward to the responder chain.
        coordinator?.handleKey(event: event, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        coordinator?.handleKey(event: event, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        coordinator?.handleFlagsChanged(event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let coordinator, coordinator.isLocked else { return false }
        // Command combos (e.g. Ctrl+Cmd+Return for Narrator) are delivered here,
        // NOT to keyDown — and AppKit never delivers a matching keyUp while
        // Command is held. We forward the press; the stuck-key flush in
        // handleFlagsChanged releases it when the chord's modifiers come up.
        coordinator.handleKey(event: event, pressed: true)
        return true
    }

    // MARK: Mouse input (issue #4 — see MOUSE INPUT in the file header)

    /// mouseMoved is only delivered inside a tracking area — established
    /// here. .inVisibleRect keeps the tracked rect current across resizes
    /// with no manual bookkeeping; .activeInKeyWindow matches the focus
    /// model (pointer events are only meaningful while this window is key
    /// and the lock is engaged — the coordinator's gate is still the
    /// authority). Old areas owned by this view are removed first so window
    /// moves and resizes never accumulate duplicates.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self,
                                       userInfo: nil))
    }

    // Trackpads and mice deliver identical NSEvents for movement, drags, and
    // buttons — the device distinction only exists in scrollWheel (handled in
    // the coordinator via hasPreciseScrollingDeltas). Drag variants forward
    // to the same move handler: a drag IS a move with a button held, and the
    // coordinator's pressedMouseButtons carries the button state.
    override func mouseMoved(with event: NSEvent) {
        coordinator?.handleMouseMove(event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        coordinator?.handleMouseMove(event: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        coordinator?.handleMouseMove(event: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        coordinator?.handleMouseMove(event: event)
    }

    // Button overrides deliberately do NOT call super: the guest owns the
    // pointer while this view has it, and AppKit's default handling (e.g.
    // rightMouseDown popping a context menu) must not run.
    override func mouseDown(with event: NSEvent) {
        coordinator?.handleMouseButton(event: event, button: .left, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        coordinator?.handleMouseButton(event: event, button: .left, pressed: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.handleMouseButton(event: event, button: .right, pressed: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        coordinator?.handleMouseButton(event: event, button: .right, pressed: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        coordinator?.handleMouseButton(event: event, button: Self.button(for: event), pressed: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        coordinator?.handleMouseButton(event: event, button: Self.button(for: event), pressed: false)
    }

    override func scrollWheel(with event: NSEvent) {
        coordinator?.handleScroll(event: event)
    }

    /// "Other" buttons: AppKit numbers them 2 (middle), 3, 4, ...; the fork's
    /// CSInputButton offers middle/side/extra beyond left/right. Buttons past
    /// 4 fold into .extra — the best available mapping rather than a silent
    /// drop.
    private static func button(for event: NSEvent) -> CSInputButton {
        switch event.buttonNumber {
        case 2:  return .middle
        case 3:  return .side
        case 4:  return .extra
        default: return .extra
        }
    }
}

// MARK: - Coordinator
final class SPICECoordinator: NSObject, CSConnectionDelegate {
    private var connection: CSConnection?
    private var renderer: CSMetalRenderer?
    private var primaryDisplay: CSDisplay?
    private var input: CSInput?
    private weak var mtkView: MTKView?
    private let focusLock: FocusLockManager

    private var lockCancellable: AnyCancellable?
    private var previousModifiers: NSEvent.ModifierFlags = []
    private var capsLockEngaged: Bool = false

    // VIEWPORT SCALING (issue #3): the guest size most recently applied to
    // the renderer's viewport transform. MAIN-THREAD-ONLY state — written and
    // read exclusively inside applyViewportScale, which runs on the Apple
    // main thread. Exists so view-geometry changes can recompute the scale
    // without a cross-context read of CSDisplay.displaySize.
    // (Issue #4: viewPointToGuestPoint reads it too — also main-thread-only,
    // called from mouse event handlers.)
    private var lastAppliedGuestSize: CGSize = .zero

    // STUCK-KEY FIX: the set of non-modifier scancodes currently pressed in the
    // guest (as far as we've forwarded). Because macOS withholds keyUp while
    // Command is held, a key pressed as part of a Command chord (e.g. Return in
    // Win+Ctrl+Enter) would otherwise never be released. We force-release any
    // key still in this set when the modifier flags change (the chord lifting),
    // and on the unlock path. Modifier scancodes are NOT tracked here — they are
    // driven directly by flagsChanged.
    private var pressedScancodes = Set<Int32>()

    // MOUSE INPUT (issue #4): the mouse buttons currently held in the guest
    // (as far as we've forwarded) — the pointer-side sibling of
    // pressedScancodes, MAIN-THREAD-ONLY for the same reason. Sent as the
    // mask on every position/button/scroll event, and flushed on unlock and
    // teardown so an interrupted drag never strands a held button.
    private var pressedMouseButtons: CSInputButton = []

    // MOUSE INPUT (issue #4): scroll accumulator, in POINT units. Trackpad
    // precise deltas add directly; wheel line deltas are converted to point
    // units on entry so both device classes share one accumulator (residue on
    // a device switch is sub-tick and harmless). Drained in whole ticks of
    // preciseScrollPointsPerTick; the fractional remainder carries over.
    private var scrollAccumulatorY: CGFloat = 0
    private static let preciseScrollPointsPerTick: CGFloat = 10

    // MOUSE INPUT (issue #4): one-shot flag so the server-refused-absolute-
    // mode announcement fires once per transition, not once per click.
    private var warnedRelativeCursorMode = false

    /// All fork mouse buttons, for flush iteration (option sets aren't
    /// natively iterable).
    private static let allMouseButtons: [CSInputButton] = [.left, .middle, .right, .side, .extra]

    init(focusLock: FocusLockManager) {
        self.focusLock = focusLock
        super.init()
    }

    var isLocked: Bool { focusLock.isLocked }

    // MARK: Setup
    func attach(mtkView: MTKView, socketPath: String) {
        self.mtkView = mtkView

        lockCancellable = focusLock.$isLocked
            .removeDuplicates()
            .sink { [weak self] locked in
                if !locked {
                    // UNLOCK-FREEZE FIX: do NOT touch CSInput synchronously from
                    // the main thread here — if the SPICE worker is wedged (the
                    // audio-teardown deadlock case), a synchronous call
                    // deadlocks the main thread. Queue the flush on the SPICE
                    // context.
                    self?.flushGuestKeysOnSpiceContext(reason: "unlock observed")
                }
            }

        let spiceMain = CSMain.shared
        if !spiceMain.running {
            guard spiceMain.spiceStart() else {
                avmPublicLog("Failed to start SPICE worker thread.")
                return
            }
        }
        let r = CSMetalRenderer(metalKitView: mtkView)
        r.changeUpscaler(.linear, downscaler: .linear)
        // The renderer IS the MTKView's delegate, directly. (2026-08-03
        // instrument teardown: the LoggingMTKViewDelegate wrapper that sat
        // between them during the display investigation was removed; this is
        // the shipping wiring its own removal note prescribed.)
        mtkView.delegate = r
        self.renderer = r

        let socketURL = URL(fileURLWithPath: socketPath)
        let conn = CSConnection(unixSocketFile: socketURL)
        conn.delegate = self
        // Audio ENABLED: when true, CSConnection calls spice_audio_get(), wiring
        // the SPICE audio channel into CocoaSpice's GStreamer pipeline. The
        // pipeline terminates in osxaudiosink (the osxaudio + autodetect plugins
        // are statically registered in gst_ios_init, and gst_ios_init() is
        // already called by CSMain on spiceStart), so guest audio — Narrator,
        // JAWS, NVDA — reaches the Mac's CoreAudio output. This is the PRIMARY
        // output channel for a blind user, so it must stay enabled.
        // KNOWN UPSTREAM ISSUE (sample-proven 2026-07-12): the osxaudiosink
        // teardown path can deadlock against CoreAudio's IO thread when the
        // guest stops its audio stream (observed at OOBE's PIN screen),
        // permanently wedging the SPICE worker — display/input die until the
        // VM is restarted. The teardown rules in this file keep AVM's main
        // thread (and QMP-based Stop) alive when that happens.
        conn.audioEnabled = true
        self.connection = conn

        guard conn.connect() else {
            avmPublicLog("CSConnection.connect() returned false for socket: \(socketPath)")
            return
        }
        avmPublicLog("SPICE connection initiated.")
    }

    func disconnect() {
        // IMPORTANT: dismantleNSView calls this on the MAIN THREAD. We must NOT
        // call CSMain.shared.spiceStop() here.
        //
        // spiceStop() stops the global SPICE worker (GLib main loop) and BLOCKS
        // waiting for that thread to finish — but the worker delivers its own
        // teardown callbacks (spiceDisplayDestroyed / spiceDisconnected) and
        // needs the main thread to keep pumping to complete shutdown. Calling it
        // from the main thread is a mutual wait => instant hang on view dismantle
        // (confirmed via `sample`: main thread parked in dismantleNSView).
        //
        // CSMain.shared is a PROCESS-GLOBAL singleton meant to live for the whole
        // app session; attach() already guards spiceStart() on !running, so we
        // simply leave it running. Tearing down the view only needs to drop THIS
        // connection and detach the renderer — not stop the shared SPICE loop.
        //
        // UNLOCK-FREEZE FIX (sample-proven 2026-07-12): ALL CocoaSpice work —
        // removeRenderer, key flush, connection.disconnect(), AND the
        // connection's FINAL RELEASE — is queued onto CSMain.shared.async.
        // The release matters most: -[CSConnection dealloc] internally does a
        // SYNCHRONOUS -[CSMain syncWith:] (CSConnection.m:404), so dropping the
        // last reference on the main thread ("connection = nil" here) blocked
        // the main thread forever when the worker was wedged in the osxaudiosink
        // deadlock — the exact stack captured by the hang sample. Strong
        // references are captured BEFORE the fields are nilled below, so the
        // objects stay alive until the SPICE context finishes with them (or
        // leak harmlessly if the worker is wedged — the main thread never
        // waits either way). The delegate is nilled synchronously FIRST so no
        // further callbacks race this teardown.

        lockCancellable?.cancel()
        lockCancellable = nil

        // Stop the MTKView from driving any further frames against a display
        // we're about to release.
        mtkView?.delegate = nil
        mtkView?.isPaused = true

        // Silence delegate callbacks immediately (plain property write; not a
        // context-bound CocoaSpice operation).
        connection?.delegate = nil

        // Capture strong references on the main thread, then queue the
        // CocoaSpice teardown work — and the final releases — on the SPICE
        // context.
        let connectionToClose = connection
        let displayToDetach = primaryDisplay
        let rendererToDetach = renderer
        let inputToFlush = input
        let codesToRelease = pressedScancodes
        pressedScancodes.removeAll()
        // MOUSE INPUT (issue #4): held buttons flush on teardown exactly like
        // stuck keys — same capture-then-queue discipline.
        let buttonsToRelease = pressedMouseButtons
        pressedMouseButtons = []
        scrollAccumulatorY = 0

        CSMain.shared.async {
            if let displayToDetach, let rendererToDetach {
                displayToDetach.removeRenderer(rendererToDetach)
                NSLog("AVM: teardown — renderer removed from display on the SPICE context.")
            }
            if let inputToFlush {
                if !codesToRelease.isEmpty {
                    NSLog("AVM: teardown — flushing \(codesToRelease.count) stuck guest key(s) on the SPICE context.")
                }
                for code in codesToRelease {
                    inputToFlush.send(.release, code: code)
                }
                if !buttonsToRelease.isEmpty {
                    NSLog("AVM: teardown — releasing held guest mouse button(s) on the SPICE context.")
                }
                for button in Self.allMouseButtons where buttonsToRelease.contains(button) {
                    inputToFlush.sendMouseButton(button, mask: [], pressed: false)
                }
                inputToFlush.releaseKeys()
            }
            if let connectionToClose {
                connectionToClose.disconnect()
                NSLog("AVM: teardown — connection disconnected on the SPICE context.")
            }
            // The captured strong references (connectionToClose in particular)
            // die HERE, on the SPICE context — so CSConnection dealloc's
            // internal syncWith: runs on its own context instead of blocking
            // the main thread.
        }

        connection = nil
        renderer = nil
        primaryDisplay = nil
        input = nil

        // Deliberately NOT calling CSMain.shared.spiceStop() — see note above.
    }

    // MARK: - Keyboard input

    /// UNLOCK-FREEZE FIX: snapshot the tracked scancodes and the input channel
    /// on the main thread, clear the tracking set immediately, and queue the
    /// release sends + releaseKeys() onto CocoaSpice's GLib main context. The
    /// strong capture keeps CSInput alive until the SPICE context runs the
    /// block. Used by the unlock observer and any path that must not risk a
    /// synchronous call into a possibly-wedged SPICE worker.
    /// (Issue #4: held mouse buttons flush here too — an unlock mid-drag must
    /// not strand a held button in the guest, exactly as it must not strand a
    /// held key.)
    private func flushGuestKeysOnSpiceContext(reason: String) {
        let inputToFlush = input
        let codesToRelease = pressedScancodes
        pressedScancodes.removeAll()
        let buttonsToRelease = pressedMouseButtons
        pressedMouseButtons = []
        scrollAccumulatorY = 0

        guard let inputToFlush else {
            NSLog("AVM: guest-key flush (\(reason)) — no input channel; tracking cleared.")
            return
        }
        NSLog("AVM: guest-key flush (\(reason)) — queued \(codesToRelease.count) tracked key(s)\(buttonsToRelease.isEmpty ? "" : " + held mouse button(s)") + releaseKeys on the SPICE context.")
        CSMain.shared.async {
            for code in codesToRelease {
                inputToFlush.send(.release, code: code)
            }
            for button in Self.allMouseButtons where buttonsToRelease.contains(button) {
                inputToFlush.sendMouseButton(button, mask: [], pressed: false)
            }
            inputToFlush.releaseKeys()
        }
    }

    /// Force-release every non-modifier key we believe is still pressed in the
    /// guest. Used by the Command-chord stuck-key flush in handleFlagsChanged —
    /// the HOT typing path, which sends on the main thread exactly as handleKey
    /// does on every keystroke (exercised constantly without incident; outside
    /// the unlock-freeze audit). The unlock/teardown paths use
    /// flushGuestKeysOnSpiceContext instead. Safe to call when empty.
    private func releaseAllPressedKeys() {
        guard let input else { pressedScancodes.removeAll(); return }
        if !pressedScancodes.isEmpty {
            NSLog("AVM: flushing \(pressedScancodes.count) stuck guest key(s).")
        }
        for code in pressedScancodes {
            input.send(.release, code: code)
        }
        pressedScancodes.removeAll()
    }

    func handleKey(event: NSEvent, pressed: Bool) {
        guard isLocked, let input else {
            NSLog("AVM: handleKey gated — locked=\(isLocked), input=\(input != nil ? "present" : "nil")")
            return
        }

        let vk = Int(event.keyCode)

        // AUTO-REPEAT SUPPRESSION — F19 COURIER ONLY (2026-07-26, MEASURED).
        //
        // The courier reaches macOS as an ordinary function key, so macOS
        // applies normal typematic repeat to it — which a real Caps Lock key
        // never receives, because macOS handles Caps Lock in the HID driver
        // and never generates key events for it at all.
        //
        // MEASURED, not assumed (unified log, Notepad, repeat at system
        // defaults): a 4.016 s hold produced 44 .press sends and ONE .release.
        // First repeat at +499 ms, then one every ~83 ms (~12/sec). A quick tap
        // in the same run produced exactly one press and one release (273 ms) —
        // that tap is the positive control the hold is read against.
        //
        // OBSERVED GUEST BEHAVIOR: with JAWS running in laptop layout, four
        // holds of 1–4 s all left caps state OFF and produced no speech. JAWS
        // consumes a bare held modifier, so the repeat run was absorbed and was
        // never user-visible. That absorption is JAWS's doing, NOT AVM's, and it
        // is not something to depend on: what raw Windows does with 44 makes was
        // never measured, and a user with no screen reader running is outside
        // everything that was tested.
        //
        // WHY SUPPRESS ANYWAY — both reasons are measured, neither depends on
        // guest behavior:
        //   1. LOG VOLUME. 44 lines per Caps Lock hold, on the key JAWS and
        //      NVDA users hold all day. The tester-facing log has to stay
        //      readable; one press + one release is both correct and legible.
        //   2. 43 redundant input.send calls per hold on the main-thread hot
        //      path, for zero added meaning.
        // And it makes the outcome INDEPENDENT of the tester's key-repeat
        // setting by construction rather than by luck — one make, one break,
        // for a hold of any length.
        //
        // SCOPED TO F19 DELIBERATELY. Ordinary keys must keep their repeats:
        // arrows, Backspace and Tab are all held on purpose during navigation,
        // and a blanket isARepeat filter would break them.
        //
        // ORDERING NOTE: event.type is checked BEFORE event.isARepeat. isARepeat
        // is only meaningful on key events, and Swift's guard-list commas
        // short-circuit, so the type check protects the access.
        //
        // No logging here on purpose — silently dropping the 43 duplicates is
        // the entire point.
        //
        // pressedScancodes is unaffected: the single keyUp still arrives and
        // still removes the code, so the stuck-key flush and the unlock flush
        // keep working exactly as before.
        if pressed, vk == kVK_F19, event.type == .keyDown, event.isARepeat {
            return
        }

        guard let scancode = Self.scancode(forVirtualKey: vk) else {
            // Stage B: an unmapped key is a REAL FAILURE — the key silently
            // does nothing in the guest — so it must not vanish from a
            // default-off diagnostic capture. The fallback line names no key:
            // "some unmapped key was pressed" identifies nothing and can
            // reconstruct no text. The vk appears only when the flag is on.
            if KeyEventLogging.isEnabled {
                NSLog("AVM: key vk=\(vk) has no scancode mapping (ignored).")
            } else {
                NSLog("AVM: key with no scancode mapping ignored.")
            }
            return
        }
        let code = Int32(scancode)
        // Stage B: THE keylogger line — every character typed in the guest is
        // recoverable from it. Gated; see KeyEventLogging at the top of the
        // file. The send below is NOT gated — forwarding is unconditional.
        // NEVER route this through avmPublicLog.
        if KeyEventLogging.isEnabled {
            NSLog("AVM: key vk=\(vk) -> scancode=0x\(String(scancode, radix: 16)) pressed=\(pressed)")
        }
        input.send(pressed ? .press : .release, code: code)

        // Track held non-modifier keys so we can force-release them if AppKit
        // withholds the keyUp (the Command-chord case). The keyUp, when it DOES
        // arrive, simply removes the code here as normal.
        //
        // NOTE (F19 courier): a remapped Caps Lock arrives here as F19 and is
        // tracked like any other non-modifier key, so it inherits the stuck-key
        // flush and the unlock flush for free. Its auto-repeat is filtered out
        // above (see the measurement there), so a held Caps Lock inserts once
        // and is removed once.
        if pressed {
            pressedScancodes.insert(code)
        } else {
            pressedScancodes.remove(code)
        }
    }

    func handleFlagsChanged(event: NSEvent) {
        guard isLocked, let input else {
            previousModifiers = event.modifierFlags
            return
        }

        let flags = event.modifierFlags

        // LEGACY CAPS LOCK FALLBACK — see "CAPS LOCK / THE F19 COURIER" in the
        // file header. This path runs ONLY when no hidutil remap is active,
        // because with the remap macOS never reports a caps-lock flag change at
        // all. It can deliver a TAP and can never deliver a HOLD, so guest
        // screen readers cannot use Caps Lock as their modifier while this is
        // the only path. Retained deliberately so that behavior with no mapping
        // applied is unchanged.
        let capsNow = flags.contains(.capsLock)
        if capsNow != capsLockEngaged {
            capsLockEngaged = capsNow
            // Stage B: names a key and fires on a press — gated.
            if KeyEventLogging.isEnabled {
                NSLog("AVM: Caps Lock toggle -> synthesizing press+release (0x3A). NOTE: tap only, no hold; see F19 courier note.")
            }
            input.send(.press, code: Int32(0x3A))
            input.send(.release, code: Int32(0x3A))
        }

        let vk = Int(event.keyCode)
        if let scancode = Self.scancode(forVirtualKey: vk) {
            let mask = Self.modifierMask(forVirtualKey: vk)
            let isDown = !mask.isEmpty && flags.contains(mask)
            // Stage B: names which modifier went down/up and when — key
            // identity, so gated. The send below is NOT gated.
            if KeyEventLogging.isEnabled {
                NSLog("AVM: modifier vk=\(vk) -> scancode=0x\(String(scancode, radix: 16)) down=\(isDown)")
            }
            input.send(isDown ? .press : .release, code: Int32(scancode))
        }

        // STUCK-KEY FLUSH: if the modifier set is shrinking (a chord is being
        // released) and we still believe non-modifier keys are held, those keys'
        // keyUp events were withheld by AppKit while Command was down. Release
        // them now. We compare against the count of "interesting" modifiers
        // (command/control/option/shift) to detect a release transition.
        let interesting: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let nowCount = flags.intersection(interesting).rawValue.nonzeroBitCount
        let prevCount = previousModifiers.intersection(interesting).rawValue.nonzeroBitCount
        if nowCount < prevCount && !pressedScancodes.isEmpty {
            releaseAllPressedKeys()
        }

        previousModifiers = flags
    }

    // MARK: - Mouse input (issue #4 — see MOUSE INPUT in the file header)

    /// ONE SOURCE OF TRUTH (issues #3 + #4): the aspect-fit scale formula,
    /// shared by the render path (applyViewportScale) and the mouse path
    /// (viewPointToGuestPoint). Extracting it is what makes render and input
    /// incapable of disagreeing by construction — the design rule recorded in
    /// this file's header the day the render transform shipped.
    static func aspectFitScale(drawable: CGSize, guest: CGSize) -> CGFloat {
        min(drawable.width / guest.width, drawable.height / guest.height)
    }

    /// APPLE MAIN THREAD ONLY (called from mouse event handlers). Convert an
    /// NSEvent's locationInWindow to guest absolute coordinates:
    /// window -> view points -> backing pixels -> flip Y (unflipped NSView is
    /// bottom-left origin; the guest is top-left) -> subtract the centering
    /// offset (drawable − guest×scale)/2 — the geometric meaning of the
    /// fork's centered quad at viewportOrigin zero -> divide by the SHARED
    /// aspect-fit scale -> clamp to guest bounds. Returns nil until a display
    /// has bound (lastAppliedGuestSize is zero) or when geometry is
    /// degenerate — the callers treat nil as "nothing to send".
    private func viewPointToGuestPoint(_ locationInWindow: NSPoint) -> CGPoint? {
        guard let mtkView else { return nil }
        let guest = lastAppliedGuestSize
        guard guest.width > 0, guest.height > 0 else { return nil }
        let drawable = mtkView.drawableSize
        guard drawable.width > 0, drawable.height > 0 else { return nil }

        let viewPoint = mtkView.convert(locationInWindow, from: nil)
        let backing = mtkView.convertToBacking(viewPoint)
        let pixelX = backing.x
        let pixelY = drawable.height - backing.y   // Y-flip: bottom-left -> top-left

        let scale = Self.aspectFitScale(drawable: drawable, guest: guest)
        guard scale > 0 else { return nil }
        let offsetX = (drawable.width - guest.width * scale) / 2
        let offsetY = (drawable.height - guest.height * scale) / 2

        let guestX = min(max((pixelX - offsetX) / scale, 0), guest.width - 1)
        let guestY = min(max((pixelY - offsetY) / scale, 0), guest.height - 1)
        return CGPoint(x: guestX, y: guestY)
    }

    /// SILENCE IS A BUG, the pointer edition: if the SPICE server holds the
    /// cursor in relative (server) mode, every sendMousePosition is silently
    /// ignored per the fork's own docs — invisible by construction. Checked
    /// at every button press (cheap — one Bool read); announced exactly once
    /// per transition in each direction.
    /// MODE RETRY (2026-08-08, probe run 1 — see MOUSE INPUT in the file
    /// header for the full evidence chain): the one-shot request at
    /// spiceInputAvailable fires within ~20 ms of the channel appearing on a
    /// freshly rebuilt connection, early enough to lose to negotiation
    /// timing — and nothing ever asked again (probe-proven: healthy guest
    /// tablet, transmitted request, server still in server mode 13 s later).
    /// So: while the wrong mode persists, RE-REQUEST client mode on every
    /// detection. Idempotent, self-healing for any transient cause, and
    /// free in the healthy state — this call only runs while the mode is
    /// wrong. The request is queued on the SPICE context by the fork
    /// (requestMouseMode's own asyncWith:), so this stays safe from the
    /// main thread per the standing thread rule.
    private func warnIfRelativeCursorMode(_ input: CSInput) {
        if input.serverModeCursor {
            input.requestMouseMode(false)
            if !warnedRelativeCursorMode {
                warnedRelativeCursorMode = true
                avmPublicLog("SPICE server reports RELATIVE (server-mode) cursor despite the absolute-mode request — absolute mouse positions are being IGNORED by the server; re-requesting client mode on every press until granted (issue #4).")
            }
        } else if warnedRelativeCursorMode {
            warnedRelativeCursorMode = false
            avmPublicLog("SPICE server granted ABSOLUTE (client-mode) cursor — pointer input active again (issue #4).")
        }
    }

    /// HOT pointer path — sends on the main thread exactly as handleKey does
    /// (the proven input pattern in this file). Gated moves are deliberately
    /// SILENT: they arrive hundreds of times a second, and a log line per
    /// event is volume without meaning (the sanctioned-silence class).
    func handleMouseMove(event: NSEvent) {
        guard isLocked, let input else { return }
        guard let guestPoint = viewPointToGuestPoint(event.locationInWindow) else { return }
        input.sendMousePosition(pressedMouseButtons, absolutePoint: guestPoint)
    }

    /// Button events: position is sent FIRST (with the updated mask) so the
    /// click lands where the pointer is, then the button transition itself.
    /// pressedMouseButtons mirrors the guest's held-button state and is the
    /// mask on every subsequent move — that is what makes a drag a drag.
    /// Gated button events LOG, like gated keys: a click that silently does
    /// nothing is a diagnosable event, and clicks are rare enough to afford
    /// the line.
    func handleMouseButton(event: NSEvent, button: CSInputButton, pressed: Bool) {
        guard isLocked, let input else {
            NSLog("AVM: mouse button gated — locked=\(isLocked), input=\(input != nil ? "present" : "nil")")
            return
        }
        warnIfRelativeCursorMode(input)

        if pressed {
            pressedMouseButtons.insert(button)
        } else {
            pressedMouseButtons.remove(button)
        }

        if let guestPoint = viewPointToGuestPoint(event.locationInWindow) {
            input.sendMousePosition(pressedMouseButtons, absolutePoint: guestPoint)
        }
        input.sendMouseButton(button, mask: pressedMouseButtons, pressed: pressed)
    }

    /// Scroll: discrete SPICE ticks for both device classes (see MOUSE INPUT
    /// in the file header for the full rationale, including why
    /// kCSInputScrollSmooth is deliberately not used). The accumulator lives
    /// in point units; wheel line deltas are converted on entry. Whole ticks
    /// drain; the fractional remainder carries over, so slow precise
    /// scrolling still eventually ticks. scrollingDeltaY already carries the
    /// user's natural-scrolling preference — positive means scroll up.
    func handleScroll(event: NSEvent) {
        guard isLocked, let input else { return }

        if event.hasPreciseScrollingDeltas {
            scrollAccumulatorY += event.scrollingDeltaY
        } else {
            scrollAccumulatorY += event.scrollingDeltaY * Self.preciseScrollPointsPerTick
        }

        let ticks = Int(scrollAccumulatorY / Self.preciseScrollPointsPerTick)
        guard ticks != 0 else { return }
        scrollAccumulatorY -= CGFloat(ticks) * Self.preciseScrollPointsPerTick

        let direction: CSInputScroll = ticks > 0 ? .up : .down
        for _ in 0..<abs(ticks) {
            input.sendMouseScroll(direction, buttonMask: pressedMouseButtons, dy: 0)
        }
    }

    // MARK: - Viewport scaling (issue #3)

    /// Queue a viewport-scale recomputation on the Apple main thread, with a
    /// guest size CAPTURED BY VALUE on the caller's context. See VIEWPORT
    /// SCALING in the file header. Called from the binding decision paths
    /// with the winner's (or holder's) displaySize — the same value the
    /// binding decision itself was made on, so the transform and the binding
    /// can never disagree about the guest's size.
    private func scheduleViewportScaleUpdate(guestSize: CGSize) {
        DispatchQueue.main.async { [weak self] in
            self?.applyViewportScale(guestSize: guestSize)
        }
    }

    /// Recompute the scale from the CURRENT drawable size after a view
    /// geometry change (frame resize, backing-scale change). Uses the last
    /// applied guest size; a harmless no-op until a display has bound.
    /// Called by SPICEKeyCaptureView's overrides on the Apple main thread;
    /// the async hop lets MTKView's automatic drawable resize settle before
    /// drawableSize is read (a synchronous read inside setFrameSize can see
    /// the OLD drawable for one cycle).
    func viewGeometryChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyViewportScale(guestSize: self.lastAppliedGuestSize)
        }
    }

    /// APPLE MAIN THREAD ONLY. Compute the aspect-fit scale and apply it to
    /// the renderer. viewportOrigin stays (0,0) — the fork builds its display
    /// vertices CENTERED (quad spans ±width/2; read in CSDisplay.m
    /// rebuildDisplayVertices, 2026-08-07), so origin zero already means
    /// centered in the drawable and no origin arithmetic is needed.
    /// The fork's own setters are no-ops on unchanged values; the epsilon
    /// guard here exists only to keep the announcement stream free of
    /// no-change noise.
    /// (Issue #4: the scale formula lives in Self.aspectFitScale — SHARED
    /// with the mouse conversion; the computation is unchanged.)
    private func applyViewportScale(guestSize: CGSize) {
        guard guestSize.width > 0, guestSize.height > 0 else { return }
        guard let renderer, let mtkView else { return }
        let drawable = mtkView.drawableSize
        guard drawable.width > 0, drawable.height > 0 else { return }

        lastAppliedGuestSize = guestSize
        let scale = Self.aspectFitScale(drawable: drawable, guest: guestSize)
        guard abs(renderer.viewportScale - scale) > 0.0005 else { return }
        renderer.viewportOrigin = .zero
        renderer.viewportScale = scale
        // PUBLIC: a configuration choice, announced — joins the binding
        // decision lines as part of the display evidence stream.
        avmPublicLog(String(format: "viewport scale set to %.3f for drawable %dx%d, guest %dx%d (aspect-fit, issue #3).",
                            scale,
                            Int(drawable.width), Int(drawable.height),
                            Int(guestSize.width), Int(guestSize.height)))
    }

    // MARK: - Display binding (the black-window fix)

    /// DETERMINISTIC DISPLAY BINDING (2026-08-03 — see the file header section
    /// of the same name for the mechanism, the evidence, and the stated
    /// size-proxy assumption).
    ///
    /// THE SELECTION RULE, in full:
    ///   - An EMPTY slot takes any display (the historical nil fallback,
    ///     preserved: some head is better than none, and a better one
    ///     transfers the renderer away later).
    ///   - A display STRICTLY LARGER in displaySize area than the current
    ///     holder takes the slot; the renderer transfers.
    ///   - TIES KEEP THE INCUMBENT — no churn on equal sizes, and re-delivery
    ///     of the holder's own config is a no-op.
    ///   - Enumeration order and isPrimaryDisplay play NO role.
    ///
    /// CALLED FROM spiceDisplayCreated AND spiceDisplayUpdated, which both
    /// arrive on the SPICE context — the same context where CocoaSpice writes
    /// displaySize, so the size read here is current by construction (and the
    /// fork connects the connection-level monitors handler with
    /// g_signal_connect_after, so CSDisplay's own size update has already run
    /// by the time either callback fires). Evaluating on Updated is what
    /// covers a live head that is still small at creation and grows at
    /// firmware mode-set: the resize re-runs this rule and the transfer
    /// catches up (OBSERVED LIVE, run 17 generation A: mon 0 created at
    /// 640x480, declined, then WON at its 800x600 update). The slot write
    /// happens synchronously here, exactly where the old policy wrote it; the
    /// renderer transfer is queued through the main thread (AppKit bounds
    /// read) onto the SPICE context, unchanged machinery.
    ///
    /// EVERY DECISION IS ANNOUNCED (win or decline) through avmPublicLog.
    /// These lines were the primary evidence stream for the binding proof
    /// (runs 11–17) and are RETAINED PERMANENTLY (2026-08-03 instrument
    /// teardown) as the field-diagnosis stream: they announce a configuration
    /// choice, and display events are rare (a handful per generation), so the
    /// volume is trivial.
    ///
    /// VIEWPORT SCALING (2026-08-07, issue #3): the slot-touching paths below
    /// also schedule the aspect-fit scale update, passing the SAME size the
    /// decision was made on. The decline path deliberately does not — a
    /// loser's size is irrelevant to the transform.
    private func considerForPrimarySlot(_ display: CSDisplay, event: String) {
        let pointerText = String(format: "0x%lx", UInt(bitPattern: Unmanaged.passUnretained(display).toOpaque()))
        let size = display.displaySize
        let area = size.width * size.height

        if let holder = primaryDisplay {
            if holder === display {
                // The holder's own event. Nothing to decide for the slot; the
                // resize (if any) reaches the renderer through CocoaSpice's
                // own rebuild — but the TRANSFORM must track it, so the scale
                // update runs with the holder's current size (issue #3).
                avmPublicLog("display binding (\(event)) — display=\(pointerText) mon=\(display.monitorID) size=\(Int(size.width))x\(Int(size.height)) is already the slot holder; no action.")
                scheduleViewportScaleUpdate(guestSize: size)
                return
            }
            let holderSize = holder.displaySize
            let holderArea = holderSize.width * holderSize.height
            guard area > holderArea else {
                avmPublicLog("display binding (\(event)) — display=\(pointerText) mon=\(display.monitorID) size=\(Int(size.width))x\(Int(size.height)) does NOT beat holder mon=\(holder.monitorID) size=\(Int(holderSize.width))x\(Int(holderSize.height)); slot unchanged.")
                return
            }
            avmPublicLog("display binding (\(event)) — display=\(pointerText) mon=\(display.monitorID) size=\(Int(size.width))x\(Int(size.height)) WINS slot from mon=\(holder.monitorID) size=\(Int(holderSize.width))x\(Int(holderSize.height)) (strictly larger area).")
        } else {
            avmPublicLog("display binding (\(event)) — display=\(pointerText) mon=\(display.monitorID) size=\(Int(size.width))x\(Int(size.height)) takes the EMPTY slot.")
        }

        let previousHolder = primaryDisplay
        primaryDisplay = display

        // VIEWPORT SCALING (issue #3): a new holder means a new guest size for
        // the transform. Same size value the decision above was made on.
        scheduleViewportScaleUpdate(guestSize: size)

        // SINGLE-ATTACHMENT RULE (2026-07-29 — see file header): the renderer
        // must be attached to at most ONE display, so winning the slot
        // TRANSFERS the renderer: detach from the previous holder before
        // attaching to the winner. This machinery is UNCHANGED by the binding
        // policy; only the decision above changed.
        //
        // CocoaSpice's display operations (addRenderer triggers an immediate
        // invalidate, which delivers the current framebuffer to the renderer)
        // MUST run on CocoaSpice's GLib main context — the invalidate path
        // asserts isCurrentContextMain. Calling them from DispatchQueue.main
        // (Apple's main thread) is the WRONG context: the first-frame
        // invalidate does not deliver, and because a static guest screen
        // never invalidates again, the display stays permanently blank. Every
        // internal CocoaSpice op (CSInput/CSCursor/CSDisplay) uses asyncWith:
        // for exactly this reason; we must too.
        //
        // We read the AppKit bounds on the Apple main thread first (UI reads
        // must not happen on the GLib context), then hop to CocoaSpice's
        // context for the actual display calls.
        //
        // ORDERING: the detach and the attach are queued in one block on
        // the SPICE context, detach first — so there is no window where
        // the renderer is attached to both displays, and no window where
        // frames could arrive from the old head after the new attach.
        // Two rapid wins (empty-slot take, then a larger head arriving)
        // queue two of these blocks; each captures its own previousHolder,
        // and queue discipline on both queues preserves their order, so the
        // renderer walks holder-to-holder without ever being double-attached.
        //
        // (2026-08-03: the ATTACH NUDGE block that used to follow the attach
        // here was REMOVED — Handoff 26 queue item 1, confirmed clean by run
        // 17; see DISPLAY INVESTIGATION STATE in the file header for the
        // record. Initial delivery rides solely on addRenderer's own
        // rebuild-and-push.)
        DispatchQueue.main.async { [weak self] in
            guard let self, let renderer = self.renderer else { return }
            let size = self.mtkView?.bounds.size ?? .zero
            CSMain.shared.async { [weak self] in
                guard let self, self.renderer === renderer else { return }
                if let previousHolder, previousHolder !== display {
                    previousHolder.removeRenderer(renderer)
                    avmPublicLog("renderer detached from previous display monitor \(previousHolder.monitorID) (transferring to monitor \(display.monitorID)).")
                }
                display.addRenderer(renderer)
                avmPublicLog("renderer registered with display monitor \(display.monitorID).")
                if size != .zero {
                    display.requestResolution(CGRect(origin: .zero, size: size))
                }
            }
        }
    }

    // MARK: CSConnectionDelegate
    func spiceConnected(_ connection: CSConnection) {
        avmPublicLog("SPICE connected.")
    }
    func spiceDisconnected(_ connection: CSConnection) {
        avmPublicLog("SPICE disconnected.")
    }
    func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        avmPublicLog("SPICE error \(code.rawValue): \(message ?? "unknown")")
    }

    func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        // PUBLIC: display lifecycle is the spine of the binding evidence and
        // must be readable from `log show`. The pointer is formatted to match
        // the fork's %p markers so the two streams join. (The old "primary:"
        // field is gone from this line — the flag is channel order, which
        // mon= already states.)
        let pointerText = String(format: "0x%lx", UInt(bitPattern: Unmanaged.passUnretained(display).toOpaque()))
        avmPublicLog("SPICE display created — display=\(pointerText) monitor \(display.monitorID), size: \(Int(display.displaySize.width))x\(Int(display.displaySize.height))")
        display.isEnabled = true

        // DETERMINISTIC DISPLAY BINDING: the selection rule replaces the old
        // "isPrimaryDisplay (channel 0) always wins / nil fallback" policy.
        // See the helper and the file header.
        considerForPrimarySlot(display, event: "created")
    }

    func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        // (2026-07-29, VERIFIED IN COCOASPICE SOURCE: this callback is emitted
        // from the "monitors" CONFIG notify — it fires on geometry changes
        // only, NEVER on frame content. It is not evidence about frame
        // delivery in either direction. 2026-08-03: geometry changes are now
        // exactly what the binding policy keys on, so this callback is a
        // first-class input to the selection rule — a live head that was
        // small at creation wins the slot here when its mode-set resize
        // arrives; observed live in run 17.)
        //
        // STAGE C (2026-08-03): the pre-binding-work "DEBUG draw —
        // spiceDisplayUpdated fired" NSLog that lived here was REMOVED under
        // its banked Stage C disposition. It was per-event chatter whose
        // information is fully covered: every evaluation this callback
        // triggers is announced by the binding decision lines below (via
        // avmPublicLog), and raw update-activity ground truth is the fork's
        // FILL stream. It was the last surviving piece of pre-binding
        // scaffolding.

        considerForPrimarySlot(display, event: "updated")

        // Keep the guest resolution request tracking the SLOT HOLDER — keyed
        // on identity, not on the isPrimaryDisplay flag (which is channel
        // order and now plays no role). No-op on an agent-less guest; kept
        // for a future where guest tools exist. Same context rule as the
        // transfer: read AppKit bounds on the Apple main thread, then run
        // requestResolution on CocoaSpice's GLib main context.
        if primaryDisplay === display {
            DispatchQueue.main.async { [weak self] in
                guard let self, let mtkView = self.mtkView, mtkView.bounds.size != .zero else { return }
                let size = mtkView.bounds.size
                CSMain.shared.async {
                    display.requestResolution(CGRect(origin: .zero, size: size))
                }
            }
        }
    }

    func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        // PUBLIC: this is the generation boundary — a first-class lifecycle
        // event in the binding evidence stream.
        let pointerText = String(format: "0x%lx", UInt(bitPattern: Unmanaged.passUnretained(display).toOpaque()))
        avmPublicLog("SPICE display destroyed — display=\(pointerText) monitor \(display.monitorID)")

        // IDENTITY-ONLY DESTROY (2026-08-03 — see DETERMINISTIC DISPLAY
        // BINDING in the file header). Only the display that IS the current
        // slot holder detaches the renderer and clears the slot. The old
        // `guard isPrimaryDisplay` pre-check is gone: under the size policy
        // the holder can be any monitor ID, and that guard would have
        // early-returned past this detach — leaving a stale holder, the exact
        // cycle-2 anomaly class the 2026-07-29 identity guard caught live.
        // A non-holder display's destroy is a NORMAL event now (the impostor
        // head dies at every generation teardown); it is logged as lifecycle
        // evidence, not flagged as an anomaly.
        if primaryDisplay === display {
            // UNLOCK-FREEZE FIX (same rule as disconnect()): removeRenderer is a
            // CocoaSpice display op — run it on the SPICE context, with a strong
            // capture so the renderer outlives the field nil-out below. Safe even
            // if this callback already arrives on the SPICE context (async onto
            // the current context just runs the block there).
            if let rendererToDetach = renderer {
                CSMain.shared.async {
                    display.removeRenderer(rendererToDetach)
                }
            }
            primaryDisplay = nil
            avmPublicLog("display destroyed — monitor \(display.monitorID) was the slot holder; renderer detach queued, slot cleared.")
        } else {
            let holderDescription: String
            if let holder = primaryDisplay {
                holderDescription = "monitor \(holder.monitorID)"
            } else {
                holderDescription = "nil (slot already clear)"
            }
            avmPublicLog("display destroyed — monitor \(display.monitorID) was NOT the slot holder (holder: \(holderDescription)); slot untouched.")
        }
    }

    func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        NSLog("AVM: SPICE input channel available.")
        self.input = input
        input.requestMouseMode(false)
        // PUBLIC (issue #4): a configuration choice, announced. false =
        // request ABSOLUTE (client-mode) positioning — the mode the fork's
        // sendMousePosition requires and the guest's usb-tablet serves. The
        // server's answer lands in serverModeCursor and is checked (and any
        // refusal announced, with a re-request until granted) at every button
        // press — see warnIfRelativeCursorMode.
        avmPublicLog("SPICE input channel available — absolute (client-mode) cursor requested for pointer input (issue #4).")
    }

    func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        NSLog("AVM: SPICE input channel unavailable.")
        if self.input === input {
            self.input = nil
        }
    }

    func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        NSLog("AVM: SPICE agent connected, features: \(features.rawValue)")
    }
    func spiceAgentDisconnected(_ connection: CSConnection) {
        NSLog("AVM: SPICE agent disconnected.")
    }
    func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {
        NSLog("AVM: SPICE port opened.")
    }
    func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {
        NSLog("AVM: SPICE port closed.")
    }
}

// MARK: - Keycode translation (macOS virtual keycode -> PC XT set-1 scancode)
extension SPICECoordinator {

    static func modifierMask(forVirtualKey vk: Int) -> NSEvent.ModifierFlags {
        switch vk {
        case kVK_Shift, kVK_RightShift:       return .shift
        case kVK_Control, kVK_RightControl:   return .control
        case kVK_Option, kVK_RightOption:     return .option
        case kVK_Command, kVK_RightCommand:   return .command
        default:                              return []
        }
    }

    static func scancode(forVirtualKey vk: Int) -> Int? {
        switch vk {
        // Letters
        case kVK_ANSI_A: return 0x1E
        case kVK_ANSI_B: return 0x30
        case kVK_ANSI_C: return 0x2E
        case kVK_ANSI_D: return 0x20
        case kVK_ANSI_E: return 0x12
        case kVK_ANSI_F: return 0x21
        case kVK_ANSI_G: return 0x22
        case kVK_ANSI_H: return 0x23
        case kVK_ANSI_I: return 0x17
        case kVK_ANSI_J: return 0x24
        case kVK_ANSI_K: return 0x25
        case kVK_ANSI_L: return 0x26
        case kVK_ANSI_M: return 0x32
        case kVK_ANSI_N: return 0x31
        case kVK_ANSI_O: return 0x18
        case kVK_ANSI_P: return 0x19
        case kVK_ANSI_Q: return 0x10
        case kVK_ANSI_R: return 0x13
        case kVK_ANSI_S: return 0x1F
        case kVK_ANSI_T: return 0x14
        case kVK_ANSI_U: return 0x16
        case kVK_ANSI_V: return 0x2F
        case kVK_ANSI_W: return 0x11
        case kVK_ANSI_X: return 0x2D
        case kVK_ANSI_Y: return 0x15
        case kVK_ANSI_Z: return 0x2C

        // Number row
        case kVK_ANSI_1: return 0x02
        case kVK_ANSI_2: return 0x03
        case kVK_ANSI_3: return 0x04
        case kVK_ANSI_4: return 0x05
        case kVK_ANSI_5: return 0x06
        case kVK_ANSI_6: return 0x07
        case kVK_ANSI_7: return 0x08
        case kVK_ANSI_8: return 0x09
        case kVK_ANSI_9: return 0x0A
        case kVK_ANSI_0: return 0x0B

        // Symbols / punctuation
        case kVK_ANSI_Minus:        return 0x0C
        case kVK_ANSI_Equal:        return 0x0D
        case kVK_ANSI_LeftBracket:  return 0x1A
        case kVK_ANSI_RightBracket: return 0x1B
        case kVK_ANSI_Backslash:    return 0x2B
        case kVK_ANSI_Semicolon:    return 0x27
        case kVK_ANSI_Quote:        return 0x28
        case kVK_ANSI_Grave:        return 0x29
        case kVK_ANSI_Comma:        return 0x33
        case kVK_ANSI_Period:       return 0x34
        case kVK_ANSI_Slash:        return 0x35

        // Whitespace / control
        case kVK_Return:    return 0x1C
        case kVK_Tab:       return 0x0F
        case kVK_Space:     return 0x39
        case kVK_Delete:    return 0x0E   // Backspace
        case kVK_Escape:    return 0x01

        // Modifiers (left)
        case kVK_Command:   return 0x100 | 0x5B  // Left GUI (extended)
        case kVK_Shift:     return 0x2A
        case kVK_CapsLock:  return 0x3A
        case kVK_Option:    return 0x38
        case kVK_Control:   return 0x1D

        // Modifiers (right)
        case kVK_RightShift:   return 0x36
        case kVK_RightOption:  return 0x100 | 0x38  // Right Alt (extended)
        case kVK_RightControl: return 0x100 | 0x1D  // Right Ctrl (extended)
        case kVK_RightCommand: return 0x100 | 0x5C  // Right GUI (extended)

        // CAPS LOCK COURIER — F19 DELIBERATELY RETURNS CAPS LOCK'S SCANCODE.
        // This is not a typo. No Mac keyboard has an F19 key; the only way this
        // case can fire is a hidutil UserKeyMapping that remaps the PHYSICAL
        // Caps Lock key to F19 at the HID driver level. That remap is what stops
        // macOS from swallowing Caps Lock as a lock-state change, so the key
        // arrives here as an ordinary keyDown/keyUp pair with real duration —
        // and we hand the guest a genuine, HELD Caps Lock (0x3A) instead of the
        // instantaneous tap that handleFlagsChanged can synthesize.
        // This is what lets JAWS and NVDA (laptop layout) and Narrator (whose
        // default modifier is Caps Lock or Insert) use their modifier key at
        // all. See "CAPS LOCK / THE F19 COURIER" in the file header for the full
        // rationale, the rejected alternative, and CapsLockRemapper for the
        // lock/unlock lifecycle that applies the mapping.
        // The user never presses F19 and the guest never receives F19.
        // NOTE: because the courier is an ordinary function key to macOS, it
        // also receives typematic repeat — filtered in handleKey, where the
        // measurement is recorded.
        case kVK_F19: return 0x3A

        // Function keys
        case kVK_F1:  return 0x3B
        case kVK_F2:  return 0x3C
        case kVK_F3:  return 0x3D
        case kVK_F4:  return 0x3E
        case kVK_F5:  return 0x3F
        case kVK_F6:  return 0x40
        case kVK_F7:  return 0x41
        case kVK_F8:  return 0x42
        case kVK_F9:  return 0x43
        case kVK_F10: return 0x44
        case kVK_F11: return 0x57
        case kVK_F12: return 0x58

        // Navigation cluster (all extended)
        case kVK_Home:          return 0x100 | 0x47
        case kVK_End:           return 0x100 | 0x4F
        case kVK_PageUp:        return 0x100 | 0x49
        case kVK_PageDown:      return 0x100 | 0x51
        case kVK_ForwardDelete: return 0x100 | 0x53
        case kVK_LeftArrow:     return 0x100 | 0x4B
        case kVK_RightArrow:    return 0x100 | 0x4D
        case kVK_UpArrow:       return 0x100 | 0x48
        case kVK_DownArrow:     return 0x100 | 0x50

        // Keypad
        case kVK_ANSI_Keypad0:        return 0x52
        case kVK_ANSI_Keypad1:        return 0x4F
        case kVK_ANSI_Keypad2:        return 0x50
        case kVK_ANSI_Keypad3:        return 0x51
        case kVK_ANSI_Keypad4:        return 0x4B
        case kVK_ANSI_Keypad5:        return 0x4C
        case kVK_ANSI_Keypad6:        return 0x4D
        case kVK_ANSI_Keypad7:        return 0x47
        case kVK_ANSI_Keypad8:        return 0x48
        case kVK_ANSI_Keypad9:        return 0x49
        case kVK_ANSI_KeypadDecimal:  return 0x53
        case kVK_ANSI_KeypadPlus:     return 0x4E
        case kVK_ANSI_KeypadMinus:    return 0x4A
        case kVK_ANSI_KeypadMultiply: return 0x37
        case kVK_ANSI_KeypadDivide:   return 0x100 | 0x35  // extended
        case kVK_ANSI_KeypadEnter:    return 0x100 | 0x1C  // extended

        default:
            return nil
        }
    }
}
