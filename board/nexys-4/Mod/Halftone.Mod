MODULE Halftone; (*the display mode's Oberon face (seam spec: ABI.md §11 in the
  sibling DOOM-on-Oberon repo). The hardware is pure mechanism: an 8bpp pixel window scanned
  out to a word-aligned panel rectangle through a tone LUT, a 64x64 threshold map, a
  768-entry row map and a horizontal DDA — every table and register CLIENT-uploaded.
  This module is the thin system service any Oberon program uses to put grayscale
  pixels on the 1-bit panel: Claim, then three calls (Open + LinearRows, Bayer8,
  ToneIdentity, On) get a working window; Release when done. DOOM's blob keeps
  talking raw MMIO per its own seam (AGENT.md paragraph 5, blob-talks-MMIO);
  Mandel.Mod is this module's first client.

  SINGLE OWNER, enforced at CONSUMER lifetime: there is exactly one rect in
  hardware, so a client CLAIMS it for as long as it lives — Claim when your viewer
  opens or your command starts (FALSE = another consumer lives: report, and let the
  user exit the current consumer before opening the next), Release when it closes.
  Between the two the window is yours through suspend and resize alike — Open
  (re)shapes the rect, Off blanks the picture while covered, and the tables never
  change hands, which is what makes a client's one-time uploads safe. Open refuses
  when NO claim is live (a forgot-to-Claim client fails loudly), but it cannot tell
  owners apart: cross-client exclusion is Claim's alone. Release is parameterless
  on purpose — as a command, a middle-click on Halftone.Release frees a claim
  wedged by a client that died without releasing.

  Geometry registers are SHADOWED in hardware and latch at vblank entry, so Open
  never tears mid-frame; the tables (thresholds, row map, tone) are LIVE — rewrite
  them inside Sync's vblank window (~600 us) or with the mode off. Mode-on with
  zeroed tables scans all-zero thresholds (every non-black pixel white): upload
  first. The status word (MMIO 0FFFFE8H, slot 10) is the machine's frame clock:
  bit 0 = vblank, bits 15..8 = frame counter.*)

  IMPORT SYSTEM;

  CONST
    base* = 310000H;    (*the pixel window: 64000 bytes, layout defined by the row map*)
    lutAdr = 31FA00H;   (*tone LUT: 256 bytes, pixel byte -> 8-bit gray*)
    ctlAdr = 31FB00H;   (*CTL word (bit 0 = mode, immediate) + geometry shadows at +4..+28*)
    thrAdr = 30E000H;   (*threshold map: 64x64 bytes row-major, verbatim, values 1..254*)
    mapAdr = 30F000H;   (*row map: 768 words {thrRow[21:16], rowBase[15:0]}, word stores*)
    statusAdr = -24;    (*MMIO slot 10 = 0FFFFE8H: bit 0 vblank, bits 15..8 frame counter*)

  VAR claimed: BOOLEAN;  (*a live consumer: the Claim .. Release bracket*)

  PROCEDURE Claim*(): BOOLEAN;
  (*take the rect for this consumer's whole lifetime — a viewer from open to close,
    or one command; FALSE = another consumer lives (report; the user exits it first)*)
    VAR ok: BOOLEAN;
  BEGIN
    ok := ~claimed;
    IF ok THEN claimed := TRUE END ;
    RETURN ok
  END Claim;

  PROCEDURE Release*;  (*mode off + the rect freed. Parameterless on purpose: as a
    command, it recovers a claim wedged by a client that died without releasing*)
  BEGIN SYSTEM.PUT(ctlAdr, 0); claimed := FALSE
  END Release;

  PROCEDURE Open*(x, y, w, h, xnum, xden, xoff: INTEGER): BOOLEAN;
  (*(re)shape the rect — legal only inside your claim: panel px, x and w multiples of
    32 (the hardware muxes whole fb words); horizontal scale xnum/xden >= 1 (the DDA
    advances the source at most one byte per output pixel); xoff = starting source
    byte column. Takes effect at the next vblank entry (call Sync to wait for it).
    FALSE = rejected (bad geometry, or no claim is live — Claim first), nothing
    written.*)
    VAR ok: BOOLEAN;
  BEGIN
    ok := claimed
        & (x MOD 32 = 0) & (w MOD 32 = 0) & (w > 0) & (h > 0)
        & (x >= 0) & (y >= 0) & (x + w <= 1024) & (y + h <= 768)
        & (xden >= 1) & (xnum >= xden) & (xnum < 4096) & (xoff >= 0) & (xoff < 10000H);
    IF ok THEN
      SYSTEM.PUT(ctlAdr + 4, x); SYSTEM.PUT(ctlAdr + 8, y);
      SYSTEM.PUT(ctlAdr + 12, w); SYSTEM.PUT(ctlAdr + 16, h);
      SYSTEM.PUT(ctlAdr + 20, xnum); SYSTEM.PUT(ctlAdr + 24, xden);
      SYSTEM.PUT(ctlAdr + 28, xoff)
    END ;
    RETURN ok
  END Open;

  PROCEDURE MapRow*(y, rowBase, thrRow: INTEGER);
  (*row map entry: rect-relative output row y scans source bytes at window offset
    rowBase, thresholded by map row thrRow (0..63)*)
  BEGIN SYSTEM.PUT(mapAdr + 4 * y, LSL(thrRow MOD 64, 16) + rowBase MOD 10000H)
  END MapRow;

  PROCEDURE LinearRows*(srcH, stride, h: INTEGER);
  (*deal srcH source rows (stride bytes apart, from window offset 0) over h output
    rows — Bresenham, works scaled up or down — with per-output threshold rows
    (thrRow = y MOD 64, the finest dithering). Any other vertical policy (out2
    dealing, double-buffer flip, interleave) is a client loop over MapRow.*)
    VAR sy, y, acc: INTEGER;
  BEGIN y := 0; acc := 0;
    FOR sy := 0 TO srcH - 1 DO
      acc := acc + h;
      WHILE acc >= srcH DO acc := acc - srcH;
        MapRow(y, sy * stride, y MOD 64); INC(y)
      END
    END
  END LinearRows;

  PROCEDURE SetTone*(VAR t: ARRAY OF BYTE);  (*256 entries: pixel byte -> gray*)
    VAR i: INTEGER;
  BEGIN
    FOR i := 0 TO 255 DO SYSTEM.PUT(lutAdr + i, t[i]) END
  END SetTone;

  PROCEDURE ToneIdentity*;  (*pixel byte IS the gray value — the grayscale framebuffer*)
    VAR i: INTEGER; c: CHAR;
  BEGIN
    FOR i := 0 TO 255 DO c := CHR(i); SYSTEM.PUT(lutAdr + i, c) END
  END ToneIdentity;

  PROCEDURE SetThresholds*(VAR m: ARRAY OF BYTE);  (*64x64 row-major, values 1..254*)
    VAR i: INTEGER;
  BEGIN
    FOR i := 0 TO 4095 DO SYSTEM.PUT(thrAdr + i, m[i]) END
  END SetThresholds;

  PROCEDURE Bayer8*;  (*a computed Bayer 8x8, tiled — the sensible default rendition*)
    VAR bay: ARRAY 8, 8 OF INTEGER;
      n, i, j, v, x, y: INTEGER; c: CHAR;
  BEGIN
    (*the classic recursive doubling: M(2n)[q] = 4*M(n) + (0|2|3|1) by quadrant*)
    bay[0, 0] := 0; n := 1;
    WHILE n < 8 DO
      FOR i := 0 TO n - 1 DO
        FOR j := 0 TO n - 1 DO
          v := bay[i, j];
          bay[i, j + n] := 4 * v + 2;
          bay[i + n, j] := 4 * v + 3;
          bay[i + n, j + n] := 4 * v + 1;
          bay[i, j] := 4 * v
        END
      END ;
      n := 2 * n
    END ;
    FOR y := 0 TO 63 DO
      FOR x := 0 TO 63 DO
        c := CHR(bay[y MOD 8, x MOD 8] * 4 + 2);  (*0..63 -> 2..254*)
        SYSTEM.PUT(thrAdr + 64 * y + x, c)
      END
    END
  END Bayer8;

  PROCEDURE On*;
  BEGIN SYSTEM.PUT(ctlAdr, 1)
  END On;

  PROCEDURE Off*;  (*mode off, claim KEPT — blank the picture while suspended; the
    desktop was under us all along, restore is instant*)
  BEGIN SYSTEM.PUT(ctlAdr, 0)
  END Off;

  PROCEDURE Frame*(): INTEGER;  (*the free-running 8-bit frame counter*)
    VAR s: INTEGER;
  BEGIN SYSTEM.GET(statusAdr, s);
    RETURN ASR(s, 8) MOD 100H
  END Frame;

  PROCEDURE Sync*;
  (*wait for the next vblank ENTRY — the edge that latches Open's geometry; the
    ~600 us blanking window that follows is the safe slot for table rewrites*)
    VAR s: INTEGER;
  BEGIN
    REPEAT SYSTEM.GET(statusAdr, s) UNTIL ~ODD(s);
    REPEAT SYSTEM.GET(statusAdr, s) UNTIL ODD(s)
  END Sync;

BEGIN claimed := FALSE
END Halftone.
