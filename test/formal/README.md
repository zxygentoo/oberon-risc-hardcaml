# `test/formal` — proofs against the reference Verilog

Where [`test/cosim`](../cosim) simulates a unit against its reference `.v` and compares
samples, this directory *proves* the two equal: for every input, and from every state.
There are 17 checks. What they do not cover is listed in
[`docs/verification.md`](../../docs/verification.md).

## What is proven

| Check | Against | Method |
|---|---|---|
| `left_shifter`, `right_shifter` | `LeftShifter.v`, `RightShifter.v` | combinational: import and z3 |
| `multiplier`, `divider` | `Multiplier.v`, `Divider.v` | sequential: yosys induction |
| `fp_adder`, `fp_multiplier`, `fp_divider` | `FPAdder.v`, `FPMultiplier.v`, `FPDivider.v` | sequential |
| `rs232t`, `rs232r`, `spi`, `ps2` | `RS232T.v`, `RS232R.v`, `SPI.v`, `PS2.v` | sequential |
| `registers` | `proofs/registers_spec.v`, a specification written here | sequential |
| `core` | `RISC5.v`, with its eight units as black boxes | sequential, assume-guarantee |
| `mouse` | `MousePM.v`, through an open-drain shim | sequential |
| `vid` | `VID60.v`, around two deliberate departures | sequential, partial |
| `vid_invariant` | a property: one fetch request out for each one in | k-induction, yosys-smtbmc and z3 |
| `vid_addr` | a specification of the look-ahead address, written here | combinational: z3 |

The ALU has no `.v` of its own: `aluRes` is inline in `RISC5.v`, and it is proven there,
as part of `core`.

## The methods

### Combinational — `formal_equiv.ml`

```
ours: Risc5.Left_shifter (log_shift, radix-2) ─┐
                                               ├─ Sec.create → CNF → z3 → UNSAT = equivalent
LeftShifter.v (Wirth, radix-4 mux tree) ───────┘
```

- The reference `.v` is **imported** as a Hardcaml circuit by `hardcaml_of_verilog`
  (yosys). We drive yosys ourselves with `write_json -compat-int`, because yosys writes
  cell parameters as binary strings that the importer rejects, and feed the JSON in
  through the importer's public `Yosys_netlist.of_string`. No fork is needed (see
  `formal_equiv.ml`).
- `hardcaml_verify`'s `Sec` builds a miter and **z3** checks it. Only the port names
  have to match.

### Sequential — `yosys_equiv.ml`

```
ours: Risc5.Multiplier (S/P state) ─emit→ gate.v ─┐
                                                  ├─ equiv_make → equiv_induct → all $equiv proven
Multiplier.v (Wirth, 33-cycle shift-add) ─────────┘
```

`Sec` pairs registers by name, and through the import the registers come back renamed
and regrouped, so it cannot pair them. Instead our circuit is **emitted as Verilog** and
compared with the `.v` inside yosys: `equiv_make` pairs the flip-flops by name, and
`equiv_induct` proves the step by induction — from any state the two designs share, they
agree after one more clock, whatever the inputs. That covers all 33 cycles of the
multiplier at once; it is not a bounded trace. It is also a proof of the step only: it
does not start from reset, and it does not check which clock a register is on. It needs
only yosys, whose SAT solver is built in.

The requirement: port names *and register names* must be the reference's, so that the
state can be paired. That is why the sequential units in `lib/` name their registers
after the RTL (the multiplier's `S` and `P`), and why the runner builds each circuit with
the `.v`'s port names. Where a `lib/` register keeps another name, the proof renames it
in yosys (the `renames` of its row).

### Against a specification — the register file

```
ours: Risc5.Registers (one 16x32 array) ─emit→ gate.v ─┐
                                                       ├─ memory → equiv_make → equiv_induct ✓
registers_spec.v (behavioural: 16x32, 3R/1W) ──────────┘
```

`Registers.v` builds its three read ports from 64 bit-sliced, duplicated `RAM16X1D`
primitives: an idiom for getting a third asynchronous read port out of two-port LUT RAM.
Its state (1,024 bits, sliced and duplicated) has no correspondence with our one 16 × 32
array (512 bits) that `equiv_make` could pair, and a memory miter is not inductive on
outputs alone: a location nobody reads can differ in an unreachable state. Only a shallow
bounded check was tractable there. So `Registers` is proven against the contract
`Registers.v` implements (`registers_spec.v`: 16 words of 32 bits, three asynchronous
reads, one synchronous write). Both sides are then one array, which the `memory` pass
lowers to flip-flops that pair by name. That the `RAM16X1D` construction meets the same
contract is a matter between Wirth's Verilog and the synthesis tool.

### The core's glue — `core_blackbox.ml`, `proofs/core.ys.template`

```
RISC5.v (gold) ──────┐  8 units = black boxes on both sides (core_stubs.v)
                     ├─ equiv_make (merge units, check inputs) → cutpoint -blackbox
Cpu (gate) ──────────┘     → equiv_simple + equiv_induct → all $equiv proven
  via create_with_units (Core_blackbox.units = Instantiation stubs)
```

The whole core against `RISC5.v`, except its eight units, which are black boxes on both
sides and assumed equivalent (each is proven separately above: seven against their `.v`,
the register file against its contract). What remains, and what this proves, is the
glue: decode, the inline ALU, the control unit (`pcmux`, `cond`), the flag logic, and the
13 state registers (`PC`, `IR`, the flags, `H`, `stallL1`, the interrupt state).

The seam is `Cpu.create_with_units`. `Core_blackbox` passes it `Instantiation` stubs
whose module, instance, port and output-wire names are `RISC5.v`'s. The flow renames our
registers to the RTL's; `equiv_make` pairs the flip-flops and merges the matched
black-box cells, which also checks that both sides drive each unit's **inputs** alike;
`cutpoint -blackbox` then replaces the merged units by signals shared between the two
sides; `equiv_simple` and `equiv_induct` close what is left.

This is the standard assume-guarantee decomposition. Equal unit inputs (checked here)
give equal unit outputs (the units' own proofs), so the outputs can be one shared signal
on both sides. Some units are combinational through-paths — the shifters, the register
file's reads — but none sits on a combinational loop, so the argument is not circular.

Seeded bug: flipping one bit of the reset vector in our core leaves exactly two points
unproven, `PC[0]` and `adr[2]` (which is `PC << 2`). The proof catches a glue bug and
says where it is.

## The peripherals

The four single-clock peripherals with a `.v` of their own go through the sequential
recipe, one row each:

- `rs232t` — the register names already match (`run`, `tick`, `bitcnt`, `shreg`).
- `rs232r` — the synchroniser flops are renamed `q0→Q0`, `q1→Q1`. 30 cells.
- `spi` — `spi_shreg→shreg`. `rdy` is an `output reg` in the RTL; Hardcaml emits the
  flop under another name, and the two pair through the output port. 78 cells.
- `ps2` — `q0→Q0`, `q1→Q1`. The 16 × 8 `fifo` is lowered by the `memory` pass and pairs
  by name (128 of the 160 cells), as the register file does.

### The mouse — `proofs/mouse_shim.v`, `proofs/mouse.ys.template`

`MousePM.v`'s `MouseP` has open-drain `inout` lines. Our port splits each into a
drive-low output (`*_oe`) and an input carrying the resolved line. Two shims wrap both
sides into one interface whose external read is a **free input** and whose observable is
the **resolved line**, `oe ? 0 : ext`. The free input is essential: without it yosys ties
the `inout` read to 0, the state machine degenerates to constants, and the proof is
vacuous. The tristate is lowered with `tribuf -formal` (which also converts the drivers
of the `inout` port), `chformal -remove` (dropping the "no two drivers" assertion, which
open drain legitimately violates) and `setundef -one` (both sides released reads as the
pull-up). 160 cells. Seeded bugs in the state, in the `*_oe` drive and in the read of the
resolved line were each caught.

## Video

Video has two clock domains, and our port departs from `VID60.v` in two places on
purpose. A proof of the whole unit cannot close across either, so it is proven in parts.

The departures (see `lib/video.ml`):

1. **The fetch request's clock crossing.** `VID60.v` sets `req1` asynchronously. We use
   a toggle synchroniser, which is safe against metastability.
2. **The look-ahead fetch.** `VID60.v` requests the current group's word into one
   `vidbuf`. We request the *next* group's word, one group early, into two alternating
   buffers, which gives a slow memory a whole group of time to answer.

### `vid` — the raster and the pixel path

`proofs/vid.ys.template` drops `VID60.v`'s DCM and clock buffer (clock generation is the
board's job; `vid_stubs.v` gives their port shapes), exposes `pclk` as an input like
ours, and sets `RGBW=6`. It **cuts** `vidbuf` — the word the pixel shifter loads; on our
side the read mux of the two buffers, named `vidbuf` to pair with the RTL's register — to
a free input shared by both sides, and it removes the two departed outputs, `req` and
`vidadr`, from the comparison.

Proven: the raster (`hcnt`, `vcnt`, sync, blanking) and the pixel path (`pixbuf` to
`RGB`) equal `VID60.v`'s, *given the same fetched word*. Seeded bugs on the raster and on
the pixel path were caught.

### `vid_invariant` — the request crossing, as a property

The crossing is not an equivalence, but its protocol can be proven: **each `req0` in the
pixel domain yields exactly one `req` in the system domain; none is lost, none is
duplicated.** `video.ml`'s `pulse_sync` is a function of its own, so the harness
(`proofs/vid_invariant.v`) wraps the real emitted synchroniser with a generator of
`req0` pulses, an assumption that both clocks keep ticking, and a counter that balances
requests in against requests out.

It is proven by k-induction with `yosys-smtbmc` over z3 (`clk2fflogic` models the two
clocks): a base case from the initial state and the induction step, both at `k = 48`. No
inductive invariant had to be written by hand; `k` only has to span a fetch cycle (the
threshold is about 38), so that the history forces a reachable state. Seeded bug:
dropping the toggle is caught.

The proof's envelope is the harness's: a request every 8 pixel clocks, and the two clocks
within a ratio of 2:1, in any phase. That leaves at least 4 system clocks between
requests, just more than the three flops of the synchroniser. The machine's requests are
32 pixel clocks apart: about 12 system clocks at 25 MHz, 31 on the board. That the wider
spacing is covered by the narrower one is an argument, not part of the proof.

### `vid_addr` — the look-ahead address

`Video.lookahead`, with the raster counters as free inputs, is proven equal to a
specification of the address written from the screen's geometry (`vid_addr_spec` in
`formal_run.ml`), for every `(hcnt, vcnt)`, by z3. There is no `.v` to compare with:
`VID60.v`'s address is the current group's. The specification is written in a different
style (the column wraps by 5-bit arithmetic, the address is packed by shifts and adds),
so the proof is a cross-check and not a restatement. Seeded bug: dropping the `~` on the
row is caught.

### Delivery — what joins the three

`vid` shows the picture is right given the right word. *Delivery* is the claim that the
look-ahead supplies that word: the word loaded into `pixbuf` for the group at screen
position `(v, c)` is the one at `Org + {~v, c}`, which is what `VID60.v` fetches there.
It rests on three checked pieces and one argument by hand:

1. **Addressing** (`vid_addr`). The request that serves `(v, c)` is issued one group
   earlier (at column `c − 1`, or at column 31 of the line before when `c = 0`). It
   computes `vidadr = Org + {~v, c}` and writes buffer `c[0]`.
2. **Routing.** The buffer written is `c[0]` (above). The buffer read when `(v, c)` is
   loaded is `hcnt[5]`, which is `c[0]` at that moment. The same buffer.
3. **Arrival in time, and survival** (`vid_invariant`, plus a margin). Each request
   produces exactly one write pulse, in any phase. The time from fill to use is at least
   one group of 32 pixels (about 12 system clocks at 25 MHz; for `c = 0` and at the top
   of a frame, a whole blanking interval), well past the three-flop synchroniser, so the
   write lands before the use. Writes to one buffer are two groups apart, while the use
   is one group after the fill, so the next write to that buffer comes after the use:
   nothing overwrites the word in between, including across blanking, when no request
   fires at all.

**The joining argument.** The load for `(v, c)` reads buffer `c[0]` (2). By (1) the
request that filled it for this group asked for `Org + {~v, c}`. By (3) that write
happened once, before the load, and is still there. Hence the word loaded is the word at
`Org + {~v, c}`.

Pieces (1) and the write side of (2) are machine-checked over all `(hcnt, vcnt)`; the
read side of (2) is a bit identity; the phase-dependent half of (3) is machine-checked
over all phases. **Not mechanized**: the counting in (3) (the one-group window, the
two-group spacing) and the threading of one particular request to one particular load.
That is weaker than the core's decomposition, whose side condition is nearly mechanical.
A simulation test in `lib/video.ml` ("every column delivers its own word, across rows")
checks the assembled property at one clock phase, with a memory that echoes addresses,
over all 32 columns of two consecutive rows; another shows the one-group gap at the top
of the first frame healing itself.

**Why not one proof.** From fill to use the thread crosses blanking: for `c = 0` the
word is fetched at the end of the previous line (about 147 system clocks earlier), and
for the first group of a frame, at the end of the previous frame. One inductive proof
would have to carry the invariant "each buffer holds the word of the next group of its
parity" across that span. A prototype (the unit with an echo memory and a monitor, under
k-induction) is true on inspection — every counterexample starts from an unreachable
state — but the induction step fails for `k` from 96 to 140 and had not converged after
six minutes at `k = 256`. So the single deep proof is traded for three shallow ones and
the argument above.

## Seeded bugs

Each proof was run against a seeded bug when it was written: a one-line change to our
side, which must leave some point unproven. The cases are named in the sections above.
This was done by hand. `@formal` re-runs the proofs, not the mutations; there is no
mutation harness.

## The runner

Every proof that goes through yosys is one function, `Yosys_equiv.run_proof`, plus a
checked-in template in [`proofs/`](proofs) holding the yosys commands. `run_proof` emits
our circuit as Verilog, substitutes the placeholders into the template (paths, module
names, the rename block), writes the concrete script to
`test/_work/formal/<check>/proof.ys` — where it can be read and rerun — runs yosys, and
maps the exit code. A placeholder left unfilled raises. `sequential.ys.template` serves
the ten single-clock rows; `core`, `mouse`, `vid` and `vid_invariant` have their own.
The two z3 checks (`formal_equiv.ml`) use no yosys script.

## Running

Opt-in: it needs **yosys** and **z3** on `PATH`, and the `hardcaml_verify` and
`hardcaml_of_verilog` libraries.

```
dune build @formal                              # every check, in parallel
dune exec test/formal/formal_run.exe -- core    # one check, output on the terminal
dune exec test/formal/formal_run.exe -- all 4   # all, at most 4 at a time
```

`formal_run` changes to the repo root, checks for the tools, fetches the reference
Verilog and verifies its checksums ([`../fetch-rtl.sh`](../fetch-rtl.sh), shared with the
co-simulation), then runs the checks in a pool of forked workers, each in its own
`test/_work/formal/<check>/` with its output in `run.log`, and prints a PASS/FAIL
summary. yosys and z3 use a lot of memory, so the pool defaults to half the cores.

## Adding a check

In `formal_run.ml`:

- **Combinational**, with a `.v` and no state: a row in `combinational` — the circuit
  built with `Circuit.With_interface` (so the ports match the `.v`), the `.v`, its top
  module.
- **Sequential**: first make sure every register in the `lib/` module is *named* (an
  unnamed one gets a generated name that nothing can pair with). Then a row in
  `sequential`: the circuit built with `Circuit.create_exn` and the `.v`'s port names,
  under a module name different from the reference's (yosys reads both), and the
  `renames` from our register names to the RTL's, empty when they match.
- **Against a specification**, for a unit whose RTL is a synthesis idiom: a `*_spec.v`
  in `proofs/` and a row in `behavioral`.
- **Something else** gets its own runner and its own template. The existing ones are the
  patterns: `run_core` (black boxes and `cutpoint`), `run_mouse` (the open-drain shim),
  `run_vid` (two clocks, a cut and removed outputs), `run_vid_invariant` (a property:
  the template emits an SMT problem, and `~smtbmc` runs the induction), `run_vid_addr`
  (two Hardcaml circuits under `Formal_equiv.check_circuits`).

Then try it once against a seeded bug.
