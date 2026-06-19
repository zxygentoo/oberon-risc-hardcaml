(* Public API and behaviour spec live in [left_shifter.mli].

   Implementation note. Wirth's RTL ([LeftShifter.v]) stages the shift radix-4 — the
   groups [sc[1:0]] / [sc[3:2]] / [sc[4]], three mux levels. We use Hardcaml's [log_shift]
   barrel-shifter combinator instead; it lowers to a radix-2 net (five 2:1-mux stages —
   shifts 1/2/4/8/16) — a different netlist but the identical combinational function,
   which synthesis re-maps onto the LUT6 fabric either way. Per AGENT.md §2: be idiomatic
   in the combinational datapath. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { x : 'a [@bits 32]
    ; sc : 'a [@bits 5]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { y : 'a [@bits 32] } [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t = { O.y = log_shift ~f:sll i.x ~by:i.sc }

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness: qcheck the circuit against the pure-OCaml reference [x lsl sc] (no oracle
   needed for a combinational block). Behaviour: a frozen waveform of a single bit walking
   left, plus a pattern shift — living documentation. *)

let%expect_test "LSL = (x lsl sc) reference [qcheck, 10k cases]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let eval ~x ~sc =
    inp.x := Bits.of_unsigned_int ~width:32 x;
    inp.sc := Bits.of_unsigned_int ~width:5 sc;
    Cyclesim.cycle sim;
    !(outp.y)
  in
  let reference ~x ~sc = Bits.of_unsigned_int ~width:32 ((x lsl sc) land 0xFFFF_FFFF) in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:10_000
       ~name:"lsl"
       QCheck.(pair (int_bound 0xFFFF_FFFF) (int_bound 31))
       (fun (x, sc) -> Bits.equal (eval ~x ~sc) (reference ~x ~sc)));
  [%expect {| |}]
;;

let%expect_test "LSL waveform — 1 << {0,1,4,16}, then 0xDEADBEEF << 4" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let drive ~x ~sc =
    inp.x := Bits.of_unsigned_int ~width:32 x;
    inp.sc := Bits.of_unsigned_int ~width:5 sc;
    Cyclesim.cycle sim
  in
  drive ~x:0x1 ~sc:0;
  drive ~x:0x1 ~sc:1;
  drive ~x:0x1 ~sc:4;
  drive ~x:0x1 ~sc:16;
  drive ~x:0xDEAD_BEEF ~sc:4;
  Waveform.print ~wave_width:5 ~display_width:96 waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves─────────────────────────────────────────────────────────────────────┐
    │                  ││────────────┬───────────┬───────────┬───────────┬───────────              │
    │sc                ││ 00         │01         │04         │10         │04                       │
    │                  ││────────────┴───────────┴───────────┴───────────┴───────────              │
    │                  ││────────────────────────────────────────────────┬───────────              │
    │x                 ││ 00000001                                       │DEADBEEF                 │
    │                  ││────────────────────────────────────────────────┴───────────              │
    │                  ││────────────┬───────────┬───────────┬───────────┬───────────              │
    │y                 ││ 00000001   │00000002   │00000010   │00010000   │EADBEEF0                 │
    │                  ││────────────┴───────────┴───────────┴───────────┴───────────              │
    └──────────────────┘└──────────────────────────────────────────────────────────────────────────┘
    |}]
;;
