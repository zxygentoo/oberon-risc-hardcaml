open! Base
open Hardcaml

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
    { Risc5.Rs232t.I.clock = input "clk" 1
    ; rst_n = input "rst" 1
    ; start = input "start" 1
    ; fsel = input "fsel" 1
    ; data = input "data" 8
    }
  in
  let { Risc5.Rs232t.O.rdy; txd } = Risc5.Rs232t.create i in
  (* run/tick/bitcnt/shreg already match RS232T.v — no renames needed. *)
  Circuit.create_exn ~name:"rs232t_ours" [ output "rdy" rdy; output "TxD" txd ]
;;

let rs232r () =
  let open Signal in
  let i =
    { Risc5.Rs232r.I.clock = input "clk" 1
    ; rst_n = input "rst" 1
    ; rxd = input "RxD" 1
    ; fsel = input "fsel" 1
    ; done_ = input "done" 1
    }
  in
  let { Risc5.Rs232r.O.rdy; data } = Risc5.Rs232r.create i in
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
   proven ≡ MouseP (see [Yosys_equiv.check_shim]). *)
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

let work_dir =
  (match Stdlib.Sys.getenv_opt "CLAUDE_JOB_DIR" with
   | Some d -> d
   | None -> "/tmp")
  ^ "/oberon-formal"
;;

let rtl_dir = "_po/verilog/src" (* Wirth's originals, fetched on demand *)
let spec_dir = "test/formal" (* our checked-in behavioural specs, e.g. registers_spec.v *)

let run_combinational (name, ours, v, top_module) =
  Stdio.printf "=== %s : ours  vs  %s   [combinational · Sec/z3] ===\n%!" name v;
  match
    Formal_equiv.check ~work_dir ~verilog:(rtl_dir ^ "/" ^ v) ~top_module ~ours:(ours ())
  with
  | Formal_equiv.Equivalent ->
    Stdio.printf "  EQUIVALENT  (no input makes the outputs differ)\n%!";
    false
  | Formal_equiv.Counterexample ->
    Stdio.printf "  NOT EQUIVALENT  (counterexample found)\n%!";
    true
;;

let run_sequential ~dir ~kind (name, ours, v, top_module, renames) =
  Stdio.printf "=== %s : ours  vs  %s   [%s] ===\n%!" name v kind;
  match
    Yosys_equiv.check
      ~work_dir
      ~verilog:(dir ^ "/" ^ v)
      ~renames
      ~top_module
      ~ours:(ours ())
  with
  | Yosys_equiv.Equivalent ->
    Stdio.printf "  EQUIVALENT  (induction closed — all $equiv proven)\n%!";
    false
  | Yosys_equiv.Not_equivalent ->
    Stdio.printf "  NOT EQUIVALENT  ($equiv cells left unproven)\n%!";
    true
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

(* Proven against our behavioural spec in [spec_dir], not a Wirth original (see
   [registers]). *)
let behavioral
  : (string * (unit -> Circuit.t) * string * string * (string * string) list) list
  =
  [ "registers", registers, "registers_spec.v", "Registers_spec", [] ]
;;

(* The in-situ core-glue proof (its own runner — one entry, distinct yosys flow). Proves
   our whole core's glue (decode, the inline ALU, control, flags, the 13 state registers)
   ≡ RISC5.v with the 8 submodules black-boxed and assumed-equivalent (each proven above /
   separately). See [Core_blackbox] (the gate) and [Yosys_equiv.check_core] (the flow:
   equiv_make merges the units, cutpoint -blackbox cuts their outputs, equiv_induct closes
   the glue). *)
let run_core () =
  Stdio.printf
    "=== core : ours glue  vs  RISC5.v   [in-situ · 8 units black-boxed · yosys \
     equiv_induct] ===\n\
     %!";
  match
    Yosys_equiv.check_core
      ~work_dir
      ~verilog:(rtl_dir ^ "/RISC5.v")
      ~stubs:(spec_dir ^ "/core_stubs.v")
      ~renames:Core_blackbox.register_renames
      ~top_module:"RISC5"
      ~ours:(Core_blackbox.circuit ())
  with
  | Yosys_equiv.Equivalent ->
    Stdio.printf
      "  EQUIVALENT  (glue proven — all $equiv closed; units assumed-equiv)\n%!";
    false
  | Yosys_equiv.Not_equivalent ->
    Stdio.printf "  NOT EQUIVALENT  ($equiv cells left unproven)\n%!";
    true
;;

(* The Mouse (Tier 2): its own runner (distinct yosys flow, like run_core), since MouseP's
   open-drain [inout] needs the two-shim recombination + tristate lowering — see
   [mouse_shim.v] and [Yosys_equiv.check_shim]. [renames] strips the [g.] instance prefix
   the flatten adds, pairing the wrapped FFs back to the RTL's names (which our lib
   already matches: rx/count/filter/tx/x/y/btns/sent/req). *)
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

let run_mouse () =
  Stdio.printf
    "=== mouse : ours (shimmed)  vs  MousePM.v   [open-drain inout · yosys equiv_induct] \
     ===\n\
     %!";
  match
    Yosys_equiv.check_shim
      ~work_dir
      ~verilog:(rtl_dir ^ "/MousePM.v")
      ~shims:(spec_dir ^ "/mouse_shim.v")
      ~gold_shim:"mouse_gold_shim"
      ~ours_shim:"mouse_ours_shim"
      ~renames:mouse_renames
      ~ours:(mouse ())
  with
  | Yosys_equiv.Equivalent ->
    Stdio.printf "  EQUIVALENT  (induction closed — all $equiv proven)\n%!";
    false
  | Yosys_equiv.Not_equivalent ->
    Stdio.printf "  NOT EQUIVALENT  ($equiv cells left unproven)\n%!";
    true
;;

let () =
  let fails =
    List.count combinational ~f:run_combinational
    + List.count
        sequential
        ~f:(run_sequential ~dir:rtl_dir ~kind:"sequential · yosys equiv_induct")
    + List.count
        behavioral
        ~f:
          (run_sequential
             ~dir:spec_dir
             ~kind:"sequential · yosys equiv_induct · behavioural spec")
    + Bool.to_int (run_core ())
    + Bool.to_int (run_mouse ())
  in
  let total =
    List.length combinational + List.length sequential + List.length behavioral + 2
  in
  if fails > 0
  then (
    Stdio.printf "\n%d of %d formal check(s) FAILED\n" fails total;
    Stdlib.exit 1)
  else Stdio.printf "\nall %d formal check(s) passed\n" total
;;
