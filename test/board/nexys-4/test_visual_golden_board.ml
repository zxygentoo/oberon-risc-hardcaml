(* Phase-10a — board visual golden WITH the I-cache: the definitive coherence proof.

   The Phase-6b visual golden (test_visual_golden.ml) renders the idle Oberon desktop on
   the flat-BRAM {!Risc5.Soc} and asserts it is byte-identical to the oracle. This variant
   runs the *board* SoC ({!Nexys4_board.Soc} + the {!Nexys4_board.Cellram_model} PSRAM
   double, via the shared {!Board_tb}) with the Phase-10a I-cache ON, past the handoff,
   and asserts the *same* framebuffer against the oracle. That is the strong coherence
   test: if the cache ever served stale code/data — the module loader writing code the
   cache holds, or a framebuffer word the CPU cached being overwritten — the desktop would
   render wrong and the hash would differ. Byte-identical ⇒ the cache is transparent
   through the whole boot + module load + desktop render, not just the boot-to-handoff
   prefix the lockstep bench covers.

   Feasibility note: this is practical *only* with the cache. Cache-off the board runs OS
   code at ~26 cyc/instr, so drawing the desktop would take hundreds of millions of
   cycles; the cache's ~6x (down to ~4.4 cyc/instr) brings it into interpreter range. So
   the cache is what makes a board-level visual golden runnable at all. (AGENT.md §5 Phase
   10.)

   The fb geometry, oracle boot, settle loop and verdict are shared in
   {!Boot_checkpoint_common}; the SPI drive in {!Boot_tb}. This file keeps what is
   board-specific: the knobs, the board wait counts, and the FB_BRAM shadow readback + its
   coherence check.

   Opt-in: dune build @visual_golden_board. Env: SOC_CAP overrides the cycle cap, ICACHE=0
   runs the (much slower) cache-off control, WRITE_UPDATE=1 the Phase-10b snoop policy,
   FB_BRAM=1 the Phase-10c framebuffer shadow (the golden then reads the *shadow* — the
   words the screen actually shows — and additionally asserts shadow ≡ PSRAM framebuffer
   window over the full span, the shadow's own coherence invariant), DISK_IMG the image. *)

open Hardcaml
module BCC = Boot_checkpoint_common
module Sim = Cyclesim.With_interface (Board_tb.I) (Board_tb.O)

(* Boot the board SoC (SD card via {!Sd_bridge}) with the cache [icache], run PAST the
   handoff until the framebuffer — reconstructed from the PSRAM model's two byte lanes via
   {!Board_tb.read_word}, or from the {!Nexys4_board.Framebuf} shadow under [fb_bram] —
   settles or [cap] cycles. read_cycles = 6 / write_cycles = 5 to match the board timing
   the golden is defending (emit_verilog.ml). *)
let boot_board
  ~icache
  ~write_update
  ~fb_bram
  ~halftone
  ~write_buffer
  ~wbuf_depth
  ~target
  ~cap
  ~chunk
  ~settle
  =
  let tmp = BCC.copy_to_temp BCC.disk_image in
  let bridge = Sd_bridge.create (Emu.Disk.to_spi (Emu.Disk.create (Some tmp))) in
  let spi_slow_div_log2 = Option.map int_of_string (Sys.getenv_opt "SPI_DIV_LOG2") in
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (fun i ->
      Board_tb.create
        ?spi_slow_div_log2
        ~read_cycles:6
        ~write_cycles:5
        ~icache
        ~write_update
        ~fb_bram
        ~halftone
        ~write_buffer
        ~wbuf_depth
        i)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let spi = Boot_tb.Spi.attach sim ~miso:inp.miso ~sclk:outp.sclk bridge in
  let pc = Boot_tb.lookup_reg sim "pc" in
  let cram_lo = Boot_tb.lookup_mem sim "cram_lo"
  and cram_hi = Boot_tb.lookup_mem sim "cram_hi" in
  (* under FB_BRAM the golden reads the *shadow* — the words the raster actually fetches;
     the PSRAM window stays readable for the shadow-equality check below *)
  let fb_lanes =
    if fb_bram
    then Some (Array.init 4 (fun k -> Boot_tb.lookup_mem sim (Printf.sprintf "fb%d" k)))
    else None
  in
  let shadow_word lanes idx =
    let b k = Cyclesim.Memory.to_int lanes.(k) ~address:idx in
    b 0 lor (b 1 lsl 8) lor (b 2 lsl 16) lor (b 3 lsl 24)
  in
  let read_fb () =
    match fb_lanes with
    | Some lanes ->
      Array.init BCC.fb_words (fun i ->
        shadow_word lanes (BCC.fb_base_word - Nexys4_board.Framebuf.base + i))
    | None ->
      Array.init BCC.fb_words (fun i ->
        Board_tb.read_word ~cram_lo ~cram_hi (BCC.fb_base_word + i))
  in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  Board_tb.drive_idle inp;
  inp.rst_n := lo;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  let fb, settled =
    BCC.run_to_settle
      ~target
      ~cap
      ~chunk
      ~settle
      ~tick:(fun () -> Boot_tb.Spi.tick sim spi)
      ~read_fb
      ~pc:(fun () -> Cyclesim.Reg.to_int pc)
      ~spi_bytes:(fun () -> Sd_bridge.nbytes bridge)
      ()
  in
  (* the shadow's own invariant, checked over the FULL span at the settled (quiet) point:
     every shadow word equals its PSRAM word — both zero-initialised, and every in-window
     store wrote both, so any mismatch is a shadow write-path bug *)
  let shadow_mismatches =
    match fb_lanes with
    | None -> None
    | Some lanes ->
      let m = ref 0 in
      for idx = 0 to Nexys4_board.Framebuf.size - 1 do
        if shadow_word lanes idx
           <> Board_tb.read_word ~cram_lo ~cram_hi (Nexys4_board.Framebuf.base + idx)
        then incr m
      done;
      Some !m
  in
  BCC.rm_temp tmp;
  fb, settled, shadow_mismatches
;;

let () =
  let icache =
    match Sys.getenv_opt "ICACHE" with
    | Some "0" -> false
    | _ -> true
  in
  (* opt-in (Phase-10b): WRITE_UPDATE=1 runs the golden with the write-update snoop policy
     — the byte-identical desktop is its coherence proof, like Phase-10a's *)
  let write_update =
    match Sys.getenv_opt "WRITE_UPDATE" with
    | Some "1" -> true
    | _ -> false
  in
  (* opt-in (Phase-10c): FB_BRAM=1 serves video from the Framebuf BRAM shadow; the golden
     then hashes the shadow (what the screen shows) and asserts shadow ≡ PSRAM window *)
  let fb_bram =
    match Sys.getenv_opt "FB_BRAM" with
    | Some "1" -> true
    | _ -> false
  in
  (* opt-in (Phase-10d): WBUF=n runs the golden with the n-entry write buffer (n >= 1;
     unset/0 = off) — the byte-identical desktop + shadow check is its coherence/ordering
     proof at that depth *)
  let wbuf_depth =
    match Sys.getenv_opt "WBUF" with
    | Some s -> int_of_string s
    | None -> 0
  in
  let write_buffer = wbuf_depth >= 1 in
  (* opt-in (feat/halftone): HALFTONE=1 instantiates the Halftone scanout ditherer with
     its mode bit never written — the byte-identical desktop is the do-no-harm gate (the
     mux at mode 0 must leave the proven Framebuf path untouched) *)
  let halftone =
    match Sys.getenv_opt "HALFTONE" with
    | Some "1" -> true
    | _ -> false
  in
  let oracle_fb, oracle_hash = BCC.boot_oracle_fb ~frames:40 in
  Printf.printf
    "oracle (frames=40): hash=0x%Lx  %d set px\n%!"
    oracle_hash
    (BCC.popcount oracle_fb);
  Printf.printf
    "booting BOARD SoC (Cellram PSRAM, icache=%b write_update=%b fb_bram=%b halftone=%b \
     write_buffer=%b depth=%d) past the handoff — cache makes this feasible...\n\
     %!"
    icache
    write_update
    fb_bram
    halftone
    write_buffer
    wbuf_depth;
  let cap =
    match Sys.getenv_opt "SOC_CAP" with
    | Some s -> int_of_string s
    | None -> 160_000_000
  in
  let soc_fb, settled, shadow_mismatches =
    boot_board
      ~icache
      ~write_update
      ~fb_bram
      ~halftone
      ~write_buffer
      ~wbuf_depth:(max 1 wbuf_depth)
      ~target:oracle_hash
      ~cap
      ~chunk:2_000_000
      ~settle:3
  in
  (match shadow_mismatches with
   | None -> ()
   | Some 0 ->
     Printf.printf
       "shadow check: all %d shadow words = PSRAM framebuffer window (coherent)\n%!"
       Nexys4_board.Framebuf.size
   | Some m ->
     Printf.printf
       "shadow check FAIL: %d/%d shadow words differ from the PSRAM window\n%!"
       m
       Nexys4_board.Framebuf.size;
     exit 1);
  let soc_hash = BCC.fb_fnv soc_fb in
  Printf.printf
    "soc (icache=%b): hash=0x%Lx  %d set px  settled=%b\n%!"
    icache
    soc_hash
    (BCC.popcount soc_fb)
    settled;
  BCC.golden_report
    ~tag:(Printf.sprintf " (BOARD, icache=%b)" icache)
    ~subject:"board-SoC"
    ~render_label:(Printf.sprintf "SoC (board, icache=%b)" icache)
    ~pass_tail:". The I-cache is transparent through boot + module load + desktop render."
    ~oracle_fb
    ~oracle_hash
    ~soc_fb
    ~soc_hash
    ~settled
;;
