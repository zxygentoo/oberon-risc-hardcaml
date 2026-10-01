open! Base
open Hardcaml

(* ── Combinational units. The ports are the reference .v's; the .v is imported and
   checked against our circuit by SAT (Formal_equiv). ── *)

let left_shifter () =
  let module C = Circuit.With_interface (Risc5.Left_shifter.I) (Risc5.Left_shifter.O) in
  C.create_exn ~name:"LeftShifter" Risc5.Left_shifter.create
;;

let right_shifter () =
  let module C = Circuit.With_interface (Risc5.Right_shifter.I) (Risc5.Right_shifter.O) in
  C.create_exn ~name:"RightShifter" Risc5.Right_shifter.create
;;

(* ── Sequential units. Each circuit is built with its .v's port names, and the library's
   registers carry the RTL's names, so yosys can pair the flip-flops and prove the step by
   induction (Yosys_equiv). The circuit's name differs from the reference module's so that
   yosys can read both. ── *)

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

(* ── The single-clock peripherals with a .v of their own: the two UART directions, SPI
   and the PS/2 keyboard. The recipe is that of the iterative units. [rst_n] is the RTL's
   active-low [rst] port under our name for it. Where a library register's name differs
   from the RTL's, the yosys script renames it (the [renames] column of the table below),
   as the core proof does. ── *)

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

(* The mouse. MousePM.v's [MouseP] has open-drain [inout] lines; our port splits each into
   a drive-low [*_oe] output and an input carrying the resolved value. A Verilog shim
   (mouse_shim.v) recombines them into the RTL's inout, and the shimmed circuit is proven
   equivalent to MouseP: see [run_mouse]. *)
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

(* Video. Two clock domains, and two deliberate departures from VID60.v: the clock
   crossing of the fetch request (a toggle synchroniser, where the RTL sets [req1]
   asynchronously), and the look-ahead fetch (the next group's address and two alternating
   buffers, where the RTL has the current group's address and one [vidbuf]). What is
   proven, and how the departures are closed, is at [run_vid]. *)
let vid () =
  let open Signal in
  let i =
    { Risc5.Video.I.clk = input "clk" 1
    ; pclk = input "pclk" 1
    ; inv = input "inv" 1
    ; viddata = input "viddata" 32
    }
  in
  let { Risc5.Video.O.req; vidadr; hsync; vsync; rgb } = Risc5.Video.create i in
  Circuit.create_exn
    ~name:"vid_ours"
    [ output "req" req
    ; output "vidadr" vidadr
    ; output "hsync" hsync
    ; output "vsync" vsync
    ; output "RGB" rgb
    ]
;;

(* The fetch request's synchroniser, [Video.pulse_sync], by itself, with [req0] as an
   input: the harness vid_invariant.v drives it and asserts one [req] per [req0]. That is
   a property proof (see [run_vid_invariant]), not an equivalence. *)
let pulse_sync () =
  let open Signal in
  let clk = input "clk" 1 in
  let pclk = input "pclk" 1 in
  let req0 = input "req0" 1 in
  let req =
    Risc5.Video.pulse_sync
      ~src_spec:(Reg_spec.create () ~clock:pclk)
      ~dst_spec:(Reg_spec.create () ~clock:clk)
      ~pulse:req0
  in
  Circuit.create_exn ~name:"pulse_sync_ours" [ output "req" req ]
;;

(* The look-ahead logic, [Video.lookahead], by itself, with the raster counters as free
   inputs: a combinational function of (hcnt, vcnt), proven equal to [vid_addr_spec]
   below. *)
let vid_addr_ours () =
  let open Signal in
  let hcnt = input "hcnt" 11 in
  let vcnt = input "vcnt" 10 in
  let { Risc5.Video.Lookahead.next_col; next_vcnt; vidadr; wpar } =
    Risc5.Video.lookahead ~hcnt ~vcnt
  in
  Circuit.create_exn
    ~name:"vid_addr_ours"
    [ output "next_col" next_col
    ; output "next_vcnt" next_vcnt
    ; output "vidadr" vidadr
    ; output "wpar" wpar
    ]
;;

(* A specification of the look-ahead address, written from the screen geometry and in a
   different style from lib/video.ml, so that the equivalence is a cross-check and not a
   restatement:
   - the next column by the natural 5-bit wrap of [col + 1], where video.ml has an
     explicit mux on [col = 31];
   - the address by shifts and adds, where video.ml concatenates fields;
   - the framebuffer base and the geometry (32 pixels to a group, 768 visible rows) stated
     again here. The row wrap 767 → 0 is not a power of two, so both sides need the same
     compare: there the spec only pins the value. *)
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

(* ── The register file, against a specification. Registers.v is 64 bit-sliced RAM16X1D
   primitives, duplicated: state of a shape that cannot be paired flip-flop by flip-flop
   with ours, and a memory miter that is not inductive (see the README). So the proof is
   against the contract Registers.v implements (registers_spec.v: 16 words of 32 bits,
   three asynchronous reads, one synchronous write). Both sides are then one array, which
   the [memory] pass lowers to flip-flops that pair by name. ── *)

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

(* Scratch files go under the git-ignored test/_work (the runner changes to the repo root
   at startup, so the relative path resolves). Each check has its own directory, so
   parallel checks' yosys and z3 files never collide. *)
let work_root = "test/_work/formal"
let rtl_dir = "test/_po/verilog/src" (* Wirth's originals, fetched on demand *)

let proofs_dir =
  "test/formal/proofs" (* the .ys.template proofs + the .v specs they read *)
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

(* The {!Formal_equiv.result} (Sec/z3) twin of [report]. *)
let report_sec ~ok ~bad result =
  match (result : Formal_equiv.result) with
  | Formal_equiv.Equivalent ->
    Stdio.printf "%s\n%!" ok;
    true
  | Formal_equiv.Counterexample ->
    Stdio.printf "%s\n%!" bad;
    false
;;

let run_combinational ~work_dir (name, ours, v, top_module) =
  Formal_equiv.check ~work_dir ~verilog:(rtl_dir ^ "/" ^ v) ~top_module ~ours:(ours ())
  |> report_sec
       ~ok:
         (Printf.sprintf
            "%s: EQUIVALENT — no input makes the outputs differ  (vs %s, combinational · \
             Sec/z3)"
            name
            v)
       ~bad:
         (Printf.sprintf
            "%s: NOT EQUIVALENT — counterexample found  (vs %s, combinational · Sec/z3)"
            name
            v)
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

(* Every single-clock sequential proof: proofs/sequential.ys.template, filled in from a
   row and run by [Yosys_equiv.run_proof]. [dir] is the reference .v's directory:
   [rtl_dir] for Wirth's originals, [proofs_dir] for registers_spec.v. *)
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

(* A row: name, circuit, reference .v, top module, register renames. [renames] is empty
   when our register names are already the RTL's; otherwise it maps ours to the .v's (for
   example [q0] to [Q0], [spi_shreg] to [shreg]). *)
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

(* The core's glue, in place: decode, the inline ALU, control, flags and the 13 state
   registers, against RISC5.v with the eight submodules as black boxes on both sides (each
   is proven separately). [Core_blackbox] builds our side with instantiation stubs for the
   units. proofs/core.ys.template pairs the black-box cells, which also checks that both
   sides drive each unit's inputs alike; cuts the units' outputs to shared free signals;
   and closes the glue by induction. *)
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

(* The mouse proof needs the two shims and tristate lowering: see proofs/mouse_shim.v and
   proofs/mouse.ys.template. The renames strip the [g.] prefix that flattening a shim
   adds, which pairs the wrapped flip-flops with the RTL's; under the prefix the names are
   already MousePM.v's. *)
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

(* Two rename blocks, one per shim ([{gold_renames}] and [{ours_renames}]); otherwise the
   shape of a sequential proof. *)
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

(* Video is a partial proof: the raster and the pixel path equal VID60.v's, given the same
   fetched word. proofs/vid.ys.template drops the DCM, exposes pclk, cuts [vidbuf] (our
   buffer read mux, named to pair with the RTL's register) to a shared free input, and
   removes the two departed outputs, [req] and [vidadr], from the comparison. The
   departures are closed separately. The request crossing: [vid_invariant]. The look-
   ahead: [vid_addr] (the address is the right one for every hcnt and vcnt),
   [vid_invariant] (its timing), and one composition step argued by hand in the README
   ("VID prefetch") and cross-checked by the simulation test in lib/video.ml. A single
   proof of the whole delivery does not converge: column 0's word is requested on the line
   before. *)
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

(* The property the video proof cuts out: [Video.pulse_sync] gives exactly one [req] per
   [req0], none lost and none spurious, in every reachable state and for every
   interleaving of clk and pclk that the harness admits (vid_invariant.v states its
   envelope). It is proven by k-induction (yosys-smtbmc over z3: a bounded base case from
   the initial state, and the step), which reaches what the single-phase simulation test
   cannot. [k] must span a fetch cycle, so that the k-step history forces a reachable
   state: the threshold is about 38, and 48 leaves margin. The template only emits the SMT
   problem; [run_proof]'s [~smtbmc] runs the induction. *)
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
             phases/states  (all-phase CDC · yosys-smtbmc k-induction k=%d, base + step)"
            vid_invariant_k)
       ~bad:
         (Printf.sprintf
            "vid_invariant: NOT PROVEN — the base case or the induction step failed  \
             (all-phase CDC · yosys-smtbmc k-induction k=%d)"
            vid_invariant_k)
;;

(* The addressing half of the look-ahead. The video proof excludes [vidadr], so this
   proves, for every (hcnt, vcnt), that [Video.lookahead] computes the next group's
   address and selects the buffer [lsb next_col]: it equals the geometry spec above. Both
   circuits are Hardcaml, checked by Sec and z3 with no .v imported (VID60.v has no look-
   ahead address to compare with). [work_dir] is unused: Sec manages its own z3 files. *)
let run_vid_addr ~work_dir:_ =
  Formal_equiv.check_circuits ~ours:(vid_addr_ours ()) ~spec:(vid_addr_spec ())
  |> report_sec
       ~ok:
         "vid_addr: EQUIVALENT — look-ahead address ≡ geometry spec for all (hcnt,vcnt)  \
          (vs geometry spec, addressing half of prefetch delivery · combinational · \
          Sec/z3)"
       ~bad:
         "vid_addr: NOT EQUIVALENT — look-ahead address differs from geometry spec  \
          (combinational · Sec/z3)"
;;

(* All the checks as one list of (name, run). [run] is called only inside a worker, or for
   a single check, so building the list touches no circuit, yosys or z3, and the parent is
   clean when [Fork_pool] forks. *)
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
  (* paths are relative to the repo root, wherever the runner is started from *)
  Fork_pool.cd_to_repo_root ();
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
  (* preparation: yosys and z3 on PATH, and the reference RTL fetched and checksum-
     verified *)
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
