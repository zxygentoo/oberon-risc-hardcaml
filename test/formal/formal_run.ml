open! Base
open Hardcaml

(* cd to the repo root so every relative path (test/_po, test/_work, the spec .v) resolves
   no matter where we're launched — directly, via dune exec, or as the @formal dune
   action. Mirrors cosim_run; called once at the top of the only [let ()]. The only
   remaining bash is the toolchain-free fetch-rtl.sh. *)
let cd_to_repo_root () =
  let rec up d =
    if Stdlib.Sys.file_exists (Stdlib.Filename.concat d "dune-project")
    then Stdlib.Sys.chdir d
    else (
      let parent = Stdlib.Filename.dirname d in
      if String.equal parent d
      then failwith "formal_run: no dune-project above cwd"
      else up parent)
  in
  up (Stdlib.Sys.getcwd ())
;;

(* ── Combinational units: our circuit's ports match the reference .v; proven by importing
   the .v and SAT-checking against ours with hardcaml_verify's Sec + z3 (Formal_equiv). ── *)

let left_shifter () =
  let module C = Circuit.With_interface (Risc5.Left_shifter.I) (Risc5.Left_shifter.O) in
  C.create_exn ~name:"LeftShifter" Risc5.Left_shifter.create
;;

let right_shifter () =
  let module C = Circuit.With_interface (Risc5.Right_shifter.I) (Risc5.Right_shifter.O) in
  C.create_exn ~name:"RightShifter" Risc5.Right_shifter.create
;;

(* ── Sequential units: built with ports named to match the .v (clk/run/u/x/y → stall/z)
   and registers named to match (S/P, in the lib) so yosys equiv_make can pair the
   flip-flops; proven by emitting our Verilog and running yosys equiv_induct
   (Yosys_equiv). The circuit is named distinctly from the reference module so yosys can
   read both. ── *)

let multiplier () =
  let open Signal in
  let i =
    { Risc5.Multiplier.I.clock = input "clk" 1
    ; run = input "run" 1
    ; u = input "u" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Multiplier.O.stall; z } = Risc5.Multiplier.create i in
  Circuit.create_exn ~name:"multiplier_ours" [ output "stall" stall; output "z" z ]
;;

let divider () =
  let open Signal in
  let i =
    { Risc5.Divider.I.clock = input "clk" 1
    ; run = input "run" 1
    ; u = input "u" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Divider.O.stall; quot; rem } = Risc5.Divider.create i in
  Circuit.create_exn
    ~name:"divider_ours"
    [ output "stall" stall; output "quot" quot; output "rem" rem ]
;;

let fp_adder () =
  let open Signal in
  let i =
    { Risc5.Fp_adder.I.clock = input "clk" 1
    ; run = input "run" 1
    ; u = input "u" 1
    ; v = input "v" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Fp_adder.O.stall; z } = Risc5.Fp_adder.create i in
  Circuit.create_exn ~name:"fp_adder_ours" [ output "stall" stall; output "z" z ]
;;

let fp_multiplier () =
  let open Signal in
  let i =
    { Risc5.Fp_multiplier.I.clock = input "clk" 1
    ; run = input "run" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Fp_multiplier.O.stall; z } = Risc5.Fp_multiplier.create i in
  Circuit.create_exn ~name:"fp_multiplier_ours" [ output "stall" stall; output "z" z ]
;;

let fp_divider () =
  let open Signal in
  let i =
    { Risc5.Fp_divider.I.clock = input "clk" 1
    ; run = input "run" 1
    ; x = input "x" 32
    ; y = input "y" 32
    }
  in
  let { Risc5.Fp_divider.O.stall; z } = Risc5.Fp_divider.create i in
  Circuit.create_exn ~name:"fp_divider_ours" [ output "stall" stall; output "z" z ]
;;

(* ── Tier-1 peripherals: the clean, single-clock peripheral FSMs with a direct standalone
   .v (RS232R/T, SPI, PS2). Same sequential recipe as the iterative units — emit our
   Verilog, equiv_make pairs flip-flops by name, equiv_induct closes. Already Verilator-
   cosim'd (Phase 6a); this is the exhaustive upgrade (AGENT.md §6, README "Planned").

   Ports are named to match the .v; [rst_n] maps to the RTL's active-low [rst] port (same
   wire — ours does [~:rst_n], the RTL does [~rst]). Our lib registers keep their
   waveform/SoC-namespaced names; where they differ from the RTL we rename them to the
   .v's in the yosys script (the [renames] column), exactly as the core proof does. ── *)

let rs232t () =
  let open Signal in
  let i =
    { Risc5.Uart_tx.I.clock = input "clk" 1
    ; rst_n = input "rst" 1
    ; start = input "start" 1
    ; fsel = input "fsel" 1
    ; data = input "data" 8
    }
  in
  let { Risc5.Uart_tx.O.rdy; txd } = Risc5.Uart_tx.create i in
  (* run/tick/bitcnt/shreg already match RS232T.v — no renames needed. *)
  Circuit.create_exn ~name:"rs232t_ours" [ output "rdy" rdy; output "TxD" txd ]
;;

let rs232r () =
  let open Signal in
  let i =
    { Risc5.Uart_rx.I.clock = input "clk" 1
    ; rst_n = input "rst" 1
    ; rxd = input "RxD" 1
    ; fsel = input "fsel" 1
    ; done_ = input "done" 1
    }
  in
  let { Risc5.Uart_rx.O.rdy; data } = Risc5.Uart_rx.create i in
  (* run/stat/tick/bitcnt/shreg match RS232R.v; only the synchronizer FFs differ in case. *)
  Circuit.create_exn ~name:"rs232r_ours" [ output "rdy" rdy; output "data" data ]
;;

let spi () =
  let open Signal in
  let i =
    { Risc5.Spi.I.clock = input "clk" 1
    ; rst_n = input "rst" 1
    ; start = input "start" 1
    ; fast = input "fast" 1
    ; data_tx = input "dataTx" 32
    ; miso = input "MISO" 1
    }
  in
  let { Risc5.Spi.O.data_rx; rdy; mosi; sclk } = Risc5.Spi.create i in
  (* tick/bitcnt/rdy match SPI.v; our shift register is SoC-namespaced [spi_shreg]. *)
  Circuit.create_exn
    ~name:"spi_ours"
    [ output "dataRx" data_rx; output "rdy" rdy; output "MOSI" mosi; output "SCLK" sclk ]
;;

let ps2 () =
  let open Signal in
  let i =
    { Risc5.Ps2.I.clock = input "clk" 1
    ; rst_n = input "rst" 1
    ; done_ = input "done" 1
    ; ps2c = input "PS2C" 1
    ; ps2d = input "PS2D" 1
    }
  in
  let { Risc5.Ps2.O.rdy; shift; data } = Risc5.Ps2.create i in
  (* shreg/inptr/outptr and the [fifo] memory match PS2.v; only the synchronizer FFs
     differ in case. The [memory] pass lowers both fifos (single 16x8 arrays) to FFs that
     pair by name — the same mechanism as the register-file proof. *)
  Circuit.create_exn
    ~name:"ps2_ours"
    [ output "rdy" rdy; output "shift" shift; output "data" data ]
;;

(* Mouse (Tier 2): MousePM.v's [MouseP] has open-drain [inout msclk, msdat]; our port
   splits each into a drive-low [*_oe] output + the resolved-value input. A Verilog shim
   ([mouse_shim.v]) recombines them back into the RTL's inout, and the shimmed gate is
   proven ≡ MouseP (see [run_mouse] + [proofs/mouse.ys.template]). *)
let mouse () =
  let open Signal in
  let i =
    { Risc5.Mouse.I.clock = input "clk" 1
    ; rst_n = input "rst" 1
    ; msclk = input "msclk" 1
    ; msdat = input "msdat" 1
    }
  in
  let { Risc5.Mouse.O.msclk_oe; msdat_oe; out } = Risc5.Mouse.create i in
  (* rx/count/filter/tx/x/y/btns/sent/req all match MousePM.v once count/filter are named. *)
  Circuit.create_exn
    ~name:"mouse_ours"
    [ output "msclk_oe" msclk_oe; output "msdat_oe" msdat_oe; output "out" out ]
;;

(* VID (Tier 2): two clock domains (pclk raster + clk DMA), and TWO deliberate departures
   from VID60.v: (1) the framebuffer-fetch CDC (our toggle pulse-synchroniser vs the RTL's
   async-set [req1]), and (2) the 2-group fetch PREFETCH (our look-ahead [vidadr] +
   ping-pong banks vs the RTL's single [vidbuf] / current-group address — the board's
   flicker fix). The gold side needs prep (stub the DCM, [chparam RGBW=6], expose [pclk]);
   the proof cuts [vidbuf] (our ping-pong read mux, named to pair with the RTL) to a
   shared free input so the raster + pixel path prove bit-exact GIVEN the same word, and
   excludes BOTH departed outputs ([req], [vidadr]). The [req] departure is closed by
   [vid_invariant]; the [vidadr] delivery is checked by a co-located sim test (a formal
   all-phases version was prototyped but does not converge tractably — col 0 is
   cross-line; see README "VID prefetch"). See [run_vid] + [proofs/vid.ys.template]. *)
let vid () =
  let open Signal in
  let i =
    { Risc5.Vid.I.clk = input "clk" 1
    ; pclk = input "pclk" 1
    ; inv = input "inv" 1
    ; viddata = input "viddata" 32
    }
  in
  let { Risc5.Vid.O.req; vidadr; hsync; vsync; rgb } = Risc5.Vid.create i in
  Circuit.create_exn
    ~name:"vid_ours"
    [ output "req" req
    ; output "vidadr" vidadr
    ; output "hsync" hsync
    ; output "vsync" vsync
    ; output "RGB" rgb
    ]
;;

(* The VID fetch-CDC invariant (the part run_vid cuts): the toggle pulse synchroniser
   [Vid.pulse_sync], isolated with [req0] as an input, so the property harness
   ([vid_invariant.v]) can drive it and assert one-req-per-req0. Proven by BMC, not equiv
   (it's a protocol property, not a cycle-equivalence). *)
let pulse_sync () =
  let open Signal in
  let clk = input "clk" 1 in
  let pclk = input "pclk" 1 in
  let req0 = input "req0" 1 in
  let req =
    Risc5.Vid.pulse_sync
      ~src_spec:(Reg_spec.create () ~clock:pclk)
      ~dst_spec:(Reg_spec.create () ~clock:clk)
      ~pulse:req0
  in
  Circuit.create_exn ~name:"pulse_sync_ours" [ output "req" req ]
;;

(* VID prefetch addressing (the [vidadr] departure the [vid] equiv excludes): the real
   look-ahead logic [Vid.lookahead], with the raster counters as free inputs so it is a
   pure combinational function of (hcnt, vcnt). Proven ≡ [vid_addr_spec] below by Sec/z3. *)
let vid_addr_ours () =
  let open Signal in
  let hcnt = input "hcnt" 11 in
  let vcnt = input "vcnt" 10 in
  let { Risc5.Vid.Lookahead.next_col; next_vcnt; vidadr; wpar } =
    Risc5.Vid.lookahead ~hcnt ~vcnt
  in
  Circuit.create_exn
    ~name:"vid_addr_ours"
    [ output "next_col" next_col
    ; output "next_vcnt" next_vcnt
    ; output "vidadr" vidadr
    ; output "wpar" wpar
    ]
;;

(* Independent geometry spec for the look-ahead address — written from the screen geometry
   directly and in a deliberately DIFFERENT style from lib/vid.ml, so the equivalence is a
   real cross-check, not a restatement:
   - next column by natural 5-bit wrap ([col + 1] mod 32) vs vid.ml's explicit [col==31]
     mux
   - address by shift/add packing vs vid.ml's [concat_msb]
   - the framebuffer base and the geometry constants (32 px/group, 768 visible rows ⇒ last
     row 767) are restated here as the audited spec, pinning vid.ml's [org]/wrap. (The row
     wrap 767→0 is not a power of two, so both sides need the same explicit compare —
     there it is a value-pin/regression-guard, like the register-file spec.) *)
let vid_addr_spec () =
  let open Signal in
  let hcnt = input "hcnt" 11 in
  let vcnt = input "vcnt" 10 in
  let org = of_unsigned_int ~width:18 0x37FC0 in
  (* framebuffer base Org = 0xDFF00 >> 2 *)
  let col = select hcnt ~high:9 ~low:5 in
  (* the 32-px column, 0..31 *)
  let ncol = col +:. 1 in
  (* 5-bit wrap: 31 + 1 = 0 *)
  let nrow = mux2 (col ==:. 31) (mux2 (vcnt ==:. 767) (zero 10) (vcnt +:. 1)) vcnt in
  let vidadr = org +: uresize ncol ~width:18 +: sll (uresize ~:nrow ~width:18) ~by:5 in
  Circuit.create_exn
    ~name:"vid_addr_spec"
    [ output "next_col" ncol
    ; output "next_vcnt" nrow
    ; output "vidadr" vidadr
    ; output "wpar" (lsb ncol)
    ]
;;

(* ── Behavioural-spec proof: the register file ── proven not against Wirth's Registers.v
   (64 duplicated, bit-sliced RAM16X1D primitives — structurally incongruent state that
   defeats FF-pairing and isn't inductive for a memory miter; see README) but against the
   behavioural CONTRACT it implements (registers_spec.v: 16x32, 3 async reads, 1 sync
   write). Both sides are a single array, so the [memory] pass lowers them to FFs that
   pair by name and equiv_induct closes. AGENT.md §2/§3: the register file is the
   canonical "structure is not the spec" case. ── *)

let registers () =
  let open Signal in
  let i =
    { Risc5.Registers.I.clock = input "clk" 1
    ; wr = input "wr" 1
    ; rno0 = input "rno0" 4
    ; rno1 = input "rno1" 4
    ; rno2 = input "rno2" 4
    ; din = input "din" 32
    }
  in
  let { Risc5.Registers.O.dout0; dout1; dout2 } = Risc5.Registers.create i in
  Circuit.create_exn
    ~name:"registers_ours"
    [ output "dout0" dout0; output "dout1" dout1; output "dout2" dout2 ]
;;

(* ── Runner ── *)

(* Scratch root: in-repo + self-contained (git-ignored test/_work; formal_run cd's to the
   repo root at startup, so this relative path resolves there). Each check runs in its own
   subdir test/_work/formal/<name>, so the parallel pool's per-check yosys/z3 files never
   collide. *)
let work_root = "test/_work/formal"
let rtl_dir = "test/_po/verilog/src" (* Wirth's originals, fetched on demand *)

let proofs_dir =
  "test/formal/proofs" (* the .ys.template proofs + the .v specs they read *)
;;

let run_combinational ~work_dir (name, ours, v, top_module) =
  match
    Formal_equiv.check ~work_dir ~verilog:(rtl_dir ^ "/" ^ v) ~top_module ~ours:(ours ())
  with
  | Formal_equiv.Equivalent ->
    Stdio.printf
      "%s: EQUIVALENT — no input makes the outputs differ  (vs %s, combinational · Sec/z3)\n\
       %!"
      name
      v;
    true
  | Formal_equiv.Counterexample ->
    Stdio.printf
      "%s: NOT EQUIVALENT — counterexample found  (vs %s, combinational · Sec/z3)\n%!"
      name
      v;
    false
;;

(* Print [ok]/[bad] for a {!Yosys_equiv.result} and return passed?. *)
let report ~ok ~bad result =
  match (result : Yosys_equiv.result) with
  | Yosys_equiv.Equivalent ->
    Stdio.printf "%s\n%!" ok;
    true
  | Yosys_equiv.Not_equivalent ->
    Stdio.printf "%s\n%!" bad;
    false
;;

(* The shared wording for the equiv_induct family — every sequential unit + the mouse. *)
let report_seq ~name ~v ~kind =
  report
    ~ok:
      (Printf.sprintf
         "%s: EQUIVALENT — induction closed, all $equiv proven  (vs %s, %s)"
         name
         v
         kind)
    ~bad:
      (Printf.sprintf
         "%s: NOT EQUIVALENT — $equiv cells left unproven  (vs %s, %s)"
         name
         v
         kind)
;;

(* Every clean single-clock FSM proof: [proofs/sequential.ys.template] filled per row and
   run by [Yosys_equiv.run_proof]. [dir] is the reference .v's directory (rtl_dir for the
   Wirth originals, proofs_dir for registers_spec.v). *)
let run_sequential ~work_dir ~dir ~kind (name, ours, v, top_module, renames) =
  let ours = ours () in
  Yosys_equiv.run_proof
    ~work_dir
    ~ours
    ~template:(proofs_dir ^ "/sequential.ys.template")
    ~subst:
      [ "rtl", dir ^ "/" ^ v
      ; "top", top_module
      ; "renames", Yosys_equiv.renames_block ~gate:(Circuit.name ours) ~renames
      ]
    ()
  |> report_seq ~name ~v ~kind
;;

let combinational : (string * (unit -> Circuit.t) * string * string) list =
  [ "left_shifter", left_shifter, "LeftShifter.v", "LeftShifter"
  ; "right_shifter", right_shifter, "RightShifter.v", "RightShifter"
  ]
;;

(* Rows: (name, circuit thunk, reference .v, top module, register renames). [renames] is
   [[]] when our register names already match the RTL (the iterative units name S/P/…
   after it; RS232T's run/tick/bitcnt/shreg line up). The peripherals that keep
   waveform/SoC- namespaced lib names rename to the .v's here (e.g. [q0→Q0],
   [spi_shreg→shreg]). *)
let sequential
  : (string * (unit -> Circuit.t) * string * string * (string * string) list) list
  =
  [ "multiplier", multiplier, "Multiplier.v", "Multiplier", []
  ; "divider", divider, "Divider.v", "Divider", []
  ; "fp_adder", fp_adder, "FPAdder.v", "FPAdder", []
  ; "fp_multiplier", fp_multiplier, "FPMultiplier.v", "FPMultiplier", []
  ; "fp_divider", fp_divider, "FPDivider.v", "FPDivider", []
  ; "rs232t", rs232t, "RS232T.v", "RS232T", []
  ; "rs232r", rs232r, "RS232R.v", "RS232R", [ "q0", "Q0"; "q1", "Q1" ]
  ; "spi", spi, "SPI.v", "SPI", [ "spi_shreg", "shreg" ]
  ; "ps2", ps2, "PS2.v", "PS2", [ "q0", "Q0"; "q1", "Q1" ]
  ]
;;

(* Proven against our behavioural spec ([proofs/registers_spec.v]), not a Wirth original
   (see [registers]). *)
let behavioral
  : (string * (unit -> Circuit.t) * string * string * (string * string) list) list
  =
  [ "registers", registers, "registers_spec.v", "Registers_spec", [] ]
;;

(* The in-situ core-glue proof (AGENT.md §6, README): our whole core's glue (decode, the
   inline ALU, control, flags, the 13 state registers) ≡ RISC5.v with the 8 submodules
   black-boxed and assumed-equivalent (each proven separately). [Core_blackbox] builds the
   gate (Instantiation stubs for the units); [proofs/core.ys.template] merges the matched
   black-box cells, cutpoint -blackbox cuts their outputs, equiv_induct closes the glue. *)
let run_core ~work_dir =
  let ours = Core_blackbox.circuit () in
  Yosys_equiv.run_proof
    ~work_dir
    ~ours
    ~template:(proofs_dir ^ "/core.ys.template")
    ~subst:
      [ "rtl", rtl_dir ^ "/RISC5.v"
      ; "stubs", proofs_dir ^ "/core_stubs.v"
      ; "top", "RISC5"
      ; ( "renames"
        , Yosys_equiv.renames_block
            ~gate:(Circuit.name ours)
            ~renames:Core_blackbox.register_renames )
      ]
    ()
  |> report
       ~ok:
         "core: EQUIVALENT — glue proven, all $equiv closed; units assumed-equiv  (vs \
          RISC5.v, in-situ · 8 units black-boxed · yosys equiv_induct)"
       ~bad:
         "core: NOT EQUIVALENT — $equiv cells left unproven  (vs RISC5.v, in-situ · 8 \
          units black-boxed · yosys equiv_induct)"
;;

(* The Mouse (Tier 2): MouseP's open-drain [inout] needs the two-shim recombination +
   tristate lowering — see [proofs/mouse_shim.v] and [proofs/mouse.ys.template]. [renames]
   strips the [g.] instance prefix the flatten adds, pairing the wrapped FFs back to the
   RTL's names (which our lib already matches: rx/count/filter/tx/x/y/btns/sent/req). *)
let mouse_renames =
  [ "g.rx", "rx"
  ; "g.count", "count"
  ; "g.filter", "filter"
  ; "g.tx", "tx"
  ; "g.x", "x"
  ; "g.y", "y"
  ; "g.btns", "btns"
  ; "g.sent", "sent"
  ; "g.req", "req"
  ]
;;

(* The Mouse proof: the open-drain split needs two rename blocks (one per shim), supplied
   as [{gold_renames}] / [{ours_renames}]; everything else is the same shape as a
   sequential proof. *)
let run_mouse ~work_dir =
  Yosys_equiv.run_proof
    ~work_dir
    ~ours:(mouse ())
    ~template:(proofs_dir ^ "/mouse.ys.template")
    ~subst:
      [ "rtl", rtl_dir ^ "/MousePM.v"
      ; "shims", proofs_dir ^ "/mouse_shim.v"
      ; "gold_shim", "mouse_gold_shim"
      ; "ours_shim", "mouse_ours_shim"
      ; ( "gold_renames"
        , Yosys_equiv.renames_block ~gate:"mouse_gold_shim" ~renames:mouse_renames )
      ; ( "ours_renames"
        , Yosys_equiv.renames_block ~gate:"mouse_ours_shim" ~renames:mouse_renames )
      ]
    ()
  |> report_seq ~name:"mouse" ~v:"MousePM.v" ~kind:"open-drain inout · yosys equiv_induct"
;;

(* VID (Tier 2): two-clock, with TWO deliberate departures from VID60.v — the framebuffer
   fetch CDC (toggle synchroniser vs async-set [req1]) and the 2-group prefetch
   (look-ahead [vidadr] + ping-pong banks vs single [vidbuf]). So this is a PARTIAL proof:
   the raster + pixel datapath ≡ VID60.v GIVEN the same fetched word, with BOTH departed
   outputs cut/ excluded. [proofs/vid.ys.template] drops the DCM, exposes pclk, cuts
   [vidbuf] (our read mux, named to pair with the RTL) to a shared free input, and
   equiv_removes [req] and [vidadr]. Both departures are closed by decomposition: the
   [req] CDC by [vid_invariant]; the [vidadr] prefetch DELIVERY by [vid_addr] (the
   look-ahead address ≡ a geometry spec, all hcnt/vcnt) + [vid_invariant] (timing) + a
   reviewed composition lemma (README "VID prefetch"). The monolithic all-phases delivery
   proof does not converge tractably (col 0 is cross-line), so that one glue step stays a
   hand argument, cross-checked by the co-located sim test. *)
let run_vid ~work_dir =
  Yosys_equiv.run_proof
    ~work_dir
    ~ours:(vid ())
    ~template:(proofs_dir ^ "/vid.ys.template")
    ~subst:
      [ "rtl", rtl_dir ^ "/VID60.v"; "stubs", proofs_dir ^ "/vid_stubs.v"; "top", "VID" ]
    ()
  |> report
       ~ok:
         "vid: EQUIVALENT — raster + pixel datapath proven, CDC + prefetch look-ahead \
          excluded  (vs VID60.v, multiclock · CDC+prefetch cut · yosys equiv_induct)"
       ~bad:
         "vid: NOT EQUIVALENT — $equiv cells left unproven  (vs VID60.v, multiclock · \
          CDC+prefetch cut · yosys equiv_induct)"
;;

(* The VID fetch-CDC invariant — the property the vid proof cuts. Proves [Vid.pulse_sync]
   is no-loss + no-spurious (one req per req0) for ALL clk/pclk phase interleavings and
   ALL reachable states, by k-INDUCTION (yosys-smtbmc -i / z3) — unbounded, the part the
   single-phase Cyclesim test can't reach. [k] is the induction length: threshold ~38 (k
   must span a fetch cycle so the k-step history forces a reachable state); 48 leaves
   margin. [proofs/vid_invariant.ys.template] only emits the SMT problem; run_proof's
   [~smtbmc] runs the k-induction. *)
let vid_invariant_k = 48

let run_vid_invariant ~work_dir =
  Yosys_equiv.run_proof
    ~work_dir
    ~ours:(pulse_sync ())
    ~template:(proofs_dir ^ "/vid_invariant.ys.template")
    ~subst:[ "monitor", proofs_dir ^ "/vid_invariant.v"; "top", "vid_invariant" ]
    ~smtbmc:vid_invariant_k
    ()
  |> report
       ~ok:
         (Printf.sprintf
            "vid_invariant: PROVEN — one req per req0, no loss, no spurious, all \
             phases/states  (all-phase CDC · yosys-smtbmc k-induction k=%d)"
            vid_invariant_k)
       ~bad:
         (Printf.sprintf
            "vid_invariant: NOT PROVEN — induction counterexample  (all-phase CDC · \
             yosys-smtbmc k-induction k=%d)"
            vid_invariant_k)
;;

(* C — the addressing half of prefetch DELIVERY (test/formal/README "VID prefetch"). The
   [vid] equiv excludes [vidadr] (our look-ahead departs from VID60.v's current-group
   address), so this proves — combinationally, exhaustively over ALL (hcnt, vcnt) — that
   [Vid.lookahead] computes Org + [{~next_vcnt, next_col}] for the correct next group and
   routes it to the [lsb next_col] bank: i.e. ≡ an independent geometry spec. Pure Sec/z3
   on two in-process Hardcaml circuits, no .v import (there is no reference .v for the
   look-ahead address — VID60.v's is the current group). Together with [vid_invariant]
   (the timing/CDC half) and the ping-pong margin, this closes the prefetch by
   decomposition (the composition lemma is in the README). [work_dir] is unused — Sec
   manages its own z3. *)
let run_vid_addr ~work_dir:_ =
  Formal_equiv.check_circuits ~ours:(vid_addr_ours ()) ~spec:(vid_addr_spec ())
  |> function
  | Formal_equiv.Equivalent ->
    Stdio.printf
      "vid_addr: EQUIVALENT — look-ahead address ≡ geometry spec for all (hcnt,vcnt)  \
       (vs geometry spec, addressing half of prefetch delivery · combinational · Sec/z3)\n\
       %!";
    true
  | Formal_equiv.Counterexample ->
    Stdio.printf
      "vid_addr: NOT EQUIVALENT — look-ahead address differs from geometry spec  \
       (combinational · Sec/z3)\n\
       %!";
    false
;;

(* All checks as one uniform list — [name, run ~work_dir -> passed?]. The combinational
   and sequential rows wrap their tuple-driven runners; core/mouse/vid/vid_invariant are
   their own one-off flows. [run] is only invoked inside a worker (or a single-check run),
   so building this list touches no circuit / yosys / z3 — keeping the parent clean before
   [Fork_pool] forks. *)
let checks : (string * (work_dir:string -> bool)) list =
  List.concat
    [ List.map combinational ~f:(fun ((name, _, _, _) as row) ->
        name, fun ~work_dir -> run_combinational ~work_dir row)
    ; List.map sequential ~f:(fun ((name, _, _, _, _) as row) ->
        ( name
        , fun ~work_dir ->
            run_sequential
              ~work_dir
              ~dir:rtl_dir
              ~kind:"sequential · yosys equiv_induct"
              row ))
    ; List.map behavioral ~f:(fun ((name, _, _, _, _) as row) ->
        ( name
        , fun ~work_dir ->
            run_sequential
              ~work_dir
              ~dir:proofs_dir
              ~kind:"sequential · yosys equiv_induct · behavioural spec"
              row ))
    ; [ "core", run_core
      ; "mouse", run_mouse
      ; "vid", run_vid
      ; "vid_invariant", run_vid_invariant
      ; "vid_addr", run_vid_addr
      ]
    ]
;;

let () =
  cd_to_repo_root ();
  let argv = Stdlib.Sys.argv in
  let sel = if Array.length argv >= 2 then argv.(1) else "all" in
  let selected =
    if String.equal sel "all"
    then checks
    else (
      match List.find checks ~f:(fun (n, _) -> String.equal n sel) with
      | Some c -> [ c ]
      | None ->
        Stdio.eprintf
          "unknown check: %s (expected %s | all)\n"
          sel
          (String.concat ~sep:" " (List.map checks ~f:fst));
        Stdlib.exit 2)
  in
  let jobs =
    if Array.length argv >= 3
    then (
      match Stdlib.int_of_string_opt argv.(2) with
      | Some j -> Int.max 1 j
      | None ->
        Stdio.eprintf "bad jobs count: %s\n" argv.(2);
        Stdlib.exit 2
        (* yosys/z3 are RAM-heavy (the core proof + vid_invariant k-induction especially),
           so default to ~half the cores; override with the 2nd arg. *))
    else
      Int.max 1 (Int.min (List.length selected) (Domain.recommended_domain_count () / 2))
  in
  (* prep: yosys + z3 on PATH, and the reference RTL fetched + checksum-verified on demand
     (the fetch itself stays toolchain-free bash). *)
  List.iter [ "yosys"; "z3" ] ~f:(fun tool ->
    if Stdlib.Sys.command (Printf.sprintf "command -v %s > /dev/null 2>&1" tool) <> 0
    then (
      Stdio.eprintf "[formal] needs '%s' on PATH — see test/formal/README.md\n" tool;
      Stdlib.exit 2));
  if Stdlib.Sys.command "bash test/fetch-rtl.sh" <> 0
  then (
    Stdio.eprintf "[formal] reference RTL fetch failed\n";
    Stdlib.exit 2);
  let check_dir name = work_root ^ "/" ^ name in
  match selected with
  | [ (name, run) ] ->
    (* single check: run live (uncaptured) for debugging *)
    Stdlib.exit (if run ~work_dir:(check_dir name) then 0 else 1)
  | _ ->
    let fails =
      Fork_pool.run
        ~what:"formal"
        ~jobs
        ~work_root
        (List.map selected ~f:(fun (name, run) ->
           name, fun () -> run ~work_dir:(check_dir name)))
    in
    if fails > 0 then Stdlib.exit 1
;;
