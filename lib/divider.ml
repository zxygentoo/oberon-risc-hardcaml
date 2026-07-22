(* Public API and behaviour spec live in [divider.mli].

   Implementation note. Sequential unit → mirror RISC5.v's skeleton exactly (AGENT.md §2);
   this is the Multiplier's twin — identical 6-bit [S] counter, [stall = run & ~(S==33)],
   run-gated with no reset, 33 cycles, and a dual-role 64-bit register [RQ]. Original RTL
   is [test/_po/verilog/src/Divider.v] (28 lines).

   [RQ] holds [remainder | quotient] (high 32 | low 32). Load (S=0) puts [|x|] in the low
   half and 0 in the high. Each step is one round of *restoring division*: shift [{R,Q}]
   left one bit (the remainder grabs the quotient's top bit → [RQ[62:31]]), trial-subtract
   the divisor, and either keep the difference (quotient bit 1) or restore the old
   remainder (quotient bit 0), with the quotient bit shifting into the LSB. After 32 steps
   [RQ] = [rem | quot] of [|x|/y]. Negative signed dividends divide [|x|] then
   sign-correct the outputs to floored division with a non-negative remainder — note
   [-q-1 = ~q] in two's complement (see the .mli). *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; run : 'a [@bits 1]
    ; u : 'a [@bits 1]
    ; x : 'a [@bits 32]
    ; y : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { stall : 'a [@bits 1]
    ; quot : 'a [@bits 32]
    ; rem : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

let create ?(ce = vdd) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* Phase 7 (board memory): ce-gates the unit's state so MUL/DIV/FP freeze in lockstep
     with the ce-gated core through a multi-cycle PSRAM wait. Without it, during the
     fetch-wait right after the op completes [S] runs past its terminal count, [stall]
     re-asserts and the divide restarts forever (the first-boot hang, root-caused in sim).
     [ce = vdd] (the default) ⇒ [~enable:vdd] is a no-op ⇒ byte-identical to the bare
     port. *)
  let reg_fb spec ~width ~f = Signal.reg_fb spec ~enable:ce ~width ~f in
  (* S : 6-bit counter; run is enable + synchronous clear (no reset) — twin of Multiplier. *)
  (* Registers named to match the RTL ([S]/[RQ]) so the Phase-8 formal harness can pair
     the flip-flops with Divider.v's (yosys [equiv_make] matches FFs by name —
     test/formal), exactly as the Multiplier names its [S]/[P]. *)
  let s = reg_fb spec ~width:6 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 6)) -- "S" in
  (* a negative signed dividend — divide [|x|], then sign-correct the outputs below *)
  let sign = msb i.x &: i.u in
  let x0 = mux2 sign (negate i.x) i.x in
  (* RQ : 64-bit [remainder | quotient]; one restoring-division round per step. *)
  let rq =
    reg_fb spec ~width:64 ~f:(fun rq ->
      (* shift [{R,Q}] left one, then trial-subtract the divisor *)
      let w0 = select rq ~high:62 ~low:31 in
      let w1 = w0 -: i.y in
      mux2
        (s ==:. 0)
        (zero 32 @: x0)
        (* keep the difference (bit 1) or restore the old remainder (bit 0); the borrow
           [~w1[31]] is the new quotient bit, shifted into the LSB *)
        (mux2 (msb w1) w0 w1 @: select rq ~high:30 ~low:0 @: ~:(msb w1)))
    -- "RQ"
  in
  let q = select rq ~high:31 ~low:0 in
  let r = select rq ~high:63 ~low:32 in
  (* floored-division sign-correction for negative dividends ([-q-1] = [~q]) *)
  let quot = mux2 sign (mux2 (r ==:. 0) (negate q) ~:q) q in
  let rem = mux2 sign (mux2 (r ==:. 0) (zero 32) (i.y -: r)) r in
  { O.stall = i.run &: ~:(s ==:. 33); quot; rem }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness oracle is pure OCaml (3a — no fp_vectors, no emulator). [reference] is the
   floored/unsigned spec (unsigned = x/y, x mod y; signed = truncate toward zero then
   floor-correct to a non-negative remainder, exactly like the emulator). [run_div] drives
   one full divide on a shared sim — it ends when stall drops, then run is dropped one
   cycle to clear S=0. Two correctness tests share them: explicit edge vectors (divider
   corners random sampling won't reliably hit — INT_MIN, by-1, by-self, x<y, …) and a
   2000-case qcheck with the divisor restricted to [1, 2^31-1] (the hardware
   precondition). Behaviour: a head/tail stall-envelope waveform of signed −7/2 = −4 rem
   1, quot/rem printed. *)

let reference ~u ~x ~y =
  let mask32 v = Int.bit_and v 0xFFFF_FFFF in
  if u = 1
  then (
    (* signed: truncate toward zero, then floor-correct to a non-negative remainder *)
    let bi = if x >= 0x8000_0000 then x - 0x1_0000_0000 else x in
    let qt = bi / y in
    let rt = bi - (qt * y) in
    let q, r = if rt < 0 then qt - 1, rt + y else qt, rt in
    mask32 q, mask32 r)
  else mask32 (x / y), mask32 (x - (x / y * y))
;;

let set r v w = r := Bits.of_unsigned_int ~width:w v

let run_div sim ~u ~x ~y =
  let inp = (Cyclesim.inputs sim : _ I.t) in
  let outp = (Cyclesim.outputs sim : _ O.t) in
  set inp.u u 1;
  set inp.x x 32;
  set inp.y y 32;
  set inp.run 1 1;
  let safety = ref 0 in
  Cyclesim.cycle sim;
  while Bits.to_int_trunc !(outp.stall) = 1 do
    Cyclesim.cycle sim;
    Int.incr safety;
    if !safety > 40 then failwith "divider did not terminate"
  done;
  let q = Bits.to_unsigned_int !(outp.quot) in
  let r = Bits.to_unsigned_int !(outp.rem) in
  set inp.run 0 1;
  Cyclesim.cycle sim;
  (* clears S back to 0 for the next divide *)
  q, r
;;

let%expect_test "DIV edge vectors — corners random sampling won't reliably hit" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let check ~u ~x ~y =
    let qh, rh = run_div sim ~u ~x ~y in
    let qr, rr = reference ~u ~x ~y in
    if not (qh = qr && rh = rr)
    then
      failwith
        (Stdlib.Printf.sprintf
           "edge u=%d x=%#x y=%#x: hw=(%#x,%#x) ref=(%#x,%#x)"
           u
           x
           y
           qh
           rh
           qr
           rr)
  in
  List.iter
    [ 1, 0x8000_0000, 1 (* INT_MIN / 1 = INT_MIN r0 (−x wraps → |INT_MIN| = 2^31) *)
    ; 1, 0x8000_0000, 3 (* INT_MIN / 3, floored *)
    ; 1, 0x8000_0000, 0x7FFF_FFFF (* INT_MIN / largest legal divisor *)
    ; 1, 0x8000_0001, 1 (* (INT_MIN+1) / 1 *)
    ; 1, 0xFFFF_FFFF, 2 (* −1 / 2 = −1 r1 (floored) *)
    ; 1, 0xFFFF_FFF9, 2 (* −7 / 2 = −4 r1 *)
    ; 1, 0x0000_0007, 2 (* 7 / 2 = 3 r1 *)
    ; 1, 0x0000_0008, 2 (* 8 / 2 = 4 r0 (exact) *)
    ; 0, 0x0000_0000, 5 (* 0 / 5 = 0 r0 *)
    ; 0, 0x0000_0003, 5 (* x < y → 0 r3 *)
    ; 0, 0xFFFF_FFFF, 1 (* max / 1 *)
    ; 0, 0xFFFF_FFFF, 0x7FFF_FFFF (* max / largest legal divisor *)
    ]
    ~f:(fun (u, x, y) -> check ~u ~x ~y);
  [%expect {| |}]
;;

let%expect_test "DIV = floored/unsigned reference [qcheck, 2000 cases]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:2000
       ~name:"div"
       QCheck.(triple (int_bound 1) (int_bound 0xFFFF_FFFF) (int_range 1 0x7FFF_FFFF))
       (fun (u, x, y) ->
         let qh, rh = run_div sim ~u ~x ~y in
         let qr, rr = reference ~u ~x ~y in
         qh = qr && rh = rr));
  [%expect {| |}]
;;

let%expect_test "DIV timing — signed -7/2 = -4 rem 1: stall envelope + outputs" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  (* one idle cycle so the run/stall edges show, then signed −7 / 2 → quot −4, rem 1
     (floored, non-negative remainder); run releases the cycle stall clears, as the core
     sequences it. quot/rem are 32-bit so they render fully; the .mli covers the
     sign-correction math. *)
  set inp.u 1 1;
  set inp.x 0xFFFF_FFF9 32;
  set inp.y 0x0000_0002 32;
  set inp.run 0 1;
  Cyclesim.cycle sim;
  set inp.run 1 1;
  Cyclesim.cycle sim;
  while Bits.to_int_trunc !(outp.stall) = 1 do
    Cyclesim.cycle sim
  done;
  let q = Bits.to_signed_int !(outp.quot) in
  let r = Bits.to_signed_int !(outp.rem) in
  set inp.run 0 1;
  Cyclesim.cycle sim;
  Cyclesim.cycle sim;
  let rules =
    D.
      [ port_name_is ~wave_format:Wave_format.Bit "run"
      ; port_name_is ~wave_format:Wave_format.Bit "u"
      ; port_name_is ~wave_format:Wave_format.Hex "x"
      ; port_name_is ~wave_format:Wave_format.Hex "y"
      ; port_name_is ~wave_format:Wave_format.Bit "stall"
      ; port_name_is ~wave_format:Wave_format.Hex "quot"
      ; port_name_is ~wave_format:Wave_format.Hex "rem"
      ]
  in
  (* head: idle → run asserts → stall asserts (load + first restoring steps) *)
  Waveform.print ~display_rules:rules ~start_cycle:0 ~wave_width:4 ~display_width:62 waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves────────────────────────────────────────┐
    │run          ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    │u            ││─────────────────────────────────────────────│
    │             ││                                             │
    │             ││─────────────────────────────────────────────│
    │x            ││ FFFFFFF9                                    │
    │             ││─────────────────────────────────────────────│
    │             ││─────────────────────────────────────────────│
    │y            ││ 00000002                                    │
    │             ││─────────────────────────────────────────────│
    │stall        ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    │             ││──────────┬───────────────────┬─────────┬────│
    │quot         ││ 00000000 │FFFFFFF9           │FFFFFFF2 │FFFF│
    │             ││──────────┴───────────────────┴─────────┴────│
    │             ││─────────────────────────────────────────────│
    │rem          ││ 00000000                                    │
    │             ││─────────────────────────────────────────────│
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  (* tail: stall drops at S==33 with quot/rem valid, run releases *)
  Waveform.print
    ~display_rules:rules
    ~start_cycle:31
    ~wave_width:4
    ~display_width:62
    waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves────────────────────────────────────────┐
    │run          ││──────────────────────────────┐              │
    │             ││                              └──────────────│
    │u            ││─────────────────────────────────────────────│
    │             ││                                             │
    │             ││─────────────────────────────────────────────│
    │x            ││ FFFFFFF9                                    │
    │             ││─────────────────────────────────────────────│
    │             ││─────────────────────────────────────────────│
    │y            ││ 00000002                                    │
    │             ││─────────────────────────────────────────────│
    │stall        ││──────────────────────────────┐              │
    │             ││                              └──────────────│
    │             ││──────────┬─────────┬─────────┬─────────┬────│
    │quot         ││ 20000000 │3FFFFFFF │7FFFFFFE │FFFFFFFC │FFFF│
    │             ││──────────┴─────────┴─────────┴─────────┴────│
    │             ││──────────┬─────────────────────────────┬────│
    │rem          ││ 00000000 │00000001                     │0000│
    │             ││──────────┴─────────────────────────────┴────│
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  Stdlib.Printf.printf "signed -7 / 2  ->  quot = %d  rem = %d\n" q r;
  [%expect {| signed -7 / 2  ->  quot = -4  rem = 1 |}]
;;
