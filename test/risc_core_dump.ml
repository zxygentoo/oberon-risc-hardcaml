(* Boot-stream RTL co-sim — capture half (AGENT.md §6 layer 3, for the CPU core).

   Boot the SoC from the real disk and record the CPU core's per-cycle I/O to a trace,
   which [test/cosim/core.cpp] replays through the reference [RISC5.v] under Verilator to
   assert the core is cycle-exact to the spec across a real workload — the core's only
   cycle-level RTL check before the Phase-8 equivalence proof (the unit co-sims cover the
   peripherals and FP units; this covers the whole core over a boot).

   Why a captured boot trace pins any divergence exactly. Both our core and [RISC5.v]
   start from the same reset state (the regfile inits to 0 on both sides). Feed [RISC5.v]
   the identical per-cycle core inputs ([rst]/[irq]/[stallX]/[codebus]/[inbus]) our core
   saw, and as long as our outputs match the spec's, memory — hence the inputs, which are
   functions of memory — evolves identically on both sides. So the comparison stays valid
   right up to the FIRST output mismatch, which is therefore the first cycle our core did
   something [RISC5.v] wouldn't; there both cores are in identical state fed an identical
   instruction — a minimal reproducer. (This is how the phase-6b ALU flag-leak — a branch
   with op-field 8 clobbering C — was found and the fix verified.)

   Trace format — one fixed 17-byte little-endian record per cycle:
   - byte 0: control = rst_n | irq<<1 | stallX<<2 | rd<<3 | wr<<4 | ben<<5
   - bytes 1-4 / 5-8: codebus / inbus (u32) — core INPUTS, drive RISC5.v
   - bytes 9-12 / 13-16: adr / outbus (u32) — core OUTPUTS, the expected values

   Boot machinery = the visual golden's [boot_soc] (SoC + the shared {!Sd_bridge} SD
   card), trimmed to the capture. Opt-in (run via the cosim runner, cosim_run); needs the
   disk image. Env: [DISK_IMG] (default the vendored .dsk), [CORE_TRACE] (output path),
   [CAP] (hard cycle cap, default 2_000_000); for ad-hoc debugging, [CYC_FROM]/[CYC_TO]
   print a windowed pc/ir/flags/regs dump and [NOTRACE] skips writing the (large) trace
   file. *)

open Hardcaml
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

(* ── repo root + disk plumbing ──────────────────────────────────────────────── *)

(* nearest ancestor holding a dune-project — to resolve the default disk image absolutely
   (mirrors test_visual_golden) *)
let project_root () =
  let rec up dir =
    if Sys.file_exists (Filename.concat dir "dune-project")
    then dir
    else (
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then failwith "risc_core_dump: no dune-project found above cwd"
      else up parent)
  in
  up (Sys.getcwd ())
;;

(* boot off a scratch copy so a crash/abort can never corrupt the vendored .dsk *)
let copy_to_temp src =
  let tmp = Filename.temp_file "core_trace_" ".dsk" in
  let ic = open_in_bin src
  and oc = open_out_bin tmp in
  output_string oc (really_input_string ic (in_channel_length ic));
  close_in ic;
  close_out oc;
  tmp
;;

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
  ; cyc_from : int (* CYC_FROM/CYC_TO — inclusive windowed detailed-dump range *)
  ; cyc_to : int
  ; no_trace : bool (* NOTRACE — skip writing the (large) trace file *)
  }

let read_config () =
  let disk_image =
    match Sys.getenv_opt "DISK_IMG" with
    | Some p -> p
    | None ->
      Filename.concat
        (project_root ())
        "vendor/oberon-risc-emu-ocaml/DiskImage/Oberon-2020-08-18.dsk"
  in
  let trace_path =
    match Sys.getenv_opt "CORE_TRACE" with
    | Some p -> p
    | None ->
      (* Self-contained in-repo default (git-ignored test/_work), matching cosim_run; the
         normal entry points pass an explicit CORE_TRACE into test/_work anyway. *)
      let dir = "test/_work/cosim/core" in
      ignore (Sys.command ("mkdir -p " ^ Filename.quote dir) : int);
      Filename.concat dir "core_boot.trace"
  in
  (* Cycle-fidelity is a spot-check, not a full boot (boot_checkpoint / visual_golden own
     boot correctness): the default ~2M cycles covers reset + ROM init + a solid run of
     the SD-load driver — a real instruction stream exercising
     decode/control/stall/flags/branch/byte-mem — at a small fraction of the full-boot
     time/trace. Raise CAP to replay deeper (handoff is ~8M, the inner core 8M+). *)
  { disk_image
  ; trace_path
  ; cap = getenv_int "CAP" ~default:2_000_000
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
  ; rdy : Cyclesim.Reg.t
  ; shreg : Cyclesim.Reg.t
  ; spi_ctrl : Cyclesim.Reg.t
  ; irq : Cyclesim.Node.t (* the core's irq input *)
  ; stallx : Cyclesim.Node.t (* the core's stall_x input *)
  ; regfile : Cyclesim.Memory.t
  }

let lookup_probes sim =
  let some n = function
    | Some x -> x
    | None -> failwith ("risc_core_dump lookup: " ^ n)
  in
  let reg n = some n (Cyclesim.lookup_reg_by_name sim n) in
  let node n = some n (Cyclesim.lookup_node_or_reg_by_name sim n) in
  { pc = reg "pc"
  ; ir = reg "ir"
  ; nf = reg "n"
  ; zf = reg "z"
  ; cf = reg "c"
  ; ovf = reg "ov"
  ; rdy = reg "rdy"
  ; shreg = reg "spi_shreg"
  ; spi_ctrl = reg "spi_ctrl"
  ; irq = node "limit"
  ; stallx = node "vidreq"
  ; regfile = some "regfile" (Cyclesim.lookup_mem_by_name sim "regfile")
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

(* stop early if pc stays constant for [spin_limit] cycles — a halted/stuck core (e.g. a
   trap abort spin). Healthy boots never do (the idle loop oscillates), so this only fires
   on a fault, and any first divergence is BEFORE it, hence contained in the trace. *)
let spin_limit = 4096
let lo = Bits.of_unsigned_int ~width:1 0
let hi = Bits.of_unsigned_int ~width:1 1

type result =
  { cycles : int
  ; final_pc : int
  ; pc_same : int (* trailing cycles pc held constant (>= spin_limit ⇒ halted) *)
  }

(* Drive + capture each state, then take the edge: settle the combinational cloud over the
   CURRENT state, record (the inputs this state consumes, the outputs it drives), then
   clock to the next state and step the SD bridge. Returns the final progress stats for
   the summary. *)
let run
  ~cfg
  ~sim
  ~(inp : Bits.t ref Soc.I.t)
  ~(outp : Bits.t ref Soc.O.t)
  ~bridge
  ~(probes : probes)
  ~oc
  =
  let buf = Bytes.create 17 in
  let cyc = ref 0
  and prev_pc = ref (-1)
  and pc_same = ref 0
  and stop = ref false in
  while (not !stop) && !cyc < cfg.cap do
    (* drive [rst_n]: 0 for the first edge (reset → StartAdr), 1 thereafter. The recorded
       [rst_n] is the value applied for this state's edge; the replay drives it verbatim. *)
    let rst_n = if !cyc = 0 then 0 else 1 in
    inp.rst_n := if rst_n = 1 then hi else lo;
    inp.miso := if Sd_bridge.miso bridge = 1 then hi else lo;
    (* Record PRE-edge: settle the combinational cloud over the CURRENT state (registers
       not yet updated), so each record is (inputs this state consumes, outputs this state
       drives) and the edge below transitions to the next state. Pre-edge is what keeps
       the trace self-consistent across the rst 0→1 reset boundary: the codebus consumed
       at the first rst=1 edge (the branch-TARGET instruction) is captured here; a
       post-edge read would record the fetch AFTER it instead and lose it, desyncing the
       replay by one instruction whenever the boot's first instruction is a taken branch
       (which it is). *)
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
    encode_record buf ~ctrl ~codebus ~inbus ~adr ~outbus;
    if not cfg.no_trace then output_bytes oc buf;
    if !cyc >= cfg.cyc_from && !cyc <= cfg.cyc_to
    then dump_state probes ~cyc:!cyc ~adr ~rd ~wr ~ben ~outbus ~inbus ~codebus;
    (* this state's I/O is recorded — now take the edge (consuming the recorded
       codebus/inbus under the recorded rst) and re-settle for the post-edge reads below *)
    Cyclesim.cycle_at_clock_edge sim;
    Cyclesim.cycle_after_clock_edge sim;
    (* drive the SD bridge (post-cycle, like the visual golden) *)
    let ctrl_v = Cyclesim.Reg.to_int probes.spi_ctrl in
    Sd_bridge.step
      bridge
      ~sclk:(b1 outp.sclk)
      ~rdy:(Cyclesim.Reg.to_int probes.rdy)
      ~data_tx:(Cyclesim.Reg.to_int probes.shreg)
      ~fast:((ctrl_v lsr 2) land 1 = 1)
      ~selected:(ctrl_v land 3 = 1);
    (* progress + halt detection *)
    let pc_now = Cyclesim.Reg.to_int probes.pc in
    if pc_now = !prev_pc then incr pc_same else pc_same := 0;
    prev_pc := pc_now;
    if !pc_same >= spin_limit then stop := true;
    incr cyc;
    if !cyc mod 1_000_000 = 0
    then
      Printf.printf
        "  @%2dM cyc: pc=0x%05X  spi_bytes=%d\n%!"
        (!cyc / 1_000_000)
        pc_now
        (Sd_bridge.nbytes bridge)
  done;
  { cycles = !cyc; final_pc = !prev_pc; pc_same = !pc_same }
;;

(* ── orchestration ──────────────────────────────────────────────────────────── *)

let () =
  let cfg = read_config () in
  (* boot + capture: SoC + the shared off-chip SD card *)
  let tmp = copy_to_temp cfg.disk_image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Risc5.Rom.bootloader)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let probes = lookup_probes sim in
  (* idle the released peripheral lines high; switches/buttons default 0 = disk boot *)
  inp.rxd := hi;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.msclk := hi;
  inp.msdat := hi;
  let oc = open_out_bin cfg.trace_path in
  Printf.printf
    "risc_core_dump: booting %s\n  trace -> %s\n%!"
    (Filename.basename cfg.disk_image)
    cfg.trace_path;
  let result = run ~cfg ~sim ~inp ~outp ~bridge ~probes ~oc in
  close_out oc;
  (try Sys.remove tmp with
   | Sys_error _ -> ());
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
    cfg.trace_path
;;
