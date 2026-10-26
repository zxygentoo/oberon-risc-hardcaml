(* The capture half of the core's co-simulation.

   The simulation SoC boots the real disk, and the core's inputs and outputs are recorded
   every cycle. core.cpp replays the trace through [RISC5.v] under Verilator and requires
   the same outputs, cycle for cycle, over a real workload.

   Why the first mismatch is exactly the divergence. Both cores start from the same reset
   state. [RISC5.v] is fed the inputs our core saw, and for as long as the outputs agree,
   memory — and with it the inputs, which are functions of memory — evolves identically on
   both sides. So the comparison is valid up to the first output mismatch, which is the
   first cycle on which our core did something [RISC5.v] would not: both in the same
   state, given the same instruction.

   The trace is one 17-byte little-endian record per cycle:
   - byte 0: rst_n | irq<<1 | stallX<<2 | rd<<3 | wr<<4 | ben<<5
   - bytes 1-4 and 5-8: codebus and inbus, the core's inputs, which drive [RISC5.v]
   - bytes 9-12 and 13-16: adr and outbus, the core's outputs, the values expected

   Environment: [DISK_IMG], [CORE_TRACE] (the output path), [CAP] (the cycle cap, 10 M by
   default); and for debugging, [CYC_FROM]/[CYC_TO] print pc, ir, flags and registers over
   a window, and [NOTRACE] skips writing the trace. *)

open Hardcaml
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

let getenv_int name ~default =
  match Sys.getenv_opt name with
  | Some s -> int_of_string s
  | None -> default
;;

(* ── env-driven configuration ───────────────────────────────────────────────── *)

type config =
  { disk_image : string (* DISK_IMG, else the vendored .dsk *)
  ; trace_path : string (* CORE_TRACE, else an in-repo test/_work default *)
  ; cap : int (* CAP — hard cycle cap *)
  ; cap_is_default : bool (* no CAP given: the coverage floor below is enforced *)
  ; spi_slow_div_log2 : int
      (* SPI_DIV_LOG2 — the SoC's slow SPI divider (default: turbo) *)
  ; cyc_from : int (* CYC_FROM/CYC_TO — inclusive windowed detailed-dump range *)
  ; cyc_to : int
  ; no_trace : bool (* NOTRACE — skip writing the (large) trace file *)
  }

let default_cap = 10_000_000

let read_config () =
  (* Boot.Disk.image already honors DISK_IMG and resolves from the project root *)
  let disk_image = Boot.Disk.image in
  let trace_path =
    match Sys.getenv_opt "CORE_TRACE" with
    | Some p -> p
    | None ->
      let dir = "test/_work/cosim/core" in
      ignore (Sys.command ("mkdir -p " ^ Filename.quote dir) : int);
      Filename.concat dir "core_boot.trace"
  in
  (* The capture checks the core, not the SPI master, so it boots with the fast divider:
     the handoff comes at about 1.9 M cycles instead of 7.6 M, and the rest of the default
     cap is OS initialisation — compiled Oberon code, where byte accesses, DIV, MUL and
     the shifts first appear (the boot loader is MOV, ADD, SUB, word loads and stores, and
     branches). *)
  { disk_image
  ; trace_path
  ; cap = getenv_int "CAP" ~default:default_cap
  ; cap_is_default = Option.is_none (Sys.getenv_opt "CAP")
  ; spi_slow_div_log2 = getenv_int "SPI_DIV_LOG2" ~default:2
  ; cyc_from = getenv_int "CYC_FROM" ~default:max_int
  ; cyc_to = getenv_int "CYC_TO" ~default:(-1)
  ; no_trace =
      (match Sys.getenv_opt "NOTRACE" with
       | Some _ -> true
       | None -> false)
  }
;;

(* ── simulator signal probes (the named regs/nodes/memory we read each cycle) ──── *)

type probes =
  { pc : Cyclesim.Reg.t
  ; ir : Cyclesim.Reg.t
  ; nf : Cyclesim.Reg.t
  ; zf : Cyclesim.Reg.t
  ; cf : Cyclesim.Reg.t
  ; ovf : Cyclesim.Reg.t
  ; irq : Cyclesim.Node.t (* the core's irq input *)
  ; stallx : Cyclesim.Node.t (* the core's stall_x input *)
  ; regfile : Cyclesim.Memory.t
  }

(* the SPI-side handles (rdy/spi_shreg/spi_ctrl) live in {!Boot.Tb.Spi} *)
let lookup_probes sim =
  let reg = Boot.Tb.lookup_reg sim
  and node = Boot.Tb.lookup_node sim in
  { pc = reg "pc"
  ; ir = reg "ir"
  ; nf = reg "n"
  ; zf = reg "z"
  ; cf = reg "c"
  ; ovf = reg "ov"
  ; irq = node "limit"
  ; stallx = node "vidreq"
  ; regfile = Boot.Tb.lookup_mem sim "regfile"
  }
;;

(* ── the per-cycle trace record (the 17-byte little-endian layout above) ──────── *)

let put_u32 buf off v =
  Bytes.set_uint8 buf off (v land 0xFF);
  Bytes.set_uint8 buf (off + 1) ((v lsr 8) land 0xFF);
  Bytes.set_uint8 buf (off + 2) ((v lsr 16) land 0xFF);
  Bytes.set_uint8 buf (off + 3) ((v lsr 24) land 0xFF)
;;

let encode_record buf ~ctrl ~codebus ~inbus ~adr ~outbus =
  Bytes.set_uint8 buf 0 ctrl;
  put_u32 buf 1 codebus;
  put_u32 buf 5 inbus;
  put_u32 buf 9 adr;
  put_u32 buf 13 outbus
;;

let b1 r = Bits.to_unsigned_int !r

(* optional windowed detailed state dump (env CYC_FROM/CYC_TO) — for zooming on a
   divergence: pc/ir/flags, the cycle's bus I/O, and the 16 registers *)
let dump_state (p : probes) ~cyc ~adr ~rd ~wr ~ben ~outbus ~inbus ~codebus =
  Printf.printf
    "cyc %d: pc=0x%05X ir=0x%08X N=%d Z=%d C=%d V=%d | adr=0x%06X rd=%d wr=%d ben=%d \
     out=0x%08X in=0x%08X code=0x%08X\n\
    \  regs:"
    cyc
    (Cyclesim.Reg.to_int p.pc)
    (Cyclesim.Reg.to_int p.ir)
    (Cyclesim.Reg.to_int p.nf)
    (Cyclesim.Reg.to_int p.zf)
    (Cyclesim.Reg.to_int p.cf)
    (Cyclesim.Reg.to_int p.ovf)
    adr
    rd
    wr
    ben
    outbus
    inbus
    codebus;
  for r = 0 to 15 do
    Printf.printf " R%d=0x%X" r (Cyclesim.Memory.to_int p.regfile ~address:r)
  done;
  Printf.printf "\n%!"
;;

(* ── the boot capture loop ──────────────────────────────────────────────────── *)

(* stop early if pc stays constant for [spin_limit] cycles: a core that is stuck. A
   healthy boot never does that, and any divergence comes before it, so it is in the
   trace. *)
let spin_limit = 4096

(* pc (a word address) below the reset vector's ROM window = running from RAM *)
let rom_base = Risc5.Cpu.start_adr
let lo = Bits.of_unsigned_int ~width:1 0
let hi = Bits.of_unsigned_int ~width:1 1

type result =
  { cycles : int
  ; final_pc : int
  ; pc_same : int (* trailing cycles pc held constant (>= spin_limit ⇒ halted) *)
  ; left_rom : bool (* pc reached low RAM — the OS handoff happened *)
  ; ben_cycles : int (* cycles with a byte access on the bus *)
  }

(* For each state: settle the combinational logic, record the inputs this state consumes
   and the outputs it drives, then take the edge and step the SD card. *)
let run
  ~cfg
  ~sim
  ~(inp : Bits.t ref Soc.I.t)
  ~(outp : Bits.t ref Soc.O.t)
  ~spi
  ~spi_bytes
  ~(probes : probes)
  ~oc
  =
  let buf = Bytes.create 17 in
  let cyc = ref 0
  and prev_pc = ref (-1)
  and pc_same = ref 0
  and left_rom = ref false
  and ben_cycles = ref 0
  and stop = ref false in
  while (not !stop) && !cyc < cfg.cap do
    (* drive [rst_n]: 0 for the first edge (reset → StartAdr), 1 thereafter. The recorded
       [rst_n] is the value applied for this state's edge; the replay drives it verbatim. *)
    let rst_n = if !cyc = 0 then 0 else 1 in
    inp.rst_n := if rst_n = 1 then hi else lo;
    Boot.Tb.Spi.set_miso spi;
    (* Record before the edge: the record is this state's outputs under this cycle's
       inputs. [outp] must be the before-edge port refs; the default after-edge refs are
       not refreshed here and would return the previous cycle's values. *)
    Cyclesim.cycle_before_clock_edge sim;
    let irq = Cyclesim.Node.to_int probes.irq
    and stallx = Cyclesim.Node.to_int probes.stallx
    and codebus = b1 outp.codebus
    and inbus = b1 outp.inbus
    and adr = b1 outp.adr
    and rd = b1 outp.rd
    and wr = b1 outp.wr
    and ben = b1 outp.ben
    and outbus = b1 outp.outbus in
    let ctrl =
      rst_n
      lor (irq lsl 1)
      lor (stallx lsl 2)
      lor (rd lsl 3)
      lor (wr lsl 4)
      lor (ben lsl 5)
    in
    ben_cycles := !ben_cycles + ben;
    encode_record buf ~ctrl ~codebus ~inbus ~adr ~outbus;
    if not cfg.no_trace then output_bytes oc buf;
    if !cyc >= cfg.cyc_from && !cyc <= cfg.cyc_to
    then dump_state probes ~cyc:!cyc ~adr ~rd ~wr ~ben ~outbus ~inbus ~codebus;
    (* this state's I/O is recorded — now take the edge (consuming the recorded
       codebus/inbus under the recorded rst) and re-settle for the post-edge reads below *)
    Cyclesim.cycle_at_clock_edge sim;
    Cyclesim.cycle_after_clock_edge sim;
    (* drive the SD bridge (post-cycle, like the visual golden) *)
    Boot.Tb.Spi.step spi;
    (* progress + halt detection *)
    let pc_now = Cyclesim.Reg.to_int probes.pc in
    if pc_now = !prev_pc then incr pc_same else pc_same := 0;
    prev_pc := pc_now;
    if pc_now < rom_base then left_rom := true;
    if !pc_same >= spin_limit then stop := true;
    incr cyc;
    if !cyc mod 1_000_000 = 0
    then
      Printf.printf
        "  @%2dM cyc: pc=0x%05X  spi_bytes=%d\n%!"
        (!cyc / 1_000_000)
        pc_now
        (spi_bytes ())
  done;
  { cycles = !cyc
  ; final_pc = !prev_pc
  ; pc_same = !pc_same
  ; left_rom = !left_rom
  ; ben_cycles = !ben_cycles
  }
;;

(* ── orchestration ──────────────────────────────────────────────────────────── *)

let () =
  let cfg = read_config () in
  (* boot + capture: SoC + the shared off-chip SD card *)
  let tmp = Boot.Disk.copy_to_temp cfg.disk_image in
  let bridge = Boot.Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~spi_slow_div_log2:cfg.spi_slow_div_log2 ~contents:Risc5.Rom.bootloader)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs ~clock_edge:Before sim in
  (* the SD bridge advances on the settled post-edge sclk, like every other boot gate *)
  let sclk_post = (Cyclesim.outputs sim).sclk in
  let spi = Boot.Tb.Spi.attach sim ~miso:inp.miso ~sclk:sclk_post bridge in
  let probes = lookup_probes sim in
  (* idle the released peripheral lines high; switches/buttons default 0 = disk boot *)
  inp.rxd := hi;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.msclk := hi;
  inp.msdat := hi;
  let oc = open_out_bin cfg.trace_path in
  Printf.printf
    "core_dump: booting %s\n  trace -> %s\n%!"
    (Filename.basename cfg.disk_image)
    cfg.trace_path;
  let result =
    run
      ~cfg
      ~sim
      ~inp
      ~outp
      ~spi
      ~spi_bytes:(fun () -> Boot.Sd_bridge.nbytes bridge)
      ~probes
      ~oc
  in
  close_out oc;
  Boot.Disk.rm_temp tmp;
  let bytes = result.cycles * 17 in
  Printf.printf
    "\n\
     done: %d cycles captured (%d bytes, %.1f MiB)\n\
     final pc=0x%05X (constant for last %d cyc%s)\n\
     trace: %s\n\
     %!"
    result.cycles
    bytes
    (float_of_int bytes /. 1024. /. 1024.)
    result.final_pc
    result.pc_same
    (if result.pc_same >= spin_limit then " — halted/stuck" else "")
    cfg.trace_path;
  Printf.printf
    "coverage: OS handoff %s; %d byte-access cycles\n%!"
    (if result.left_rom then "reached" else "NOT reached")
    result.ben_cycles;
  (* a trace that stopped on a stuck core, or (at the default cap) never left the boot
     ROM, must not replay as a pass *)
  if result.pc_same >= spin_limit
  then (
    prerr_endline "core_dump: FAIL — the core halted (pc stuck)";
    exit 1);
  if cfg.cap_is_default && not (result.left_rom && result.ben_cycles > 0)
  then (
    prerr_endline
      "core_dump: FAIL — the default capture must reach OS code (handoff + byte access)";
    exit 1)
;;
