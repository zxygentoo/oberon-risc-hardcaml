(* A port of LeftShifter.v; the contract is in [left_shifter.mli].

   The RTL stages the shift in three mux levels (sc[1:0], sc[3:2], sc[4]). [log_shift]
   builds five 2:1 levels instead: another netlist for the same function, and the function
   is all a combinational block has to preserve. *)

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

(* ── Tests ── A property test against [x lsl sc], and a waveform of a bit walking left. *)

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
  Test_gen.check_exn
    (QCheck.Test.make
       ~count:10_000
       ~name:"lsl"
       QCheck.(pair Test_gen.word32 (int_bound 31))
       (fun (x, sc) -> Bits.equal (eval ~x ~sc) (reference ~x ~sc)));
  [%expect {| |}]
;;

let%expect_test "LSL waveform — 1 << {0,1,4,16}, then 0xDEADBEEF << 4" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
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
  Waveform.print ~wave_width:4 ~display_width:70 waves;
  [%expect
    {|
    ┌Signals────────┐┌Waves──────────────────────────────────────────────┐
    │               ││────────────────────────────────────────┬───────── │
    │x              ││ 00000001                               │DEADBEEF  │
    │               ││────────────────────────────────────────┴───────── │
    │               ││──────────┬─────────┬─────────┬─────────┬───────── │
    │sc             ││ 00       │01       │04       │10       │04        │
    │               ││──────────┴─────────┴─────────┴─────────┴───────── │
    │               ││──────────┬─────────┬─────────┬─────────┬───────── │
    │y              ││ 00000001 │00000002 │00000010 │00010000 │EADBEEF0  │
    │               ││──────────┴─────────┴─────────┴─────────┴───────── │
    └───────────────┘└───────────────────────────────────────────────────┘
    |}]
;;
