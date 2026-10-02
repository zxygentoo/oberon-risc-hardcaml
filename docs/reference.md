# Reference

The facts the port is built on: the Verilog it follows, the instruction set, the memory
map, how the core behaves cycle by cycle, and the places where the emulator and the
Verilog disagree.

## The reference Verilog

The port follows `OStationVerilog.zip` (rev. 2015/2018, N. Wirth / P. Reed). The archive
is not ours to redistribute, so it is not in the repo: `test/fetch-rtl.sh` fetches it on
demand into `test/_po/verilog/src/`, and `test/rtl-sources.txt` pins every file by
checksum. A mismatch means upstream has drifted from the revision the port was verified
against (the line numbers below refer to that revision); updating a pin is a deliberate
edit of that file.

| File | What it is | Notes |
|---|---|---|
| `RISC5.v` (184 lines) | the CPU core | one instruction at a time, mostly one cycle; multi-cycle units stall it; interrupts |
| `RISC5Top.OStation.v` | the original SoC | our reference for the MMIO map; our two SoCs are their own designs |
| `Registers.v` | the register file, three read ports | built from `RAM16X1D` primitives; we infer an array instead |
| `Multiplier.v`, `Divider.v` | iterative multiply and divide | 33 cycles, a state counter and `stall` |
| `LeftShifter.v`, `RightShifter.v` | barrel shifters | combinational; the right shifter does ASR and ROR |
| `FPAdder.v` (132 lines) | FP add and subtract, and FLT and FLOOR | a three-state pipeline |
| `FPMultiplier.v`, `FPDivider.v` | iterative FP multiply and divide | 25 and 26 cycles |
| `PROM.v` | the boot ROM, 512 × 32 | the image in the design (`Risc5.Rom`) is the emulator's boot loader, which is not the archive's `prom.mem`: see `lib/rom.mli` |
| `RS232R.v`, `RS232T.v` | UART receive and transmit | |
| `SPI.v` | the SPI master (SD card, network) | |
| `VID60.v` | video, 1024 × 768 × 1, read from RAM by DMA | drives `stallX` on the core |
| `PS2.v`, `MousePM.v` | PS/2 keyboard and mouse | |

Wirth's own write-ups are on projectoberon.net, the archive's host: `RISC-Arch.pdf` (the
instruction encoding), `RISC.pdf` (the design of the CPU), `PO.Computer.pdf` (the board
and the SoC).

## The instruction set

Fields of the instruction register, as `RISC5.v` names them:

```
p = IR[31]   q = IR[30]   u = IR[29]   v = IR[28]
a = IR[27:24]   b = IR[23:20]   op = IR[19:16]   c = IR[3:0]
imm = IR[15:0]   off = IR[19:0]   disp = IR[21:0]   cc = IR[26:24]
```

**Register instructions** (`p = 0`). The second operand is `R.c` when `q = 0`, and the
immediate `imm`, extended with sixteen copies of `v`, when `q = 1`. The result goes to
`R.a` and sets N and Z; ADD and SUB also set C and V.

```
0 MOV   1 LSL   2 ASR   3 ROR   4 AND   5 ANN   6 IOR   7 XOR
8 ADD   9 SUB  10 MUL  11 DIV  12 FAD  13 FSB  14 FML  15 FDV
```

With the modifier `u` set: `ADD'` and `SUB'` add and subtract the carry C; `MUL'` is
unsigned; `MOV'` with `q = 0, v = 0` reads `H`; with `q = 0, v = 1` it reads the flags
word `[N, Z, C, V]` (low byte `0x53`); with `q = 1` it loads `imm << 16`. `H` holds the
high word of a product and the remainder of a division.

**Memory instructions** (`p = 1, q = 0`). `u = 0` loads `R.a := Mem[R.b + off]`; `u = 1`
stores. `v = 0` is a word, `v = 1` a byte. `off` is 20 bits, signed.

**Branches** (`p = 1, q = 1`). The target is `R.c` when `u = 0` and `PC + 1 + disp` when
`u = 1`; `v = 1` links `PC + 1` into `R15`. The condition `cc` is negated when
`IR[27] = 1`:

```
0 MI (N)   1 EQ (Z)   2 CS (C)   3 VS (V)   4 LS (C|Z)   5 LT (N≠V)   6 LE ((N≠V)|Z)   7 always
```

`RTI` is `1100 0111 … 0001 Rn`. `STI` and `CLI` are `1100 1111 … 0010 000e`, which sets
the interrupt enable to `e`.

**Reset.** `rst` is active low and loads the PC with `StartAdr = 0x3FF800`, a word
address: the start of the ROM.

## The memory map

Addresses are byte addresses on a 24-bit bus.

| Region | Where | Notes |
|---|---|---|
| RAM | `0` .. `0x0FFFFF` | 1 MiB. `RISC5.v` decodes a 20-bit window, so higher addresses alias into it |
| framebuffer | `0x0E7F00` .. `0x0FFEFF` | inside the RAM: 1 bit per pixel, 32 pixels per word, bit 0 leftmost, the bottom scan line at the lowest address |
| boot ROM | fetches with `adr[23:14] = 0x3FF` | the top 16 KiB; the image is 512 words from `0xFFE000` |
| MMIO | `0xFFFFC0` .. `0xFFFFFF` | sixteen words; loads with `adr[23:6] = 0x3FFFF` |

The MMIO words (word *n* is at `0xFFFFC0 + 4n`):

| Word | Read | Write |
|---|---|---|
| 0 | the millisecond counter | |
| 1 | buttons and switches | the LED latch |
| 2 | UART: the received byte | UART: transmit a byte |
| 3 | UART status, `{rdyTx, rdyRx}` | UART: the rate bit |
| 4 | SPI: the received data | SPI: data, starts a transfer |
| 5 | SPI: `rdy` | SPI: the control register |
| 6 | `{keyboard ready, mouse state}` | |
| 7 | a keyboard byte (and pops its FIFO) | |
| 8 | GPIO: the pins | GPIO: the drive value |
| 9 | GPIO: the direction | GPIO: the direction |
| 10 | board only: Halftone's status (`0xFFFFE8`) | |
| 11–15 | 0 | |

**On the board** the data decode is the full 24 bits, onto the 16 MiB PSRAM, and the
emulator matches it at 16 MiB. The memory from 1 MiB up holds Halftone's two windows —
tables at `0x30E000` (8 KiB), pixels at `0x310000` (64 KiB), see
`board/nexys-4/halftone.mli` — and DOOM's code and data. On the board an MMIO store goes
only to its peripheral; in the original, and in `Risc5.Soc`, it also lands in the aliased
RAM word, which Oberon never reads back.

## How the core behaves

Facts about `RISC5.v` that the port mirrors and that tests and tools rely on:

- **The register file** reads asynchronously (data follows the read address in the same
  cycle) and writes on the clock. It has three read ports; port 0's address is also the
  write address, and it is 15 for a branch, which is how a branch links into `R15`.
- **A stall freezes PC and IR.** A multi-cycle unit holds `stall` until its state counter
  reaches its last state: MUL and DIV `S = 33`, the FP adder `State = 3`, the FP
  multiplier `S = 25`, the FP divider `S = 26`. A load or store takes one extra cycle
  (`stallL`). `stallX` is the external stall, which the video DMA drives.
- **Interrupts.** `intAck = intPnd & intEnb & ~intMd & ~stall`. The vector is word
  address 1. `SPC` saves the flags and the return address, and `RTI` restores them.
  `STI` and `CLI` set `intEnb`.
- **The second ALU operand** `C1` is the extended immediate when `q = 1` and `R.c`
  otherwise. A byte access uses `ben` to select the byte lane on the way in and to
  replicate the byte on the way out.
- **C and V are clocked on every cycle an ADD or SUB sits in IR**, stalled or not
  (`RISC5.v:161-175`); only N and Z wait for the register write. For plain ADD and SUB
  that is harmless. `ADD'` and `SUB'` take C as their carry-in, so one held by `stallX`
  consumes its own carry-out. The board never asserts `stallX`: it freezes the whole core
  by its clock enable instead.

## Where the emulator and `RISC5.v` differ

The port follows the Verilog in every case, and the co-simulation and the proofs hold it
there. The emulator is still the oracle for results, so the single-instruction lockstep
has to know each difference. None of them can be reached from compiled Oberon.

| Case | `RISC5.v` | The emulator | In the lockstep |
|---|---|---|---|
| `ADD'`/`SUB'` with carry-in and a second operand of `0xFFFFFFFF` | C and V from the real sign bits (lines 161–166) | C by comparison (`s < b`), wrong in this corner | skipped |
| high word of an unsigned `MUL'` when the second operand has bit 31 set | the multiplier sign-extends its second operand always (`Multiplier.v:16`); `u` only changes the first operand's sign, so `H` is `B` unsigned × `C1` signed | `B` unsigned × `C1` unsigned | everything but `H` is compared with the emulator; `H` with the hardware's definition |
| `DIV` with a divisor ≤ 0 | undefined: `Divider.v` requires `y > 0` | some result | skipped. The compiler rejects such a constant and traps on a variable |
| branch-and-link through `R15` | jumps to the old `R15` (asynchronous read, the link is written on the same edge) | links first, then jumps to the link | discarded. The compiler never calls through the link register |
| `ADD'`/`SUB'` held by a stall | consumes its own carry-out (above) | executes each instruction once | those cycles are never stalled; the core proof holds the port to the RTL there |
| FLT and FLOOR, denormalizing a negative operand with a zero mantissa | the shift fills with the operand's sign bit (`FPAdder.v`) | shifts the two's-complement value | FP operations are forced to their register form; the FP tests replay only what the compiler can emit |
| code addresses while running from ROM | ROM at word `0x3FF800` | ROM at word `0x3FFFFE00` (byte `0xFFFFF800`) | see below |

Notes:

- **FLT and FLOOR.** The compiler (`ORG.Mod`, `Float` and `Floor`) always supplies
  `0x4B000000` (2^23) as the second operand, and with it the divergent shift cannot
  occur. The port was checked bit for bit against `FPAdder.v` over 26,000 stimuli,
  divergent forms included.
- **Code addresses.** The emulator decodes 32 address bits and keeps its ROM at another
  base, so while the boot loader runs, `pc` and the links in `R15` and on the stack
  differ from the hardware's by a constant. Data addresses and all code in RAM are
  identical, so the difference disappears once the OS runs. That is why a boot is checked
  by its end states and not instruction by instruction: at the handoff, one register and
  seven stack words carry the offset, and the comparison allows exactly that.
- **The flags word** is not a difference any more. `MOV'` with `v = 1` reads
  `{N, Z, C, V, 20'b0, 8'h53}` (`RISC5.v:113`), and the OCaml and Rust emulators return
  `0x53` too. Only the C emulator they descend from (`pdewacht/oberon-risc-emu`) still
  returns `0xD0`.
- A new difference goes into the table, with what the lockstep does about it. The Rust
  port's `DIVERGENCES.md` keeps the longer record.
