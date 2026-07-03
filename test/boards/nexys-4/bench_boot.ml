(* Phase-9 end-to-end bench (AGENT.md §5) — boot the *real memory path* (the PSRAM board
   SoC) to the OS handoff and count TOTAL cycles, to place the DSP-multiplier and clock
   wins in the context that actually matters: the whole machine, wait-states and all.

   The other two gauges look at compute in isolation — bench_core times one op
   (memoryless), profile_boot counts MUL/DIV density on the oracle (no memory model). This
   one runs {!Nexys4_board.Soc}: the core on a clock-enable, main memory behind {!Cellram}
   inserting [read_cycles]/[write_cycles] wait-states per access, driven from the real
   disk through the SD bridge. Two questions:

   1. Does the DSP multiplier move end-to-end cycles? Boot faithful vs [fast_mul] at the
      board's read_cycles=5. Expect ~nil — boot is 0.1% MUL (profile_boot), dominated by
      the SD-copy + PSRAM traffic.

   2. How memory-bound is it? Sweep read_cycles 2 -> 5. Every memory access costs its
      wait-states, so the extra cycles are *pure* PSRAM wait: (C5 - C2) = 3 * accesses,
      and ~rc * accesses is the wait-state overhead at that latency. That fraction is the
      ceiling a cache could reclaim — the number that says whether the next win is compute
      or memory.

   Standalone report (no pass/fail); run: dune build @bench_boot. *)

open Hardcaml
open Boot_checkpoint_common

(* The board SoC + behavioural PSRAM model is the shared {!Board_tb}; the bench drives its
   [fast_mul] / [mul_stages] (the DSP-multiplier variant) and [read_cycles] /
   [write_cycles] (the PSRAM latency) knobs across the sweeps below. Only [sclk] is read
   directly (for the SD bridge); the rest go by name via [trace_all]. *)
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

let cycle_cap = 80_000_000

(* boot to the OS handoff; return the cycle count (or None if it never leaves the ROM) *)
let boot_cycles ~icache ~fast_mul ~mul_stages ~read_cycles ~write_cycles =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp))) in
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (fun i ->
      Board_tb.create ~fast_mul ~mul_stages ~icache ~read_cycles ~write_cycles i)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let some w = function
    | Some x -> x
    | None -> failwith ("lookup: " ^ w ^ " not found")
  in
  let reg n = some n (Cyclesim.lookup_reg_by_name sim n) in
  let pc = reg "pc"
  and rdy = reg "rdy"
  and shreg = reg "spi_shreg"
  and spi_ctrl = reg "spi_ctrl" in
  (* cache stats (Phase-10a): named combinational nodes, present only with [icache]. An
     access is counted at its retire ([core_ce]=1); a hit lasts one [core_ce]=1 cycle. *)
  let cnode n = Cyclesim.lookup_node_by_name sim n in
  let n_cache_read = cnode "cache_read"
  and n_cache_hit = cnode "cache_hit"
  and n_core_ce = cnode "core_ce" in
  let accesses = ref 0
  and hits = ref 0 in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  inp.rxd := hi;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.msclk := hi;
  inp.msdat := hi;
  inp.rst_n := lo;
  inp.miso := hi;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  let cycle = ref 0
  and handoff = ref false in
  while (not !handoff) && !cycle < cycle_cap do
    inp.miso := if Sd_bridge.miso bridge = 1 then hi else lo;
    Cyclesim.cycle sim;
    (match n_cache_read, n_cache_hit, n_core_ce with
     | Some rd, Some h, Some ce ->
       if Cyclesim.Node.to_int ce = 1 && Cyclesim.Node.to_int rd = 1 then incr accesses;
       if Cyclesim.Node.to_int h = 1 then incr hits
     | _ -> ());
    let ctrl = Cyclesim.Reg.to_int spi_ctrl in
    Sd_bridge.step
      bridge
      ~sclk:(Bits.to_unsigned_int !(outp.sclk))
      ~rdy:(Cyclesim.Reg.to_int rdy)
      ~data_tx:(Cyclesim.Reg.to_int shreg)
      ~fast:((ctrl lsr 2) land 1 = 1)
      ~selected:(ctrl land 3 = 1);
    if Cyclesim.Reg.to_int pc < rom_region_base then handoff := true;
    incr cycle
  done;
  rm_temp tmp;
  if !handoff then Some (!cycle, !accesses, !hits) else None
;;

let must = function
  | Some c -> c
  | None -> failwith "no handoff within the cycle cap"
;;

(* Phase-10a — a *same-work* compare of the running OS (post-handoff), fixing the
   fixed-cycle window's phase drift (there the cached run raced ahead into the idle loop
   while the uncached one was still in init, so the two averaged different code). Two
   board SoCs, cache off and on, each boot to the handoff — from the *same* architectural
   state, since the boot checkpoint proves the loaded image + arch state there are
   timing-independent — then run in INSTRUCTION LOCKSTEP: advance each by one retired
   instruction and compare [pc]. While the pc's agree the two execute the identical OS
   instruction stream, so the cycles each spent are a clean same-work measurement. The
   first timing-dependent poll (SD / ms-timer, which the faster machine reaches after
   fewer instructions) diverges the streams; we stop there and report the aligned prefix —
   the straight-line OS code before the first I/O wait. [make_os] builds one instance; the
   closures keep the [Sim.t] type private. *)
(* one CPU PSRAM access retiring this cycle, with its address — the raw material for the
   miss-autopsy cache mirrors (Phase-10b). [wa] is the 18-bit word address of the 1 MB
   window ([adr[19:2]], exactly {!Cache}'s cached address). *)
type mem_ev =
  | Read of
      { wa : int
      ; hit : bool
      ; fetch : bool
      }
  | Store of
      { wa : int
      ; byte : bool
      }

type os_inst =
  { step : unit -> unit
  ; retired :
      unit -> bool (* did an instruction retire this cycle ([is_fetch] & [core_ce]) *)
  ; cache_ev : unit -> bool * bool (* (a cacheable read retired, it hit) this cycle *)
  ; mem_ev : unit -> mem_ev option (* the PSRAM access retiring this cycle, if any *)
  ; classify : unit -> int
      (* this clock's bucket: 0 retire 1 exec 2 compute 3 fetchW 4 loadW 5 storeW *)
  ; contention : unit -> bool (* frozen this clock because video owns the PSRAM bus *)
  ; video_bus : unit -> bool (* the PSRAM port is serving a video word this clock *)
  ; store_ev : unit -> bool (* a store retires this clock (ce=1 & wr) *)
  ; pc : unit -> int
  ; cleanup : unit -> unit
  }

let make_os ?(video = true) ?(write_update = false) ~write_cycles ~icache ~lines_log2 () =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp))) in
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (fun i ->
      Board_tb.create
        ~fast_mul:false
        ~mul_stages:0
        ~icache
        ~lines_log2
        ~write_update
        ~video
        ~read_cycles:5
        ~write_cycles
        i)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let some w = function
    | Some x -> x
    | None -> failwith ("lookup: " ^ w ^ " not found")
  in
  let reg n = some n (Cyclesim.lookup_reg_by_name sim n) in
  let pc = reg "pc"
  and rdy = reg "rdy"
  and shreg = reg "spi_shreg"
  and spi_ctrl = reg "spi_ctrl" in
  let cnode n = Cyclesim.lookup_node_by_name sim n in
  (* [cache_read]/[cache_hit] exist only under [~icache:true], so they stay optional;
     everything else is unconditional and must resolve LOUDLY — a silent [None] zeroes a
     whole profile column (it hid the video-contention overlay once: [cr_busy] /
     [cr_op_vid] are *registers*, invisible to [lookup_node_by_name]). *)
  let n_cache_read = cnode "cache_read"
  and n_cache_hit = cnode "cache_hit" in
  let n_core_ce = some "core_ce" (cnode "core_ce")
  and n_is_fetch = some "is_fetch" (cnode "is_fetch")
  and n_core_wr = some "core_wr" (cnode "core_wr")
  and n_core_rd = some "core_rd" (cnode "core_rd")
  and n_core_adr = some "core_adr" (cnode "core_adr")
  and n_core_ben = some "core_ben" (cnode "core_ben")
  and n_cpu_internal = some "cpu_internal" (cnode "cpu_internal")
  and r_cr_busy = reg "cr_busy"
  and r_cr_op_vid = reg "cr_op_vid" in
  let ci = Cyclesim.Node.to_int in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  inp.rxd := hi;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.msclk := hi;
  inp.msdat := hi;
  inp.rst_n := lo;
  inp.miso := hi;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  let step () =
    inp.miso := if Sd_bridge.miso bridge = 1 then hi else lo;
    Cyclesim.cycle sim;
    let ctrl = Cyclesim.Reg.to_int spi_ctrl in
    Sd_bridge.step
      bridge
      ~sclk:(Bits.to_unsigned_int !(outp.sclk))
      ~rdy:(Cyclesim.Reg.to_int rdy)
      ~data_tx:(Cyclesim.Reg.to_int shreg)
      ~fast:((ctrl lsr 2) land 1 = 1)
      ~selected:(ctrl land 3 = 1)
  in
  let retired () = ci n_core_ce = 1 && ci n_is_fetch = 1 in
  let cache_ev () =
    match n_cache_read, n_cache_hit with
    | Some rd, Some h -> ci n_core_ce = 1 && ci rd = 1, ci h = 1
    | _ -> false, false
  in
  (* classify this system clock into one stall bucket (see [stall_profile]): 0 retire | 1
     exec | 2 compute | 3 fetchW | 4 loadW | 5 storeW *)
  let classify () =
    let ce = ci n_core_ce
    and f = ci n_is_fetch
    and r = ci n_core_rd
    and w = ci n_core_wr in
    if ce = 1
    then if f = 1 then 0 else if r = 1 || w = 1 then 1 else 2
    else if w = 1
    then 5
    else if r = 1
    then 4
    else 3
  in
  (* the PSRAM port is serving a video word ([cr_busy & cr_op_vid]); [contention] is that
     while the CPU sits frozen — the tax framebuffer-in-BRAM removes. Both registers read
     post-edge ([Cyclesim.Reg]) vs the nodes' in-cycle values: a ±1-cycle skew, noise
     against a video word's ~11-cycle port occupancy. *)
  let video_bus () =
    Cyclesim.Reg.to_int r_cr_busy = 1 && Cyclesim.Reg.to_int r_cr_op_vid = 1
  in
  let contention () = ci n_core_ce = 0 && video_bus () in
  let store_ev () = ci n_core_ce = 1 && ci n_core_wr = 1 in
  (* the PSRAM access retiring this cycle, with its cached word address. Reads need the
     icache instance ([cache_read]/[cache_hit]); on a cache-off instance they are
     invisible (None) — the autopsy only runs cache-on. *)
  let mem_ev () =
    if ci n_core_ce <> 1
    then None
    else (
      let wa = (ci n_core_adr lsr 2) land 0x3FFFF in
      let read, hit = cache_ev () in
      if read
      then Some (Read { wa; hit; fetch = ci n_is_fetch = 1 })
      else if ci n_core_wr = 1 && ci n_cpu_internal = 0
      then Some (Store { wa; byte = ci n_core_ben = 1 })
      else None)
  in
  { step
  ; retired
  ; cache_ev
  ; mem_ev
  ; classify
  ; contention
  ; video_bus
  ; store_ev
  ; pc = (fun () -> Cyclesim.Reg.to_int pc)
  ; cleanup = (fun () -> rm_temp tmp)
  }
;;

let boot_to_handoff t =
  let c = ref 0
  and hand = ref false in
  while (not !hand) && !c < cycle_cap do
    t.step ();
    if t.pc () < rom_region_base then hand := true;
    incr c
  done;
  if not !hand then failwith "no handoff within the cycle cap"
;;

(* advance one retired instruction; return (cycles, cacheable-read retires, hits) it took *)
let advance_instr t =
  let cyc = ref 0
  and acc = ref 0
  and hit = ref 0
  and go = ref true in
  while !go do
    t.step ();
    incr cyc;
    let a, h = t.cache_ev () in
    if a then incr acc;
    if h then incr hit;
    if t.retired () then go := false;
    if !cyc > 100_000 then failwith "advance_instr: no retire in 100k cycles (hang?)"
  done;
  !cyc, !acc, !hit
;;

(* boot both instances to the handoff, then lockstep by instruction over the same OS code
   until [pc] diverges (the first timing-dependent poll) or [max_instrs]. Returns
   (aligned_instrs, diverged, cycles_a, cycles_b, b_accesses, b_hits) — the honest
   same-work A/B for any single-knob pair (icache off/on, video on/off, ...). *)
let compare_pair ~max_instrs (a : os_inst) (b : os_inst) =
  boot_to_handoff a;
  boot_to_handoff b;
  let cyc_a = ref 0
  and cyc_b = ref 0
  and acc = ref 0
  and hit = ref 0
  and i = ref 0
  and diverged = ref false in
  while !i < max_instrs && not !diverged do
    let ca, _, _ = advance_instr a in
    let cb, ab, hb = advance_instr b in
    if a.pc () <> b.pc ()
    then diverged := true
    else (
      cyc_a := !cyc_a + ca;
      cyc_b := !cyc_b + cb;
      acc := !acc + ab;
      hit := !hit + hb;
      incr i)
  done;
  a.cleanup ();
  b.cleanup ();
  !i, !diverged, !cyc_a, !cyc_b, !acc, !hit
;;

let compare_os ~max_instrs ~lines_log2 =
  compare_pair
    ~max_instrs
    (make_os ~write_cycles:5 ~icache:false ~lines_log2 ())
    (make_os ~write_cycles:5 ~icache:true ~lines_log2 ())
;;

(* Phase-10b spike — MISS AUTOPSY. Why do loads miss 35-41% when capacity doesn't move
   them (the size sweep is flat)? Hypothesis: snoop-INVALIDATE self-inflicts them — a
   store to a cached line drops it, so store-then-load (stack slots, record fields) is a
   guaranteed miss. Two measurements over one run:

   1. Taxonomy: for every read miss, what state was the line in — conflict (valid, other
      tag), store-killed (invalid, killed by a store to THIS tag; split word/byte store),
      or cold (anything else)?
   2. Counterfactual snoop policies, replayed on the same access stream: A (RTL today)
      fill on read-miss; store-hit INVALIDATES B1 (update) word store-hit UPDATES in
      place; byte store-hit still kills B2 (update+merge) any store-hit updates (byte
      merges via the async-read port) B3 (B2+allocate) word store-miss also fills the line
      (write-allocate)

   The mirrors track (valid, tag) only — policy hit-rates need no data. Mirror A is
   validated against the RTL's own [cache_hit] on every read (a mismatch = harness bug,
   reported loudly; note [multiport_memory]'s post-write async read, cache.ml — events are
   applied at retire, which matches it). Events feed the mirrors from RESET (the boot
   warms the cache); stats collect past the OS handoff only. Caveat: the stream is the one
   the RTL policy produced — a different policy shifts poll-loop timing slightly; fine for
   a ceiling. *)
let miss_autopsy
  ?(video = true)
  ?(write_update = false)
  ~lines_log2
  ~instr_budget
  ~cycle_cap:cap
  ()
  =
  let t = make_os ~video ~write_update ~write_cycles:5 ~icache:true ~lines_log2 () in
  let lines = 1 lsl lines_log2 in
  let idx_of wa = wa land (lines - 1)
  and tag_of wa = wa lsr lines_log2 in
  (* mirror A (the RTL policy) + why-invalid; mirrors B1/B2/B3 *)
  let a_val = Array.make lines false
  and a_tag = Array.make lines 0
  and killed = Array.make lines 0 (* 0 live/cold; 1 killed by word store; 2 by byte *)
  and killed_tag = Array.make lines 0 in
  let b_val = Array.init 3 (fun _ -> Array.make lines false)
  and b_tag = Array.init 3 (fun _ -> Array.make lines 0) in
  let mism = ref 0
  and measuring = ref false
  and cyc = ref 0
  and instr = ref 0
  and loadw = ref 0
  and stores_w = ref 0
  and stores_b = ref 0 in
  (* per read class: 0 = fetch, 1 = load *)
  let reads = [| 0; 0 |]
  and hits_rtl = [| 0; 0 |]
  and miss_conflict = [| 0; 0 |]
  and miss_killed_w = [| 0; 0 |]
  and miss_killed_b = [| 0; 0 |]
  and miss_cold = [| 0; 0 |]
  and hits_b = Array.make_matrix 3 2 0 in
  let apply = function
    | Read { wa; hit; fetch } ->
      let idx = idx_of wa
      and tag = tag_of wa in
      let k = if fetch then 0 else 1 in
      if (a_val.(idx) && a_tag.(idx) = tag) <> hit then incr mism;
      if !measuring
      then (
        reads.(k) <- reads.(k) + 1;
        if hit
        then hits_rtl.(k) <- hits_rtl.(k) + 1
        else if a_val.(idx)
        then miss_conflict.(k) <- miss_conflict.(k) + 1
        else if killed.(idx) = 1 && killed_tag.(idx) = tag
        then miss_killed_w.(k) <- miss_killed_w.(k) + 1
        else if killed.(idx) = 2 && killed_tag.(idx) = tag
        then miss_killed_b.(k) <- miss_killed_b.(k) + 1
        else miss_cold.(k) <- miss_cold.(k) + 1;
        for p = 0 to 2 do
          if b_val.(p).(idx) && b_tag.(p).(idx) = tag
          then hits_b.(p).(k) <- hits_b.(p).(k) + 1
        done);
      (* every policy fills on its read-miss (a no-op when it hit) *)
      a_val.(idx) <- true;
      a_tag.(idx) <- tag;
      killed.(idx) <- 0;
      for p = 0 to 2 do
        b_val.(p).(idx) <- true;
        b_tag.(p).(idx) <- tag
      done
    | Store { wa; byte } ->
      let idx = idx_of wa
      and tag = tag_of wa in
      if !measuring then if byte then incr stores_b else incr stores_w;
      (* A mirrors the RTL policy under test: a store-hit kills the line — except a word
         store-hit under [write_update], which refreshes it in place *)
      if a_val.(idx) && a_tag.(idx) = tag && not (write_update && not byte)
      then (
        a_val.(idx) <- false;
        killed.(idx) <- (if byte then 2 else 1);
        killed_tag.(idx) <- tag);
      (* B1: word store-hit updates in place (no mirror change); byte store-hit kills *)
      if byte && b_val.(0).(idx) && b_tag.(0).(idx) = tag then b_val.(0).(idx) <- false;
      (* B2: any store-hit updates — nothing to do. B3: word stores also allocate *)
      if not byte
      then (
        b_val.(2).(idx) <- true;
        b_tag.(2).(idx) <- tag)
  in
  (* boot to the handoff, mirrors following along *)
  let booted = ref false
  and bc = ref 0 in
  while (not !booted) && !bc < cycle_cap do
    t.step ();
    (match t.mem_ev () with
     | Some ev -> apply ev
     | None -> ());
    if t.pc () < rom_region_base then booted := true;
    incr bc
  done;
  if not !booted then failwith "miss_autopsy: no handoff within the cycle cap";
  Printf.printf
    "    boot: mirror-A vs RTL hit-bit mismatches = %d %s\n%!"
    !mism
    (if !mism = 0
     then "(mirror validated)"
     else "** HARNESS BUG — numbers below suspect **");
  mism := 0;
  measuring := true;
  while !instr < instr_budget && !cyc < cap do
    t.step ();
    incr cyc;
    if t.classify () = 4 then incr loadw;
    (match t.mem_ev () with
     | Some ev -> apply ev
     | None -> ());
    if t.retired () then incr instr
  done;
  t.cleanup ();
  let pct a b = if b = 0 then 0.0 else 100.0 *. float_of_int a /. float_of_int b in
  Printf.printf
    "    window: %d instr / %d cyc (CPI %.2f);  window mismatches = %d;  stores: %d word \
     + %d byte\n\
     %!"
    !instr
    !cyc
    (float_of_int !cyc /. float_of_int (max 1 !instr))
    !mism
    !stores_w
    !stores_b;
  Printf.printf "\n    miss taxonomy (per read class; %% of that class's misses):\n%!";
  List.iteri
    (fun k name ->
      let m = miss_conflict.(k) + miss_killed_w.(k) + miss_killed_b.(k) + miss_cold.(k) in
      Printf.printf
        "      %-5s : %8d reads, %.2f%% hit, %6d misses = conflict %5d (%4.1f%%) | \
         store-killed word %5d (%4.1f%%) byte %5d (%4.1f%%) | cold %5d (%4.1f%%)\n\
         %!"
        name
        reads.(k)
        (pct hits_rtl.(k) reads.(k))
        m
        miss_conflict.(k)
        (pct miss_conflict.(k) m)
        miss_killed_w.(k)
        (pct miss_killed_w.(k) m)
        miss_killed_b.(k)
        (pct miss_killed_b.(k) m)
        miss_cold.(k)
        (pct miss_cold.(k) m))
    [ "fetch"; "load" ];
  (* counterfactual policies: hit-rates + a cycle projection. Extra hits vs the RTL saved
     ~the average measured load-miss cost each (loadW cycles / load misses). *)
  let load_misses = reads.(1) - hits_rtl.(1) in
  let avg_miss = float_of_int !loadw /. float_of_int (max 1 load_misses) in
  Printf.printf
    "\n\
    \    counterfactual snoop policies (same stream; avg load-miss cost measured %.1f \
     cyc):\n\
     %!"
    avg_miss;
  List.iteri
    (fun p name ->
      let extra = hits_b.(p).(1) - hits_rtl.(1) in
      let saved = float_of_int extra *. avg_miss in
      let proj = float_of_int !cyc -. saved in
      Printf.printf
        "      %-18s: load hit %.2f%% (fetch %.2f%%)  ->  +%d load hits, ~%.0fk cyc \
         saved, CPI %.2f -> %.2f (%.3fx)\n\
         %!"
        name
        (pct hits_b.(p).(1) reads.(1))
        (pct hits_b.(p).(0) reads.(0))
        extra
        (saved /. 1000.)
        (float_of_int !cyc /. float_of_int (max 1 !instr))
        (proj /. float_of_int (max 1 !instr))
        (float_of_int !cyc /. proj))
    [ "B1 update"; "B2 update+merge"; "B3 +allocate" ]
;;

(* Phase-10b spike: the autopsies + the write-update A/B run FIRST for fast iteration; the
   heavier gauges follow. *)
let () =
  Printf.printf
    "  Miss autopsy — snoop-INVALIDATE, the Phase-10a baseline (cache on, 4KB, video \
     live):\n\
     %!";
  miss_autopsy ~lines_log2:10 ~instr_budget:2_000_000 ~cycle_cap:20_000_000 ();
  Printf.printf
    "\n\
    \  Miss autopsy — WRITE-UPDATE, the Phase-10b policy. Mismatches = 0 validates the RTL\n\
    \  change against the independent OCaml mirror; B1/B2 should now project +0.\n\
     %!";
  miss_autopsy
    ~write_update:true
    ~lines_log2:10
    ~instr_budget:2_000_000
    ~cycle_cap:20_000_000
    ();
  Printf.printf
    "\n\
    \  Write-update — same-work instruction lockstep, snoop-invalidate vs WRITE-UPDATE\n\
    \  (cache on, 4KB, video live): the honest Phase-10b number.\n\
     %!";
  let aligned, _, c_inv, c_upd, upd_reads, upd_hits =
    compare_pair
      ~max_instrs:200_000
      (make_os ~write_cycles:5 ~icache:true ~lines_log2:10 ())
      (make_os ~write_update:true ~write_cycles:5 ~icache:true ~lines_log2:10 ())
  in
  let f = float_of_int in
  Printf.printf
    "    aligned OS instructions : %d\n\
    \    cycles over that prefix : invalidate %d   write-update %d\n\
    \    cycles / instruction    : invalidate %.2f   write-update %.2f\n\
    \    same-work speedup       : %.3fx\n\
    \    cache (write-update)    : %d hits / %d PSRAM reads = %.2f%% hit-rate\n\
     %!"
    aligned
    c_inv
    c_upd
    (f c_inv /. f (max 1 aligned))
    (f c_upd /. f (max 1 aligned))
    (f c_inv /. f (max 1 c_upd))
    upd_hits
    upd_reads
    (100. *. f upd_hits /. f (max 1 upd_reads))
;;

let () =
  Printf.printf
    "\n\
     Phase-9 end-to-end bench — PSRAM board SoC, reset -> OS handoff, total cycles\n\n\
     %!";
  Printf.printf "  booting (faithful mul, read_cycles=5) ...\n%!";
  let f5, _, _ =
    must
      (boot_cycles
         ~icache:false
         ~fast_mul:false
         ~mul_stages:0
         ~read_cycles:5
         ~write_cycles:5)
  in
  Printf.printf "  booting (DSP fast_mul mul_stages:2, read_cycles=5) ...\n%!";
  let x5, _, _ =
    must
      (boot_cycles
         ~icache:false
         ~fast_mul:true
         ~mul_stages:2
         ~read_cycles:5
         ~write_cycles:5)
  in
  Printf.printf "  booting (faithful mul, read_cycles=2) ...\n%!";
  let f2, _, _ =
    must
      (boot_cycles
         ~icache:false
         ~fast_mul:false
         ~mul_stages:0
         ~read_cycles:2
         ~write_cycles:2)
  in
  (* rc only touches PSRAM accesses, so the rc 2->5 delta is *pure* wait: +3 cycles per
     half-word, so (C5 - C2) / 3 = half-word accesses and ~rc * that = the wait at that
     latency. The SoC's instruction count isn't observed (it re-polls the slow SPI far
     more than the oracle), so we quote no CPI — the rc-delta is denominator-free, the
     honest memory number. *)
  let halfword_accesses = (f5 - f2) / 3 in
  let wait5 = 5 * halfword_accesses in
  let pct x tot = 100.0 *. float_of_int x /. float_of_int tot in
  Printf.printf "\n  DSP multiplier, end-to-end (read_cycles=5, the board latency):\n";
  Printf.printf "    faithful : %d cycles\n" f5;
  Printf.printf "    fast_mul : %d cycles\n" x5;
  Printf.printf
    "    gain     : %+.2f%%  (%d cycles)  — boot is 0.1%% MUL, so ~nil, as Amdahl predicts\n"
    (pct (f5 - x5) f5)
    (f5 - x5);
  Printf.printf "\n  PSRAM wait-states (faithful mul), from the read_cycles sweep:\n";
  Printf.printf "    read_cycles=2 : %d cycles\n" f2;
  Printf.printf "    read_cycles=5 : %d cycles\n" f5;
  Printf.printf
    "    +3 wait/access delta = %d cycles (%.1f%% of the rc=5 boot); ~%d half-word \
     accesses\n\
    \    => ~%d cycles = ~%.0f%% of the rc=5 boot spent in PSRAM latency\n"
    (f5 - f2)
    (pct (f5 - f2) f5)
    halfword_accesses
    wait5
    (pct wait5 f5);
  Printf.printf
    "\n\
    \  Read-off. The DSP mul (17x per-op) is Amdahl-capped to ~nil end-to-end. ~%.0f%% \
     of boot\n\
    \  cycles are PSRAM wait — and that UNDERSTATES the running OS: boot fetches code \
     from the\n\
    \  on-chip ROM fast-path, but post-handoff every instruction fetch is a PSRAM read, \
     so the\n\
    \  live system is more memory-bound still. The broad win already banked is the \
     50->60 MHz\n\
    \  clock (1.2x, on compute AND memory); the next real lever is memory latency — an \
     I-cache /\n\
    \  wider PSRAM — not more compute. See test/bench/README.md.\n\
     %!"
    (pct wait5 f5);
  (* ── Phase-10a: I-cache on vs off (faithful mul, read_cycles=5) ── reuses [f5] as the
     cache-off baseline, so this is one extra boot. Reaching the handoff at all with the
     cache on is itself the coherence check: the loader writes the OS to low RAM then
     jumps into it, so a stale-code bug would trap or hang before the handoff. *)
  Printf.printf "\n  I-cache (Phase-10a) — faithful mul, read_cycles=5:\n%!";
  Printf.printf "  booting (I-CACHE ON) ...\n%!";
  let c_on, acc, hits =
    must
      (boot_cycles
         ~icache:true
         ~fast_mul:false
         ~mul_stages:0
         ~read_cycles:5
         ~write_cycles:5)
  in
  let hr = if acc = 0 then 0.0 else 100.0 *. float_of_int hits /. float_of_int acc in
  Printf.printf "    icache off : %d cycles\n" f5;
  Printf.printf "    icache on  : %d cycles\n" c_on;
  Printf.printf "    gain       : %+.2f%%  (%d cycles)\n" (pct (f5 - c_on) f5) (f5 - c_on);
  Printf.printf
    "    cache      : %d hits / %d PSRAM read-accesses = %.1f%% hit-rate\n"
    hits
    acc
    hr;
  Printf.printf
    "    NB boot runs code from the on-chip ROM fast-path, so PSRAM *fetches* are few — \
     this\n\
    \    is a lower bound; the running OS fetches every instruction from PSRAM. See \
     README.\n\
     %!";
  (* ── Phase-10a: same-work post-handoff compare (OS code only, instr lockstep) ── *)
  let max_instrs = 2_000_000 in
  Printf.printf
    "\n\
    \  Running OS — same-work instruction lockstep past the handoff (faithful, rc=5):\n\
     %!";
  Printf.printf "  booting both configs to the handoff, then lockstepping ...\n%!";
  let aligned, diverged, oc, cc, cacc, chits = compare_os ~max_instrs ~lines_log2:10 in
  let denom = max 1 aligned in
  let cpi c = float_of_int c /. float_of_int denom in
  let hr = if cacc = 0 then 0.0 else 100.0 *. float_of_int chits /. float_of_int cacc in
  Printf.printf
    "    aligned OS instructions   :  %d %s\n"
    aligned
    (if diverged
     then "(streams then diverge — the first timing-dependent SD/timer poll)"
     else "(reached max_instrs; never diverged)");
  Printf.printf "    cycles over that prefix   :  off %d   on %d\n" oc cc;
  Printf.printf "    cycles / instruction      :  off %.2f   on %.2f\n" (cpi oc) (cpi cc);
  Printf.printf
    "    same-work speedup         :  %.2fx\n"
    (if cc = 0 then 0.0 else float_of_int oc /. float_of_int cc);
  Printf.printf
    "    cache (on, this prefix)   :  %d hits / %d PSRAM reads = %.1f%% hit-rate\n"
    chits
    cacc
    hr
;;

(* ── Phase-10: split the on-cycle stall over a long post-handoff window ── The size sweep
   settled the read side (the residual miss is compulsory, not capacity), so the question
   is *where the stall cycles go*, over more than the 28.8K same-work prefix.
   [stall_profile] runs the running OS (cache on) forward from the handoff and classifies
   EVERY system clock into one bucket from [core_ce]/[is_fetch]/[core_rd]/[core_wr]:
   {v
     0 retire  ce=1 & fetch          an instruction boundary (= #instrs)
     1 exec    ce=1 & ~fetch & mem   a load/store data or completion cycle
     2 compute ce=1 & ~fetch & ~mem  an iterative unit grinding (MUL/DIV/FP)
     3 fetchW  ce=0 & fetch          frozen on an instruction-fetch miss
     4 loadW   ce=0 & load           frozen on a data-load miss
     5 storeW  ce=0 & store          frozen on a write-through store (UNCACHED)
   v}
   [contend] overlays frozen cycles where the PSRAM port is serving VIDEO
   ([cr_busy & cr_op_vid]) — the bus tax framebuffer-in-BRAM removes. read-wait
   (fetchW+loadW) vs store-wait is the lever question: reads -> multi-word/prefetch/burst;
   stores -> a write buffer. Segmented per 250k instr so bring-up (heavy) vs idle (light)
   is visible. *)
let stall_profile
  ?(video = true)
  ~lines_log2
  ~write_cycles
  ~instr_budget
  ~cycle_cap
  ~seg
  ()
  =
  let t = make_os ~video ~icache:true ~lines_log2 ~write_cycles () in
  boot_to_handoff t;
  let names = [| "retire"; "exec"; "compute"; "fetchW"; "loadW"; "storeW" |] in
  let tot = Array.make 6 0
  and seg_b = Array.make 6 0
  and contend = ref 0
  and vidbus = ref 0
  and seg_contend = ref 0
  and creads = ref 0
  and chits = ref 0
  and stores = ref 0
  and fr_reads = ref 0
  and fr_hits = ref 0
  and ld_reads = ref 0
  and ld_hits = ref 0
  and instr = ref 0
  and seg_instr = ref 0
  and cyc = ref 0
  and seg_cyc = ref 0 in
  let pctc v c = if c = 0 then 0.0 else 100.0 *. float_of_int v /. float_of_int c in
  Printf.printf
    "      seg     instrs        cyc    CPI   fetchW%% loadW%% storeW%% contend%%\n%!";
  Printf.printf
    "      -----   -------   --------   ----   ------- ------- ------- --------\n%!";
  let flush_seg lbl =
    let c = !seg_cyc in
    let cpi = if !seg_instr = 0 then 0.0 else float_of_int c /. float_of_int !seg_instr in
    Printf.printf
      "    %6s  %8d  %9d  %5.2f   %6.1f  %6.1f  %6.1f  %7.1f\n%!"
      lbl
      !seg_instr
      c
      cpi
      (pctc seg_b.(3) c)
      (pctc seg_b.(4) c)
      (pctc seg_b.(5) c)
      (pctc !seg_contend c);
    Array.fill seg_b 0 6 0;
    seg_contend := 0;
    seg_instr := 0;
    seg_cyc := 0
  in
  while !instr < instr_budget && !cyc < cycle_cap do
    t.step ();
    incr cyc;
    incr seg_cyc;
    let b = t.classify () in
    tot.(b) <- tot.(b) + 1;
    seg_b.(b) <- seg_b.(b) + 1;
    if t.video_bus () then incr vidbus;
    if t.contention ()
    then (
      incr contend;
      incr seg_contend);
    let a, h = t.cache_ev () in
    if a
    then (
      incr creads;
      if h then incr chits;
      if b = 0
      then (
        incr fr_reads;
        if h then incr fr_hits)
      else (
        incr ld_reads;
        if h then incr ld_hits));
    if t.store_ev () then incr stores;
    if b = 0
    then (
      incr instr;
      incr seg_instr);
    if !seg_instr >= seg then flush_seg (Printf.sprintf "%dk" (!instr / 1000))
  done;
  if !seg_cyc > 0 then flush_seg "tail";
  t.cleanup ();
  let cpi = if !instr = 0 then 0.0 else float_of_int !cyc /. float_of_int !instr in
  Printf.printf
    "\n    totals: %d instr / %d cyc  (CPI %.2f);  cache %d/%d = %.1f%% hit\n%!"
    !instr
    !cyc
    cpi
    !chits
    !creads
    (pctc !chits !creads);
  Array.iteri
    (fun i n -> Printf.printf "      %-8s %9d  %5.1f%%\n" names.(i) n (pctc n !cyc))
    tot;
  Printf.printf
    "      %-8s %9d  %5.1f%%   (overlay: frozen while video owns the bus)\n%!"
    "contend"
    !contend
    (pctc !contend !cyc);
  let readw = tot.(3) + tot.(4) in
  let frozen = readw + tot.(5) in
  Printf.printf
    "\n\
    \    frozen PSRAM-wait = %d cyc = %.1f%% of the run (the residual the cache leaves):\n\
     %!"
    frozen
    (pctc frozen !cyc);
  Printf.printf
    "      read-wait  (fetchW+loadW)  : %9d  (%.1f%% run, %.0f%% of frozen)\n%!"
    readw
    (pctc readw !cyc)
    (pctc readw (max 1 frozen));
  Printf.printf
    "      store-wait (write-through) : %9d  (%.1f%% run, %.0f%% of frozen)\n%!"
    tot.(5)
    (pctc tot.(5) !cyc)
    (pctc tot.(5) (max 1 frozen));
  Printf.printf
    "      video-contention (overlay) : %9d  (%.1f%% run, %.0f%% of frozen) — removed by \
     framebuffer-in-BRAM\n\
     %!"
    !contend
    (pctc !contend !cyc)
    (pctc !contend (max 1 frozen));
  Printf.printf
    "      video port occupancy       : %9d  (%.1f%% of all clocks the PSRAM port serves \
     video)\n\
     %!"
    !vidbus
    (pctc !vidbus !cyc);
  (* load probe (cheap first step): split the cache read hit-rate by fetch vs load *)
  Printf.printf
    "\n\
    \    read hit-rate split:  fetch %d/%d = %.2f%%   load %d/%d = %.2f%%  (loads are \
     the miss source)\n\
     %!"
    !fr_hits
    !fr_reads
    (pctc !fr_hits !fr_reads)
    !ld_hits
    !ld_reads
    (pctc !ld_hits !ld_reads);
  (* write-buffer ceiling: a perfect async buffer hides storeW entirely — realistic while
     the bus has free headroom (below: cycles neither frozen on a CPU access nor serving
     video), bounded below by drain-vs-load/video arbitration (unmodelled) + buffer-full
     on store bursts *)
  let ceil_cyc = !cyc - tot.(5) in
  Printf.printf
    "\n\
    \    WRITE-BUFFER ceiling (stores fully hidden):  CPI %.2f -> %.2f  (%.2fx),  frozen \
     %.1f%% -> %.1f%%\n\
     %!"
    cpi
    (float_of_int ceil_cyc /. float_of_int (max 1 !instr))
    (float_of_int !cyc /. float_of_int (max 1 ceil_cyc))
    (pctc frozen !cyc)
    (pctc readw !cyc);
  (* bus-free = not frozen on a CPU access AND not serving video (video-owned cycles
     outside frozen ones still occupy the port) *)
  let idle_bus = !cyc - frozen - (!vidbus - !contend) in
  Printf.printf
    "    feasibility: bus-free %d cyc (%.1f%%) vs store-work %d cyc (%.1f%%) = %.1fx \
     headroom to hide stores; ~%d store events (1 per %d instr)\n\
     %!"
    idle_bus
    (pctc idle_bus !cyc)
    tot.(5)
    (pctc tot.(5) !cyc)
    (float_of_int idle_bus /. float_of_int (max 1 tot.(5)))
    !stores
    (!instr / max 1 !stores)
;;

(* the LOAD lever: the aggregate size sweep was fetch-dominated (flat) and hid loads. This
   sweeps the cache size reporting fetch vs LOAD hit-rate separately, over the long window
   — does load-hit climb with capacity (a bigger / split D-cache is the win) or stay flat
   (loads are low-locality: only burst / penalty-reduction helps)? Unified cache; a rising
   curve implies a split I/D would help too (and cheaper — it stops fetches evicting load
   lines). *)
let load_point ~lines_log2 ~instr_budget ~cycle_cap =
  let t = make_os ~write_cycles:5 ~icache:true ~lines_log2 () in
  boot_to_handoff t;
  let tot = Array.make 6 0
  and fr_reads = ref 0
  and fr_hits = ref 0
  and ld_reads = ref 0
  and ld_hits = ref 0
  and instr = ref 0
  and cyc = ref 0 in
  while !instr < instr_budget && !cyc < cycle_cap do
    t.step ();
    incr cyc;
    let b = t.classify () in
    tot.(b) <- tot.(b) + 1;
    let a, h = t.cache_ev () in
    if a
    then
      if b = 0
      then (
        incr fr_reads;
        if h then incr fr_hits)
      else (
        incr ld_reads;
        if h then incr ld_hits);
    if b = 0 then incr instr
  done;
  t.cleanup ();
  let pct v c = if c = 0 then 0.0 else 100.0 *. float_of_int v /. float_of_int c in
  Printf.printf
    "  %7dB %7d   fetch %6.2f%%   load %6.2f%%   loadW %5.1f%%   storeW %5.1f%%   CPI %.2f\n\
     %!"
    ((1 lsl lines_log2) * 4)
    (1 lsl lines_log2)
    (pct !fr_hits !fr_reads)
    (pct !ld_hits !ld_reads)
    (pct tot.(4) !cyc)
    (pct tot.(5) !cyc)
    (float_of_int !cyc /. float_of_int (max 1 !instr))
;;

let () =
  Printf.printf
    "\n\
    \  Running-OS stall profile (cache on, 4KB, video DMA live — the board reality; long\n\
    \  post-handoff window, every system clock bucketed; segmented per 250k instr).\n\
     %!";
  stall_profile
    ~video:true
    ~lines_log2:10
    ~write_cycles:5
    ~instr_budget:2_000_000
    ~cycle_cap:20_000_000
    ~seg:250_000
    ();
  Printf.printf
    "\n\
    \  Same profile, video DMA gated OFF — the framebuffer-in-BRAM counterfactual.\n\
    \  (NB a different instruction mix past the first timer poll; the honest same-work\n\
    \  number is the lockstep below.)\n\
     %!";
  stall_profile
    ~video:false
    ~lines_log2:10
    ~write_cycles:5
    ~instr_budget:2_000_000
    ~cycle_cap:20_000_000
    ~seg:250_000
    ();
  Printf.printf
    "\n\
    \  Framebuffer-in-BRAM ceiling — same-work instruction lockstep, video on vs OFF\n\
    \  (cache on, 4KB): what removing ALL video traffic from the PSRAM port buys.\n\
     %!";
  let aligned, _diverged, c_on, c_off, _, _ =
    compare_pair
      ~max_instrs:200_000
      (make_os ~video:true ~write_cycles:5 ~icache:true ~lines_log2:10 ())
      (make_os ~video:false ~write_cycles:5 ~icache:true ~lines_log2:10 ())
  in
  let f = float_of_int in
  Printf.printf
    "    aligned OS instructions : %d\n\
    \    cycles over that prefix : video-on %d   video-off %d\n\
    \    cycles / instruction    : video-on %.2f   video-off %.2f\n\
    \    same-work speedup       : %.3fx  (the whole-machine ceiling of \
     framebuffer-in-BRAM)\n\
     %!"
    aligned
    c_on
    c_off
    (f c_on /. f (max 1 aligned))
    (f c_off /. f (max 1 aligned))
    (f c_on /. f (max 1 c_off));
  Printf.printf
    "\n\
    \  Load-locality sweep (cache on, video live, per-size fetch vs LOAD hit-rate, long \
     window):\n\
     %!";
  Printf.printf "     size    lines    fetch-hit    load-hit    loadW   storeW    CPI\n%!";
  List.iter
    (fun ll2 -> load_point ~lines_log2:ll2 ~instr_budget:1_000_000 ~cycle_cap:15_000_000)
    [ 8; 9; 10; 12; 14; 16 ]
;;
