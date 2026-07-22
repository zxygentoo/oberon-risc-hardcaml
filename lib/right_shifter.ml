(* Public API and behaviour spec live in [right_shifter.mli].

   Implementation note. Wirth's RTL ([RightShifter.v]) is the mirror of [LeftShifter.v] —
   the same radix-4 barrel (stages sc[1:0] / sc[3:2] / sc[4]) run rightward — with one
   twist: each stage's vacated top bits are filled by [md], the sign bit for ASR or the
   outgoing low bits for ROR. We express that as the two idiomatic barrels
   [log_shift ~f:sra] (ASR) and [log_shift ~f:rotr] (ROR) selected by [md]; synthesis
   rebuilds the shared staged tree. Per AGENT.md §2: be idiomatic in the combinational
   datapath. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { x : 'a [@bits 32]
    ; sc : 'a [@bits 5]
    ; md : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { y : 'a [@bits 32] } [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let asr_ = log_shift ~f:sra i.x ~by:i.sc in
  let ror_ = log_shift ~f:rotr i.x ~by:i.sc in
  { O.y = mux2 i.md ror_ asr_ }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness: qcheck both modes against pure-OCaml references — ASR is sign-extend then
   arithmetic-shift then mask to 32 bits; ROR is the shift-or-shift identity with the sc=0
   case handled (no oracle needed for a combinational block). Behaviour: a frozen waveform
   of the sign flooding in under ASR and a pattern wrapping under ROR — living docs. *)

let%expect_test "ASR/ROR = references [qcheck, 10k cases]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let eval ~x ~sc ~md =
    inp.x := Bits.of_unsigned_int ~width:32 x;
    inp.sc := Bits.of_unsigned_int ~width:5 sc;
    inp.md := Bits.of_unsigned_int ~width:1 md;
    Cyclesim.cycle sim;
    !(outp.y)
  in
  (* 32-bit arithmetic shift right: sign-extend x into an OCaml int, [asr], re-mask. *)
  let asr_ref ~x ~sc = (((x lxor 0x8000_0000) - 0x8000_0000) asr sc) land 0xFFFF_FFFF in
  (* 32-bit rotate right; [x lsl 32] is undefined, so handle sc=0 directly. *)
  let ror_ref ~x ~sc =
    if sc = 0 then x else (x lsr sc) lor (x lsl (32 - sc)) land 0xFFFF_FFFF
  in
  let reference ~x ~sc ~md = if md = 1 then ror_ref ~x ~sc else asr_ref ~x ~sc in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:10_000
       ~name:"asr_ror"
       QCheck.(triple (int_bound 0xFFFF_FFFF) (int_bound 31) (int_bound 1))
       (fun (x, sc, md) ->
         Bits.equal
           (eval ~x ~sc ~md)
           (Bits.of_unsigned_int ~width:32 (reference ~x ~sc ~md))));
  [%expect {| |}]
;;

let%expect_test "right-shift waveform — ASR sign-floods, then ROR wraps" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let drive ~x ~sc ~md =
    inp.x := Bits.of_unsigned_int ~width:32 x;
    inp.sc := Bits.of_unsigned_int ~width:5 sc;
    inp.md := Bits.of_unsigned_int ~width:1 md;
    Cyclesim.cycle sim
  in
  (* ASR (md=0): the set sign bit floods in from the top. *)
  drive ~x:0xF000_0000 ~sc:0 ~md:0;
  drive ~x:0xF000_0000 ~sc:4 ~md:0;
  drive ~x:0xF000_0000 ~sc:8 ~md:0;
  (* ROR (md=1): the low bits wrap around to the top. *)
  drive ~x:0xDEAD_BEEF ~sc:4 ~md:1;
  drive ~x:0xDEAD_BEEF ~sc:16 ~md:1;
  Waveform.print ~wave_width:4 ~display_width:70 waves;
  [%expect
    {|
    ┌Signals────────┐┌Waves──────────────────────────────────────────────┐
    │               ││──────────────────────────────┬─────────────────── │
    │x              ││ F0000000                     │DEADBEEF            │
    │               ││──────────────────────────────┴─────────────────── │
    │               ││──────────┬─────────┬─────────┬─────────┬───────── │
    │sc             ││ 00       │04       │08       │04       │10        │
    │               ││──────────┴─────────┴─────────┴─────────┴───────── │
    │md             ││                              ┌─────────────────── │
    │               ││──────────────────────────────┘                    │
    │               ││──────────┬─────────┬─────────┬─────────┬───────── │
    │y              ││ F0000000 │FF000000 │FFF00000 │FDEADBEE │BEEFDEAD  │
    │               ││──────────┴─────────┴─────────┴─────────┴───────── │
    └───────────────┘└───────────────────────────────────────────────────┘
    |}]
;;
