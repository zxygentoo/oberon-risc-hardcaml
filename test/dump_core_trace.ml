(* Boot-stream RTL co-sim — capture half (AGENT.md §6 layer 3, for the CPU core).

   Boot the SoC from the real disk and record the CPU core's per-cycle I/O to a trace,
   which [test/cosim/risc5.cpp] replays through the reference [RISC5.v] under Verilator to
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
   card), trimmed to the capture. Opt-in (run via [test/cosim/run-core.sh]); needs the
   disk image. Env: [DISK_IMG] (default the vendored .dsk), [CORE_TRACE] (output path),
   [CAP] (hard cycle cap, default 25_000_000); for ad-hoc debugging, [CYC_FROM]/[CYC_TO]
   print a windowed pc/ir/flags/regs dump and [NOTRACE] skips writing the (large) trace
   file. *)

open Hardcaml
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

let () =
  (* ── disk path (mirrors test_visual_golden) ─────────────────────────────────── *)
  let project_root () =
    let rec up dir =
      if Sys.file_exists (Filename.concat dir "dune-project")
      then dir
      else (
        let parent = Filename.dirname dir in
        if String.equal parent dir
        then failwith "dump_core_trace: no dune-project found above cwd"
        else up parent)
    in
    up (Sys.getcwd ())
  in
  let disk_image =
    match Sys.getenv_opt "DISK_IMG" with
    | Some p -> p
    | None ->
      Filename.concat
        (project_root ())
        "vendor/oberon-risc-emu-ocaml/DiskImage/Oberon-2020-08-18.dsk"
  in
  let copy_to_temp src =
    let tmp = Filename.temp_file "core_trace_" ".dsk" in
    let ic = open_in_bin src
    and oc = open_out_bin tmp in
    output_string oc (really_input_string ic (in_channel_length ic));
    close_in ic;
    close_out oc;
    tmp
  in
  let trace_path =
    match Sys.getenv_opt "CORE_TRACE" with
    | Some p -> p
    | None ->
      let dir =
        match Sys.getenv_opt "CLAUDE_JOB_DIR" with
        | Some d -> Filename.concat d "tmp"
        | None -> "/tmp/oberon-cosim"
      in
      (try Unix.mkdir dir 0o755 with
       | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
       | _ -> ());
      Filename.concat dir "core_boot.trace"
  in
  let cap =
    match Sys.getenv_opt "CAP" with
    | Some s -> int_of_string s
    | None -> 25_000_000
  in
  (* ── boot + capture (SoC + the shared off-chip SD card) ─────────────────────── *)
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Oracle.Boot_rom.bootloader)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let some n = function
    | Some x -> x
    | None -> failwith ("dump_core_trace lookup: " ^ n)
  in
  let reg n = some n (Cyclesim.lookup_reg_by_name sim n) in
  let node n = some n (Cyclesim.lookup_node_or_reg_by_name sim n) in
  let pc = reg "pc"
  and ir = reg "ir"
  and nf = reg "n"
  and zf = reg "z"
  and cf = reg "c"
  and ovf = reg "ov"
  and rdy = reg "rdy"
  and shreg = reg "spi_shreg"
  and spi_ctrl = reg "spi_ctrl"
  and irq_node = node "limit" (* the core's irq input *)
  and stallx_node = node "vidreq" (* the core's stall_x input *) in
  let regfile = some "regfile" (Cyclesim.lookup_mem_by_name sim "regfile") in
  (* optional windowed detailed state dump (env CYC_FROM/CYC_TO) — for zooming on a
     divergence *)
  let cyc_from =
    match Sys.getenv_opt "CYC_FROM" with
    | Some s -> int_of_string s
    | None -> max_int
  in
  let cyc_to =
    match Sys.getenv_opt "CYC_TO" with
    | Some s -> int_of_string s
    | None -> -1
  in
  let no_trace =
    match Sys.getenv_opt "NOTRACE" with
    | Some _ -> true
    | None -> false
  in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  (* idle the released peripheral lines high; switches/buttons default 0 = disk boot *)
  inp.rxd := hi;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.msclk := hi;
  inp.msdat := hi;
  let oc = open_out_bin trace_path in
  let rec17 = Bytes.create 17 in
  let put_u32 off v =
    Bytes.set_uint8 rec17 off (v land 0xFF);
    Bytes.set_uint8 rec17 (off + 1) ((v lsr 8) land 0xFF);
    Bytes.set_uint8 rec17 (off + 2) ((v lsr 16) land 0xFF);
    Bytes.set_uint8 rec17 (off + 3) ((v lsr 24) land 0xFF)
  in
  let b1 r = Bits.to_unsigned_int !r in
  (* stop early if pc stays constant for [spin_limit] cycles — a halted/stuck core (e.g. a
     trap abort spin). Healthy boots never do (the idle loop oscillates), so this only
     fires on a fault, and any first divergence is BEFORE it, hence contained in the
     trace. *)
  let spin_limit = 4096 in
  let cyc = ref 0
  and prev_pc = ref (-1)
  and pc_same = ref 0
  and stop = ref false in
  Printf.printf
    "dump_core_trace: booting %s\n  trace -> %s\n%!"
    (Filename.basename disk_image)
    trace_path;
  (* drive [rst_n]: 0 for the first edge (reset → StartAdr), 1 thereafter. The recorded
     rst_n is the value applied for that cycle's edge; the replay harness owns its own
     clean reset (it loads IR from record[0]'s StartAdr fetch), so the single reset-cycle
     phase is handled there. *)
  while (not !stop) && !cyc < cap do
    let rst_n = if !cyc = 0 then 0 else 1 in
    inp.rst_n := if rst_n = 1 then hi else lo;
    inp.miso := if Sd_bridge.miso bridge = 1 then hi else lo;
    Cyclesim.cycle sim;
    (* post-cycle reads: the settled combinational cloud over the now-current state *)
    let irq = Cyclesim.Node.to_int irq_node
    and stallx = Cyclesim.Node.to_int stallx_node
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
    Bytes.set_uint8 rec17 0 ctrl;
    put_u32 1 codebus;
    put_u32 5 inbus;
    put_u32 9 adr;
    put_u32 13 outbus;
    if not no_trace then output_bytes oc rec17;
    (* windowed detailed state dump (pc/ir/flags + the 16 regs) over [CYC_FROM,CYC_TO] *)
    if !cyc >= cyc_from && !cyc <= cyc_to
    then (
      Printf.printf
        "cyc %d: pc=0x%05X ir=0x%08X N=%d Z=%d C=%d V=%d | adr=0x%06X rd=%d wr=%d ben=%d \
         out=0x%08X in=0x%08X code=0x%08X\n\
        \  regs:"
        !cyc
        (Cyclesim.Reg.to_int pc)
        (Cyclesim.Reg.to_int ir)
        (Cyclesim.Reg.to_int nf)
        (Cyclesim.Reg.to_int zf)
        (Cyclesim.Reg.to_int cf)
        (Cyclesim.Reg.to_int ovf)
        adr
        rd
        wr
        ben
        outbus
        inbus
        codebus;
      for r = 0 to 15 do
        Printf.printf " R%d=0x%X" r (Cyclesim.Memory.to_int regfile ~address:r)
      done;
      Printf.printf "\n%!");
    (* drive the SD bridge (post-cycle, like the visual golden) *)
    let ctrl_v = Cyclesim.Reg.to_int spi_ctrl in
    Sd_bridge.step
      bridge
      ~sclk:(b1 outp.sclk)
      ~rdy:(Cyclesim.Reg.to_int rdy)
      ~data_tx:(Cyclesim.Reg.to_int shreg)
      ~fast:((ctrl_v lsr 2) land 1 = 1)
      ~selected:(ctrl_v land 3 = 1);
    (* progress + halt detection *)
    let p = Cyclesim.Reg.to_int pc in
    if p = !prev_pc then incr pc_same else pc_same := 0;
    prev_pc := p;
    if !pc_same >= spin_limit then stop := true;
    incr cyc;
    if !cyc mod 1_000_000 = 0
    then
      Printf.printf
        "  @%2dM cyc: pc=0x%05X  spi_bytes=%d\n%!"
        (!cyc / 1_000_000)
        p
        (Sd_bridge.nbytes bridge)
  done;
  close_out oc;
  (try Sys.remove tmp with
   | Sys_error _ -> ());
  let bytes = !cyc * 17 in
  Printf.printf
    "\n\
     done: %d cycles captured (%d bytes, %.1f MiB)\n\
     final pc=0x%05X (constant for last %d cyc%s)\n\
     trace: %s\n\
     %!"
    !cyc
    bytes
    (float_of_int bytes /. 1024. /. 1024.)
    !prev_pc
    !pc_same
    (if !pc_same >= spin_limit then " — halted/stuck" else "")
    trace_path
;;
