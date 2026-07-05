# Reset-button findings: EO on real hardware (HW-confirmed)

> Investigation of "Extended Oberon seems to handle reset differently — after reset,
> `Hilbert.Draw`/`Stars.Open` don't launch." Live-debugged on silicon 2026-07-04/05 over
> the oberon-agent serial wire plus an on-screen LED instrument (`XLed.Mod`, appendix).
> **Verdict: EO's reset semantics are a designed feature working as intended; the port —
> core, peripherals, and on re-inspection even the SoC reset wiring — is faithful; the
> failure originates in the one place bit-exactness cannot reach: the Nexys-4's
> PS/2-over-USB-HID bridge is not a real PS/2 mouse under a mid-stream re-init.**
> Status: findings only; no fix applied yet.
>
> *Revision note.* A first draft of this doc blamed a board-wide reset domain ("Wirth
> resets the CPU only") and a millisecond-timer rollback. Both claims were **wrong** and
> are retracted below with the source lines that refute them — kept on record because
> the refutation is itself the finding: the SoC glue is faithful, which narrows the
> fault to the board environment.

## TL;DR

| # | finding | status |
|---|---|---|
| 1 | EO hooks memory location 0 (`Kernel.Install(SYSTEM.ADR(Abort), 0)`) so a warm reset is *recovery in place* — log `ABORT`, GC, back into the loop with modules/viewers/heap/tasks preserved. PO leaves location 0 at the boot-file entry → full reinit. | by design, healthy (software-abort verified end-to-end on our hardware) |
| 2 | After a **button** reset, the mouse register intermittently carries **phantom MR (right-button) bits** — latched on hardware by the XLed instrument. One phantom MR anywhere in a click's `keysum` and EO's `TextFrames` **silently discards the command** (`~(0 IN keysum)` cancel-chord guard): no error, no log line, clean underline. This is the user-visible bug. | confirmed on silicon |
| 3 | The same phantom bits explain the **serial-wire deaths**: `Oberon.Loop` services tasks only in its idle branch (`keys = {}`), so a phantom bit — streaming during motion, or latched at rest — parks the loop in click-tracking forever; cursor still tracks, GC + AgentTool poll starve. | consistent with all observed timelines |
| 4 | ~~Board resets the whole SoC unlike Wirth's CPU-only button~~ — **refuted**: `RISC5Top.OStation.v` feeds `rst` to RS232R/T, SPI, PS2 *and* `MouseP` (line 78). Our fanout is faithful. | retracted |
| 5 | ~~ms-timer resets → EO task dormancy~~ — **refuted**: `RISC5Top` lines 139–140 free-run `cnt0`/`cnt1` with no reset term, and both `lib/soc.ml` and the board SoC are faithful (`Reg_spec` without reset, commented "free-running (no reset), like RISC5Top's"). `Kernel.Time()` cannot roll back. | retracted |
| 6 | One press (of several) took the **cold path** — `LNK` read 0 despite the regfile being reset-free RAM (`multiport_memory`, same contract as `RAM16X1D`) and a correct 2-FF reset synchronizer. | unexplained, 1 occurrence |

PO *appears* immune, but under the corrected model it is exposed to the same phantom
window after a button press — its ~20 s cold reboot may simply let the bridge settle
before anyone clicks. Untested; see Next steps.

## How reset reaches software (all verified against source)

- PROM (`lib/rom.ml`, verbatim `prom.mem`): warm/cold test at words 342–344
  (`MOV R0, R15; SUB R0, R0, 0; BNE warm` — cold iff `LNK = 0`); cold runs
  `LoadFromDisk`, which **rewrites location 0** with the boot-file entry; both paths end
  at words 381–382 with `MOV R0, 0; B R0` — an unconditional jump to absolute 0.
  `LED(84H)` (LD2+LD7) is BootLoad's "done" code on both paths and persists (nothing
  rewrites the LED register afterwards); a kernel-trap halt would show `192+n`
  (LD7+LD6+code) instead.
- Registers survive the button (distributed RAM, no reset term) → post-boot presses read
  `LNK ≠ 0` → warm path → jump to location 0, which EO owns. Verified live: branching to
  the location-0 handler over the serial wire produced `ABORT in XProbe` in the log and
  a fully functional system — module loads from disk and viewer opens included. **EO's
  abort recovery is sound.**

## The one real fault: phantom mouse buttons after a mid-stream reset

What the button does to the mouse is *faithful*: `rst` resets `MouseP` on OberonStation
too, and on reset release the module re-runs its 8-command init (F4 + the Microsoft
scroll-magic F3 C8 / F3 64 / F3 50) — see `MousePM.v`. Two facts about that spec matter:

- `MousePM` frames packets by **idle gaps** (`endcount` ≈ 1.15 ms of quiet line), and a
  full packet re-fills the whole `rx` shift register — so pure bit-phase desync
  **self-heals within about one packet**. The decoder is not fragile by itself.
- Against a **real PS/2 mouse**, a mid-stream re-init is well-defined: the host's
  clock-inhibit aborts the in-flight byte, the device ACKs each command and resumes
  aligned streaming. The protocol was designed for this.

The Nexys-4 has no real PS/2 mouse: a **PIC24 USB-HID bridge** emulates one (see the POR
comment in `nexys4_top.v` — the 1.1 s power-on delay exists precisely because this
bridge must enumerate before `MousePM`'s one-shot init fires). A *button* reset re-fires
that init **against a bridge that is actively streaming** — the corner the emulation was
evidently never exercised on. Measured result (XLed, LD5 sticky latch): phantom MR bits
appear after a button reset and keep appearing with mouse activity, without the right
button ever being pressed. Note `0xFA` — the ACK byte the bridge sends after each init
command — read as a flags byte has **bit 1 = PS/2 right button** set; misframed ACKs are
phantom right-clicks. The persistence mechanism (transient init confusion vs. a lasting
bridge mode mismatch) is not yet pinned down — see Next steps.

Downstream, two independent symptoms, both from one bit:

1. **Silent command veto** — EO `TextFrames.Mod` middle-click dispatch:
   `IF (pos >= 0) & ~(0 IN keysum) THEN Call(F, pos, 2 IN keysum)`. MR-in-`keysum` is
   the *cancel chord*; a phantom MR during press-track-release discards the command with
   no output. Observed as "`Hilbert.Draw`/`Stars.Open`/`System.Clear` do nothing" while
   caret, scrollbar, selection, and underline all look normal.
2. **Task starvation** — `Oberon.Loop` runs installed tasks only when
   `Input.Available() = 0` and `keys = {}`. Phantom bits keep `keys ≠ {}`
   (`REPEAT … UNTIL keys = {}` click-tracking), so the GC and the AgentTool serial poll
   never run; the cursor still tracks because tracking itself draws it. Observed as the
   serial link dying while the screen stays live — including one exchange that answered
   at a 16 s round-trip before permanent death (tasks squeezed by intermittent
   contamination), and no recovery even after tens of idle minutes (a phantom bit
   latched in the register at rest).

Why EO surfaces this and PO seemed fine: EO's abort-recovery resumes the running system
*instantly*, straight into the poisoned input stream. PO cold-reboots for ~20 s (SD
reload) before a click matters — and its reboot masks nothing else, since the timer and
RTL are faithful. Whether PO is *actually* immune after a button press is an open
experiment (below), not an established fact.

## Retractions, with the refuting lines

| retracted claim | refutation |
|---|---|
| "OberonStation's button resets the CPU only; our board resets everything — that divergence is the root cause" | `RISC5Top.OStation.v`: `RS232R receiver(.rst(rst)…)` l.66, `RS232T` l.68, `SPI` l.70, `PS2 kbd` l.76, `MouseP Ms(.rst(rst)…)` l.78. Our `soc.ml` fanout matches; `Lreg`/`spiCtrl`/`bitrate`/`gpoc` clear on reset in both (l.138–144). |
| "The button resets the ms timer; EO's preserved `nextTime` stamps leave every task dormant for the prior uptime" | `RISC5Top.OStation.v` l.139–140: `cnt0 <= limit ? 0 : cnt0+1; cnt1 <= cnt1 + limit;` — no `rst` term, free-running. `lib/soc.ml` l.70–80 and board `soc.ml` l.81–92: same, `Reg_spec.create () ~clock` with no reset, comment says so. The dormancy interpretation also failed its own prediction (no revival at prior-uptime); starvation (finding 3) explains the timelines without it. |

The corrected lesson is sharper than the original claim: **the port is faithful all the
way through the SoC glue** — the verification pyramid's blind spot is not our RTL but
*mid-run reset against live external devices*, a scenario no layer exercises (the
emulator has no reset input; cosim/formal/goldens all *start from* reset; and the one
external device with its own state, the HID bridge, exists only on the physical board).

## Fix directions (for the fix phase — decide there, measure first)

1. **Confirm the mechanism before coding**: instrument phantom generation (XLed with an
   event *counter* rather than a sticky bit; or an ILA on `msclk`/`msdat`) across a
   button press — transient burst vs. ongoing misparse decides between the options
   below.
2. **Gate the Mouse out of the button-reset domain** (keep it on POR only). One-line
   candidate fix; would be a *deliberate, documented departure* from `RISC5Top` —
   justified because our "mouse" is a bridge that mishandles mid-stream re-init, the
   exact thing the faithful reset wiring assumes works. Cheap to A/B-test.
3. **Harden instead of gate**: delay the post-reset re-init (reuse the POR counter on
   button resets too, giving the bridge a quiet window), or teach the init FSM to drain
   the line first.
4. Not needed: timer changes (faithful, free-running), EO-side `nextTime` patches (no
   rollback exists), cache/cellram reset changes (no evidence of memory-path fault —
   but if option 2 ever grows into a broader domain split, mind a CPU reset mid-PSRAM
   transaction: drain or quiesce before releasing the core).

## Open questions / next steps

- **Is PO also affected after a button press?** Compile `XLed.Mod` on the PO image,
  press reset, watch LD5. Decides whether the phantom window is universal (and merely
  masked by PO's slow reboot) or somehow EO-specific in timing.
- **Phantom persistence mechanism** — transient init-window misframing vs. lasting
  bridge mode mismatch (e.g. 3- vs 4-byte packet framing after the scroll-magic re-run).
  The event-counter instrument answers this.
- **The one cold boot**: a single press (first episode, 2026-07-04) full-rebooted —
  fresh 3-line log — requiring `LNK` = 0, which the RAM regfile and the clean 2-FF
  synchronizer make mysterious. Unreproduced across later presses (which warm-aborted,
  desktop preserved). Count warm vs. cold on future presses (warm = `ABORT` line in the
  *scrolled* log + desktop survives); if cold recurs, capture `LNK` (spare MMIO latch or
  a PROM LED breadcrumb distinguishing the two paths).
- Log-reading gotcha for all future sessions: Oberon's log viewer does **not**
  auto-scroll; evidence lines land below the visible fold. Scroll before concluding
  "nothing was printed."

## Acceptance test (after any fix)

`XLed.Mod` (below) lives on the EO disk image. Cursor inside its white frame drives a
track handler — the one code path proven to survive every failure mode here — that
mirrors the raw mouse register and clock onto LD0–7:

| LED | meaning |
|---|---|
| LD0/1/2 | live button bits MR/MM/ML from MMIO `-40` |
| LD3/LD4 | `Oberon.Time()` heartbeat (~4/2 Hz flicker while the clock runs) |
| LD5 | sticky latch: MR bit ever seen (clear: squeeze all three buttons) |
| LD6 | handler alive |

Pass criteria after a button press on a running EO: **LD5 stays dark** through wiggling
and middle-clicking inside the frame; `ABORT …` appended to the (scrolled) log; desktop
intact; serial wire answering within one poll period; `Hilbert.Draw` opens its viewer on
the first middle-click.

## Appendix: XLed.Mod

```oberon
MODULE XLed;
	IMPORT SYSTEM, Display, Viewers, Oberon, MenuViewers, TextFrames;

	CONST Menu = "System.Close System.Copy System.Grow";
		msAdr = -40; ledAdr = -60;

	TYPE Frame = POINTER TO FrameDesc;
		FrameDesc = RECORD (Display.FrameDesc) END ;

	VAR seenMR: BOOLEAN;

	PROCEDURE Upd;
		VAR m, k, t, led: INTEGER;
	BEGIN SYSTEM.GET(msAdr, m);
		k := m DIV 1000000H MOD 8;	(*keys: bit2=ML bit1=MM bit0=MR*)
		IF k = 7 THEN seenMR := FALSE	(*all three buttons: clear the latch*)
		ELSIF ODD(k) THEN seenMR := TRUE	(*latch: MR bit ever seen*)
		END ;
		t := Oberon.Time() DIV 256 MOD 4;	(*heartbeat: LD3 ~4Hz, LD4 ~2Hz*)
		led := k + t*8 + 40H;	(*LD6: handler alive*)
		IF seenMR THEN led := led + 20H END ;	(*LD5: MR latch*)
		SYSTEM.PUT(ledAdr, led)
	END Upd;

	PROCEDURE Restore(F: Frame);
	BEGIN Oberon.RemoveMarks(F.X, F.Y, F.W, F.H);
		Display.ReplConst(Display.white, F.X+1, F.Y, F.W-1, F.H, Display.replace)
	END Restore;

	PROCEDURE Handle(F: Display.Frame; VAR M: Display.FrameMsg);
		VAR F1: Frame;
	BEGIN
		CASE F OF Frame:
			CASE M OF
				Oberon.InputMsg:
					IF M(Oberon.InputMsg).id = Oberon.track THEN Upd;
						Oberon.DrawMouseArrow(M(Oberon.InputMsg).X, M(Oberon.InputMsg).Y)
					END
			| Oberon.CopyMsg: NEW(F1); F1^ := F^; M.F := F1
			| Viewers.ViewerMsg:
					IF M.id = Viewers.restore THEN Restore(F)
					ELSIF M.id = Viewers.modify THEN
						IF (M.Y # F.Y) OR (M.H # F.H) THEN F.Y := M.Y; F.H := M.H; Restore(F) END
					END
			END
		END
	END Handle;

	PROCEDURE Open*;
		VAR F: Frame; V: Viewers.Viewer; X, Y: INTEGER;
	BEGIN NEW(F); F.handle := Handle;
		Oberon.AllocateUserViewer(Oberon.Par.vwr.X, X, Y);
		V := MenuViewers.New(TextFrames.NewMenu("XLed", Menu), F, TextFrames.menuH, X, Y)
	END Open;

BEGIN seenMR := FALSE
END XLed.
```

## Evidence trail

- **EO abort at location 0**: extracted EO source (oberon-agent `build/eo/Oberon.Mod`,
  `Kernel.Install(SYSTEM.ADR(Abort), 0)`); exercised live over the serial wire — clean
  recovery, disk loads and viewer opens verified after.
- **Command veto guard**: EO `build/eo/TextFrames.Mod` middle-click dispatch (the
  `~(0 IN keysum)` cancel chord).
- **Task scheduling**: EO `build/eo/Oberon.Mod` `Install` (`nextTime := 0` on fresh
  install) + `Loop` (tasks only in the idle branch); `Kernel.Mod` `Time()` = raw MMIO
  read of the free-running counter.
- **PROM behavior**: `lib/rom.ml` image disassembled — LNK test words 342–344, `MOV
  R0,0; B R0` at 381–382, `LED(84H)` explaining the persistent LD2+LD7.
- **Reset fanout + free-running timer**: `test/_po/verilog/src/RISC5Top.OStation.v`
  lines 61–78 (rst to CPU, RS232R/T, SPI, PS2, MouseP), 137 (32 ms-aligned button
  sampling), 139–140 (unreset `cnt0`/`cnt1`); matched against `lib/soc.ml` and
  `boards/nexys-4/soc.ml`.
- **Mouse decoder spec**: `MousePM.v` — idle-gap packet framing (`endcount`), one-shot
  8-command init on reset release, `btns = {rx[1], rx[3], rx[2]}` mapping (PS/2 flags
  bit 1 = right = Oberon MR).
- **Phantom MR on silicon**: XLed LD5 latch lighting across a button press without the
  right button being pressed; middle-button (LD1) and heartbeat (LD3/4) normal.
- **Starvation timelines**: serial-wire monitor across two reset episodes — one answer
  at 16 s RT then permanent death (episode 1, cold); dead through active mouse use
  (episode 2, warm, desktop preserved); no revival after tens of idle minutes, killing
  the dormancy interpretation.
- **Regfile survives reset**: `lib/registers.ml` (`multiport_memory`, no reset term).
