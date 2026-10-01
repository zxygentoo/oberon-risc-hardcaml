(* The board gauge — a report, not a gate. It boots the board SoC behind the PSRAM model
   ({!Board_tb}) from the real disk to the OS handoff, then runs the OS for a window of
   instructions and watches every system clock. Three gauges:

   - [profile] — where the clocks of the configured machine go: cycles per instruction,
     the share frozen on the PSRAM by cause, the cache hit rates.
   - [ladder] — what each layer of the memory stack buys: the same machine with the cache,
     write-update, the framebuffer shadow and the write buffer added one at a time, each
     rung profiled and compared with the rung above it over the same work.
   - [autopsy] — why reads miss: every cache miss classified by an independent model of
     the cache, which must agree with the design's own hit bit on every read (a
     disagreement fails the run).

   The machine is {!Board_tb.config_of_env}: what the bitstream ships, unless the board
   gates' environment knobs say otherwise — so a candidate change is measured by setting
   its knob (LINES_LOG2=10, WBUF=1, READ_CYCLES=7, ...).

   "The same work": two machines that boot the same disk reach the handoff in the same
   architectural state (the boot checkpoint proves it), and from there execute the same
   instruction stream until the first timing-dependent poll — the SD card, the ms timer —
   sends the faster one down a different path. Over that aligned prefix their cycle counts
   compare like for like; a fixed-length window would average different code.

   Run everything with [dune build @bench_boot], or one gauge with
   [dune exec test/board/nexys-4/bench_boot.exe -- profile | ladder | autopsy]. The
   machines run in parallel, one forked worker each. *)

open Hardcaml
module BCC = Boot_checkpoint_common
module Build_config = Nexys4_board.Build_config
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

let boot_cycle_cap = 200_000_000

(* the window: this many instructions past the handoff, or this many clocks if that comes
   first (the uncached machine spends ~30 clocks on an instruction) *)
let window_instrs = 2_000_000
let window_cycle_cap = 20_000_000
let segment_instrs = 250_000

(* ── One machine under the probes ── *)

(* a CPU access to PSRAM retiring this clock; [wa] is the word address the cache indexes
   (adr[23:2]) *)
type access =
  | Read of
      { wa : int
      ; hit : bool
      ; fetch : bool
      }
  | Store of
      { wa : int
      ; byte : bool
      }

(* Every clock falls in one bucket, from [core_ce] / [is_fetch] / [core_rd] / [core_wr]:
   the core advanced (ce = 1) and retired an instruction, or spent a load/store data
   cycle, or ground through an iterative unit; or it was frozen (ce = 0) waiting on the
   PSRAM for a fetch, a load or a store. *)
let bucket_names = [| "retire"; "exec"; "compute"; "fetchW"; "loadW"; "storeW" |]
let retire = 0
let fetch_wait = 3
let load_wait = 4
let store_wait = 5

type machine =
  { step : unit -> unit (* one system clock, the SD card on the SPI pins *)
  ; pc : unit -> int
  ; bucket : unit -> int
  ; access : unit -> access option
      (* reads are visible only with the cache: it is the cache's read strobe that marks
         them *)
  ; video_bus : unit -> bool (* the PSRAM port is serving a video word *)
  ; cleanup : unit -> unit
  }

let machine (c : Build_config.t) =
  let tmp = BCC.copy_to_temp BCC.disk_image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (Board_tb.create ~datasheet_chip:true c)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let spi = Boot_tb.Spi.attach sim ~miso:inp.miso ~sclk:outp.sclk bridge in
  (* every probe resolves loudly: a silent miss would read as a column of zeros *)
  let node name = Boot_tb.lookup_node sim name in
  let pc = Boot_tb.lookup_reg sim "pc"
  and core_ce = node "core_ce"
  and is_fetch = node "is_fetch"
  and core_wr = node "core_wr"
  and core_rd = node "core_rd"
  and core_adr = node "core_adr"
  and core_ben = node "core_ben"
  and cpu_internal = node "cpu_internal"
  and cr_busy = Boot_tb.lookup_reg sim "cr_busy"
  and cr_op_vid = Boot_tb.lookup_reg sim "cr_op_vid" in
  (* the cache's strobes exist only in a machine that has the cache *)
  let cache = if c.icache then Some (node "cache_read", node "cache_hit") else None in
  let v = Cyclesim.Node.to_int in
  Board_tb.drive_idle inp;
  inp.rst_n := Bits.gnd;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.vdd;
  let bucket () =
    if v core_ce = 1
    then if v is_fetch = 1 then 0 else if v core_rd = 1 || v core_wr = 1 then 1 else 2
    else if v core_wr = 1
    then store_wait
    else if v core_rd = 1
    then load_wait
    else fetch_wait
  in
  let access () =
    if v core_ce <> 1
    then None
    else (
      let wa = (v core_adr lsr 2) land 0x3FFFFF in
      match cache with
      | Some (read, hit) when v read = 1 ->
        Some (Read { wa; hit = v hit = 1; fetch = v is_fetch = 1 })
      | _ ->
        if v core_wr = 1 && v cpu_internal = 0
        then Some (Store { wa; byte = v core_ben = 1 })
        else None)
  in
  (* the two registers read post-edge, the nodes in-cycle: a one-clock skew, noise against
     a video word's ~11 clocks on the port *)
  let video_bus () =
    Cyclesim.Reg.to_int cr_busy = 1 && Cyclesim.Reg.to_int cr_op_vid = 1
  in
  { step = (fun () -> Boot_tb.Spi.tick sim spi)
  ; pc = (fun () -> Cyclesim.Reg.to_int pc)
  ; bucket
  ; access
  ; video_bus
  ; cleanup = (fun () -> BCC.rm_temp tmp)
  }
;;

(* ── One measurement: boot, then the window ── *)

type segment =
  { s_instrs : int
  ; s_cycles : int
  ; s_buckets : int array
  ; s_contend : int
  }

type run =
  { boot_cycles : int (* reset to the handoff *)
  ; instrs : int
  ; cycles : int
  ; buckets : int array
  ; contend : int (* frozen while video owns the port *)
  ; video_port : int (* clocks the port serves video *)
  ; fetch_reads : int
  ; fetch_hits : int
  ; load_reads : int
  ; load_hits : int
  ; stores : int (* PSRAM stores retired *)
  ; segments : segment list
  ; pcs : int array (* pc after each instruction of the window ... *)
  ; at : int array (* ... and the clocks since the handoff when it retired *)
  }

(* [observe ~measuring access] sees every PSRAM access from reset on ([measuring] turns
   true at the handoff) — the autopsy's cache model follows along through it. *)
let measure ?(observe = fun ~measuring:_ _ -> ()) (c : Build_config.t) =
  let m = machine c in
  let boot_cycles = ref 0 in
  while m.pc () >= BCC.rom_region_base do
    if !boot_cycles >= boot_cycle_cap
    then failwith "bench_boot: no handoff within the cycle cap";
    m.step ();
    Option.iter (observe ~measuring:false) (m.access ());
    incr boot_cycles
  done;
  let pcs = Array.make window_instrs 0
  and at = Array.make window_instrs 0 in
  let buckets = Array.make 6 0
  and seg_buckets = Array.make 6 0 in
  let instrs = ref 0
  and cycles = ref 0
  and contend = ref 0
  and video_port = ref 0
  and fetch_reads = ref 0
  and fetch_hits = ref 0
  and load_reads = ref 0
  and load_hits = ref 0
  and stores = ref 0
  and seg_instrs = ref 0
  and seg_cycles = ref 0
  and seg_contend = ref 0
  and segments = ref [] in
  let close_segment () =
    segments
    := { s_instrs = !seg_instrs
       ; s_cycles = !seg_cycles
       ; s_buckets = Array.copy seg_buckets
       ; s_contend = !seg_contend
       }
       :: !segments;
    Array.fill seg_buckets 0 6 0;
    seg_instrs := 0;
    seg_cycles := 0;
    seg_contend := 0
  in
  while !instrs < window_instrs && !cycles < window_cycle_cap do
    m.step ();
    incr cycles;
    incr seg_cycles;
    let b = m.bucket () in
    buckets.(b) <- buckets.(b) + 1;
    seg_buckets.(b) <- seg_buckets.(b) + 1;
    if m.video_bus ()
    then (
      incr video_port;
      if b >= fetch_wait
      then (
        incr contend;
        incr seg_contend));
    (match m.access () with
     | None -> ()
     | Some a ->
       observe ~measuring:true a;
       (match a with
        | Read { hit; fetch = true; _ } ->
          incr fetch_reads;
          if hit then incr fetch_hits
        | Read { hit; fetch = false; _ } ->
          incr load_reads;
          if hit then incr load_hits
        | Store _ -> incr stores));
    if b = retire
    then (
      pcs.(!instrs) <- m.pc ();
      at.(!instrs) <- !cycles;
      incr instrs;
      incr seg_instrs;
      if !seg_instrs = segment_instrs then close_segment ())
  done;
  if !seg_cycles > 0 then close_segment ();
  m.cleanup ();
  { boot_cycles = !boot_cycles
  ; instrs = !instrs
  ; cycles = !cycles
  ; buckets
  ; contend = !contend
  ; video_port = !video_port
  ; fetch_reads = !fetch_reads
  ; fetch_hits = !fetch_hits
  ; load_reads = !load_reads
  ; load_hits = !load_hits
  ; stores = !stores
  ; segments = List.rev !segments
  ; pcs = Array.sub pcs 0 !instrs
  ; at = Array.sub at 0 !instrs
  }
;;

let pct part whole = if whole = 0 then 0.0 else 100.0 *. float part /. float whole
let ratio a b = if b = 0 then 0.0 else float a /. float b
let frozen r = r.buckets.(fetch_wait) + r.buckets.(load_wait) + r.buckets.(store_wait)

(* the instructions two runs execute in common from the handoff, and the clocks each spent
   on them *)
let same_work a b =
  let n = min a.instrs b.instrs in
  let i = ref 0 in
  while !i < n && a.pcs.(!i) = b.pcs.(!i) do
    incr i
  done;
  if !i = 0 then 0, 0, 0 else !i, a.at.(!i - 1), b.at.(!i - 1)
;;

(* ── profile ── *)

let print_profile r =
  Printf.printf
    "  reset to the handoff: %d clocks.  The window past it: %d instructions in %d \
     clocks = %.2f clocks per instruction.\n\n"
    r.boot_cycles
    r.instrs
    r.cycles
    (ratio r.cycles r.instrs);
  Printf.printf
    "    through   instrs    clocks    CPI   fetchW%% loadW%% storeW%% video%%\n";
  let through = ref 0 in
  List.iter
    (fun s ->
      through := !through + s.s_instrs;
      Printf.printf
        "    %6dk  %7d  %8d  %5.2f   %6.1f  %5.1f  %6.1f  %5.1f\n"
        (!through / 1000)
        s.s_instrs
        s.s_cycles
        (ratio s.s_cycles s.s_instrs)
        (pct s.s_buckets.(fetch_wait) s.s_cycles)
        (pct s.s_buckets.(load_wait) s.s_cycles)
        (pct s.s_buckets.(store_wait) s.s_cycles)
        (pct s.s_contend s.s_cycles))
    r.segments;
  Printf.printf "\n    every clock of the window, by what the core was doing:\n";
  Array.iteri
    (fun i n ->
      Printf.printf "      %-8s %9d  %5.1f%%\n" bucket_names.(i) n (pct n r.cycles))
    r.buckets;
  Printf.printf
    "    frozen on the PSRAM: %d clocks = %.1f%% (reads %.1f%%, stores %.1f%%); frozen \
     while video held the port: %.1f%% (video holds it %.1f%% of all clocks)\n"
    (frozen r)
    (pct (frozen r) r.cycles)
    (pct (r.buckets.(fetch_wait) + r.buckets.(load_wait)) r.cycles)
    (pct r.buckets.(store_wait) r.cycles)
    (pct r.contend r.cycles)
    (pct r.video_port r.cycles);
  if r.fetch_reads + r.load_reads > 0
  then
    Printf.printf
      "    cache: fetches %d/%d = %.2f%% hit, loads %d/%d = %.2f%% hit;  %d PSRAM stores \
       (1 per %d instructions)\n"
      r.fetch_hits
      r.fetch_reads
      (pct r.fetch_hits r.fetch_reads)
      r.load_hits
      r.load_reads
      (pct r.load_hits r.load_reads)
      r.stores
      (r.instrs / max 1 r.stores)
;;

(* ── ladder ── *)

(* [top] with the memory stack peeled off, then put back one layer at a time. A layer
   [top] lacks leaves two equal rungs; the later one is dropped. *)
let rungs (top : Build_config.t) =
  let psram =
    { top with
      icache = false
    ; write_update = false
    ; fb_bram = false
    ; halftone = false
    ; write_buffer = false
    ; wbuf_depth = 1
    }
  in
  let cache = { psram with icache = top.icache } in
  let update = { cache with write_update = top.write_update } in
  let shadow = { update with fb_bram = top.fb_bram; halftone = top.halftone } in
  let buffer = { shadow with write_buffer = top.write_buffer } in
  let rec dedupe = function
    | ((_, a) as rung) :: (_, b) :: rest when a = b -> dedupe (rung :: rest)
    | rung :: rest -> rung :: dedupe rest
    | [] -> []
  in
  dedupe
    [ "PSRAM only", psram
    ; "+ cache", cache
    ; "+ write-update", update
    ; "+ framebuffer shadow", shadow
    ; "+ write buffer", buffer
    ; Printf.sprintf "+ depth %d" top.wbuf_depth, top
    ]
;;

let print_ladder named_runs =
  Printf.printf
    "    %-22s %10s %8s %6s %7s %7s %10s %9s   %s\n"
    "rung"
    "boot"
    "instrs"
    "CPI"
    "frozen"
    "storeW"
    "fetch hit"
    "load hit"
    "the same work as the rung above";
  let hit hits reads =
    if reads = 0 then "-" else Printf.sprintf "%.2f%%" (pct hits reads)
  in
  let above = ref None in
  List.iter
    (fun (name, r) ->
      Printf.printf
        "    %-22s %10d %8d %6.2f %6.1f%% %6.1f%% %10s %9s"
        name
        r.boot_cycles
        r.instrs
        (ratio r.cycles r.instrs)
        (pct (frozen r) r.cycles)
        (pct r.buckets.(store_wait) r.cycles)
        (hit r.fetch_hits r.fetch_reads)
        (hit r.load_hits r.load_reads);
      (match !above with
       | None -> Printf.printf "\n"
       | Some a ->
         let n, ca, cr = same_work a r in
         Printf.printf
           "   %.3fx  (%d -> %d clocks over %d instructions)\n"
           (ratio ca cr)
           ca
           cr
           n);
      above := Some r)
    named_runs;
  match named_runs with
  | (_, first) :: _ :: _ ->
    let _, last = List.nth named_runs (List.length named_runs - 1) in
    let n, cf, cl = same_work first last in
    Printf.printf
      "\n\
      \    the whole stack against the PSRAM alone: %.2fx over the same %d instructions \
       (%.2f -> %.2f clocks per instruction)\n"
      (ratio cf cl)
      n
      (ratio cf n)
      (ratio cl n)
  | _ -> ()
;;

(* ── autopsy ── *)

type autopsy =
  { boot_mismatches : int (* model vs the design's hit bit, reset to handoff ... *)
  ; window_mismatches : int (* ... and over the window *)
  ; word_stores : int
  ; byte_stores : int
  ; reads : int array (* per class: 0 = fetch, 1 = load *)
  ; hits : int array
  ; conflict : int array (* the line held another address *)
  ; killed : int array (* the line was dropped by a store to this address *)
  ; cold : int array (* the line was never filled, or dropped by a store to another *)
  }

(* The model keeps a valid bit and a tag per line — the cache's policy with none of its
   data: a read fills its line; a store to a cached word refreshes the line when the
   machine has write-update and the store is a whole word, and drops it otherwise. It
   follows the design from reset (the boot warms the cache) and classifies the misses of
   the window. *)
let autopsy (c : Build_config.t) =
  if not c.icache then failwith "bench_boot autopsy: this machine has no cache";
  let lines = 1 lsl c.lines_log2 in
  let valid = Array.make lines false
  and tag = Array.make lines 0
  and killed_tag = Array.make lines (-1) in
  let boot_mismatches = ref 0
  and window_mismatches = ref 0
  and word_stores = ref 0
  and byte_stores = ref 0 in
  let reads = [| 0; 0 |]
  and hits = [| 0; 0 |]
  and conflict = [| 0; 0 |]
  and killed = [| 0; 0 |]
  and cold = [| 0; 0 |] in
  let bump a k = a.(k) <- a.(k) + 1 in
  let observe ~measuring access =
    match access with
    | Read { wa; hit; fetch } ->
      let i = wa land (lines - 1)
      and t = wa lsr c.lines_log2 in
      let k = if fetch then 0 else 1 in
      if (valid.(i) && tag.(i) = t) <> hit
      then incr (if measuring then window_mismatches else boot_mismatches);
      if measuring
      then (
        bump reads k;
        if hit
        then bump hits k
        else if valid.(i)
        then bump conflict k
        else if killed_tag.(i) = t
        then bump killed k
        else bump cold k);
      valid.(i) <- true;
      tag.(i) <- t;
      killed_tag.(i) <- -1
    | Store { wa; byte } ->
      let i = wa land (lines - 1)
      and t = wa lsr c.lines_log2 in
      if measuring then incr (if byte then byte_stores else word_stores);
      if valid.(i) && tag.(i) = t && not (c.write_update && not byte)
      then (
        valid.(i) <- false;
        killed_tag.(i) <- t)
  in
  let (_ : run) = measure ~observe c in
  { boot_mismatches = !boot_mismatches
  ; window_mismatches = !window_mismatches
  ; word_stores = !word_stores
  ; byte_stores = !byte_stores
  ; reads
  ; hits
  ; conflict
  ; killed
  ; cold
  }
;;

(* returns whether the model and the design agreed *)
let print_autopsy a =
  let agreed = a.boot_mismatches = 0 && a.window_mismatches = 0 in
  Printf.printf
    "  the cache model against the design's hit bit: %d disagreements through the boot, \
     %d over the window%s\n"
    a.boot_mismatches
    a.window_mismatches
    (if agreed then "" else "  ** the numbers below are suspect **");
  Printf.printf
    "  stores to PSRAM in the window: %d word, %d byte\n\n"
    a.word_stores
    a.byte_stores;
  Printf.printf
    "    %-6s %9s %8s %8s   %-18s %-18s %s\n"
    "reads"
    "count"
    "hit"
    "misses"
    "conflict"
    "dropped by a store"
    "cold";
  List.iteri
    (fun k name ->
      let misses = a.reads.(k) - a.hits.(k) in
      let share n = Printf.sprintf "%d (%.1f%%)" n (pct n misses) in
      Printf.printf
        "    %-6s %9d %7.2f%% %8d   %-18s %-18s %s\n"
        name
        a.reads.(k)
        (pct a.hits.(k) a.reads.(k))
        misses
        (share a.conflict.(k))
        (share a.killed.(k))
        (share a.cold.(k)))
    [ "fetch"; "load" ];
  agreed
;;

(* ── The report ── *)

(* what a forked worker hands back *)
type result =
  | Run of run
  | Autopsy of autopsy

let in_parallel jobs = Fork_pool.map ~jobs:(List.length jobs) jobs

let () =
  let top = Board_tb.config_of_env () in
  let shipped = Build_config.shipped in
  Printf.printf
    "The board gauge — %s machine:\n  %s\n"
    (if top = shipped then "the SHIPPED" else "an OVERRIDDEN (not the shipped)")
    (Build_config.to_string top);
  if top.spi_slow_div_log2 <> shipped.spi_slow_div_log2
  then
    Printf.printf
      "  NB the SPI divider is not the shipped one: boot-cycle counts are not comparable \
       with shipped-divider runs (the window figures are).\n";
  Printf.printf "%!";
  let rungs = rungs top in
  let ladder_jobs = List.map (fun (_, c) () -> Run (measure c)) rungs in
  let report_ladder results =
    let runs =
      List.filter_map
        (function
          | Run r -> Some r
          | Autopsy _ -> None)
        results
    in
    Printf.printf "\nThe memory stack, one layer at a time:\n\n";
    print_ladder (List.map2 (fun (name, _) r -> name, r) rungs runs);
    runs
  and report_profile r =
    Printf.printf "\nWhere the clocks go:\n\n";
    print_profile r
  and report_autopsy a =
    Printf.printf "\nWhy reads miss:\n\n";
    if not (print_autopsy a) then exit 1
  in
  match List.tl (Array.to_list Sys.argv) with
  | [ "profile" ] -> report_profile (measure top)
  | [ "ladder" ] -> ignore (report_ladder (in_parallel ladder_jobs) : run list)
  | [ "autopsy" ] -> report_autopsy (autopsy top)
  | [] | [ "all" ] ->
    (* the ladder's last rung is the configured machine, so its run is the profile *)
    let autopsy_jobs = if top.icache then [ (fun () -> Autopsy (autopsy top)) ] else [] in
    let results = in_parallel (ladder_jobs @ autopsy_jobs) in
    let runs = report_ladder results in
    report_profile (List.nth runs (List.length runs - 1));
    List.iter
      (function
        | Autopsy a -> report_autopsy a
        | Run _ -> ())
      results
  | _ ->
    prerr_endline "usage: bench_boot [all | profile | ladder | autopsy]";
    exit 2
;;
