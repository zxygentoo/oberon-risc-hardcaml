(* A port of FPMultiplier.v; the contract is in [fp_multiplier.mli].

   The mantissa engine is the integer [Multiplier] in miniature. [P] is 48 bits: its low
   half holds [x]'s mantissa being consumed, its high half the running sum. Each step adds
   [y]'s mantissa, gated by [P[0]], to the high half (a 25-bit add whose carry becomes the
   new top bit) and shifts the register right by one. [S] sequences it: 0 loads, 1..24 add
   and shift, 25 ends.

   Around it, combinationally: the sign is the XOR of the operands' signs; the exponent is
   [xe + ye - 127], plus one when the product reached bit 47; the mantissa is rounded from
   bit 47 or 46 accordingly; and a zero operand, overflow (to infinity) and underflow (to
   zero) are mapped as the RTL maps them. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; run : 'a [@bits 1]
    ; x : 'a [@bits 32]
    ; y : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { stall : 'a [@bits 1]
    ; z : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

(* Everything but the mantissa product, shared by the three variants below: they differ
   only in how they form [p]. *)
let pack ~p (i : _ I.t) =
  let sign = msb i.x ^: msb i.y in
  let xe = select i.x ~high:30 ~low:23 in
  let ye = select i.y ~high:30 ~low:23 in
  let e0 = uresize xe ~width:9 +: uresize ye ~width:9 in
  (* remove one exponent bias; bump by one when the product reached bit 47 (>= 2.0) *)
  let e1 = e0 -:. 127 +: uresize (msb p) ~width:9 in
  (* round (+1) and normalize, from bit 47 or 46 depending on that carry *)
  let z0 =
    mux2 (msb p) (select p ~high:47 ~low:23 +:. 1) (select p ~high:46 ~low:22 +:. 1)
  in
  let mant = select z0 ~high:23 ~low:1 in
  let normal = sign @: select e1 ~high:7 ~low:0 @: mant in
  let inf = sign @: ones 8 @: mant in
  (* a zero operand -> 0; exponent in range -> normal; overflow -> inf; underflow -> 0
     (the borrow/sign bits of e1 distinguish the three exponent cases) *)
  mux2
    (xe ==:. 0 |: (ye ==:. 0))
    (zero 32)
    (mux2 ~:(msb e1) normal (mux2 ~:(select e1 ~high:7 ~low:7) inf (zero 32)))
;;

let create ?(ce = vdd) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* the state freezes with the core under [ce]; see [Divider] *)
  let reg_fb spec ~width ~f = Signal.reg_fb spec ~enable:ce ~width ~f in
  (* [run] is the enable and the synchronous clear. The registers carry the RTL's names,
     [S] and [P]: the equivalence proof pairs registers by name. *)
  let s = reg_fb spec ~width:5 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 5)) -- "S" in
  let p =
    reg_fb spec ~width:48 ~f:(fun p ->
      (* y's mantissa (with restored hidden bit), gated by the current x-mantissa bit P[0] *)
      let w0 = mux2 (lsb p) (vdd @: select i.y ~high:22 ~low:0) (zero 24) in
      (* 25-bit add of the accumulator's top 24 bits, the carry becoming the new MSB *)
      let w1 = uresize (select p ~high:47 ~low:24) ~width:25 +: uresize w0 ~width:25 in
      (* S=0 loads x's mantissa into the low half; else accumulate-then-shift-right-by-one *)
      mux2
        (s ==:. 0)
        (zero 24 @: vdd @: select i.x ~high:22 ~low:0)
        (w1 @: select p ~high:23 ~low:1))
    -- "P"
  in
  { O.stall = i.run &: ~:(s ==:. 25); z = pack ~p i }
;;

(* The same mantissa product from one unsigned 24 x 24 multiply. *)
let create_opt ?(ce = vdd) (i : _ I.t) : _ O.t =
  ignore (ce : Signal.t);
  let xm = vdd @: select i.x ~high:22 ~low:0 in
  let ym = vdd @: select i.y ~high:22 ~low:0 in
  { O.stall = gnd; z = pack ~p:(xm *: ym) i }
;;

(* [create_opt] with [stages] registers on the mantissa product, ahead of [pack]. *)
let create_opt_pipelined ?(ce = vdd) ?(stages = 2) (i : _ I.t) : _ O.t =
  (* the run counter below is 4 bits and must reach [stages] *)
  if stages < 1 || stages > 15
  then
    failwith
      (Printf.sprintf
         "Fp_multiplier.create_opt_pipelined: stages must be in 1..15, got %d"
         stages);
  let spec = Reg_spec.create () ~clock:i.clock in
  let xm = vdd @: select i.x ~high:22 ~low:0 in
  let ym = vdd @: select i.y ~high:22 ~low:0 in
  (* the synthesizer retimes these into the DSP48 *)
  let p = Fn.apply_n_times ~n:stages (Signal.reg spec ~enable:ce) (xm *: ym) in
  let s =
    Signal.reg_fb spec ~enable:ce ~width:4 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 4))
  in
  { O.stall = i.run &: ~:(s ==:. stages); z = pack ~p i }
;;

(* ── Tests ── The values are checked against FPMultiplier.v by the co-simulation, and
   against the frozen vectors in test/. Here: the timing ([S] walks from 0 to 25 and
   [stall] drops at 25), one value (2.0 x 2.0), and differential tests of the two DSP
   variants against the iterative unit. *)

let set r v w = r := Bits.of_unsigned_int ~width:w v

(* One FML as the core sequences it: [run] up, clock until [stall] drops, read [z], then
   one cycle with [run] low to clear [S]. *)
let run_fml (inp : _ I.t) (out : _ O.t) sim ~x ~y =
  set inp.x x 32;
  set inp.y y 32;
  set inp.run 1 1;
  let safety = ref 0 in
  Cyclesim.cycle sim;
  while Bits.to_int_trunc !(out.stall) = 1 do
    Cyclesim.cycle sim;
    Int.incr safety;
    if !safety > 40 then failwith "fp multiplier did not terminate"
  done;
  let z = Bits.to_unsigned_int !(out.z) in
  set inp.run 0 1;
  Cyclesim.cycle sim;
  z
;;

let%expect_test "FML create_opt ≡ create (differential qcheck, 32-bit z, 20000 cases)" =
  (* The DSP variant has no proof of its own: it is compared with the proven iterative
     unit over random bit patterns, on the whole result. Both form the same 48-bit product
     and share [pack], so they agree on every input, the RTL's non-IEEE corners included. *)
  let module Sim = Cyclesim.With_interface (I) (O) in
  let ref_sim = Sim.create create
  and opt_sim = Sim.create create_opt in
  let ri = Cyclesim.inputs ref_sim
  and ro = Cyclesim.outputs ref_sim
  and oi = Cyclesim.inputs opt_sim
  and oo = Cyclesim.outputs opt_sim in
  Test_gen.check_exn
    (QCheck.Test.make
       ~count:20_000
       ~name:"fp_create_opt=create"
       QCheck.(pair Test_gen.fp32 Test_gen.fp32)
       (fun (x, y) ->
         Int.equal (run_fml ri ro ref_sim ~x ~y) (run_fml oi oo opt_sim ~x ~y)));
  [%expect {| |}]
;;

let%expect_test "FML create_opt_pipelined ≡ create (differential qcheck, stages=2, 20000 \
                 cases)"
  =
  (* The same for the pipelined variant, driven through the run/stall handshake. *)
  let module Sim = Cyclesim.With_interface (I) (O) in
  let ref_sim = Sim.create create
  and opt_sim = Sim.create (create_opt_pipelined ~stages:2) in
  let ri = Cyclesim.inputs ref_sim
  and ro = Cyclesim.outputs ref_sim
  and oi = Cyclesim.inputs opt_sim
  and oo = Cyclesim.outputs opt_sim in
  Test_gen.check_exn
    (QCheck.Test.make
       ~count:20_000
       ~name:"fp_create_opt_pipelined=create"
       QCheck.(pair Test_gen.fp32 Test_gen.fp32)
       (fun (x, y) ->
         Int.equal (run_fml ri ro ref_sim ~x ~y) (run_fml oi oo opt_sim ~x ~y)));
  [%expect {| |}]
;;

let%expect_test "FPMultiplier timing — stall envelope (S 0->25) + FML 2.0 * 2.0 = 4.0" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  (* one idle cycle, then FML with the operands held; [z] is read when [stall] drops, and
     [run] is released on the next cycle, as the core does *)
  set inp.x 0x4000_0000 32;
  set inp.y 0x4000_0000 32;
  set inp.run 0 1;
  Cyclesim.cycle sim;
  set inp.run 1 1;
  Cyclesim.cycle sim;
  while Bits.to_int_trunc !(outp.stall) = 1 do
    Cyclesim.cycle sim
  done;
  let z_result = Bits.to_unsigned_int !(outp.z) in
  set inp.run 0 1;
  Cyclesim.cycle sim;
  let rules =
    D.
      [ port_name_is ~wave_format:Wave_format.Bit "run"
      ; port_name_is ~wave_format:Wave_format.Hex "x"
      ; port_name_is ~wave_format:Wave_format.Hex "y"
      ; port_name_is ~wave_format:Wave_format.Bit "stall"
      ]
  in
  (* head: idle -> run asserts -> stall asserts (the load + first iterations) *)
  Waveform.print ~display_rules:rules ~start_cycle:0 ~wave_width:4 ~display_width:62 waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves────────────────────────────────────────┐
    │run          ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    │             ││─────────────────────────────────────────────│
    │x            ││ 40000000                                    │
    │             ││─────────────────────────────────────────────│
    │             ││─────────────────────────────────────────────│
    │y            ││ 40000000                                    │
    │             ││─────────────────────────────────────────────│
    │stall        ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  (* tail: stall drops at S==25, run releases (the 25-cycle middle is uniform stall=1) *)
  Waveform.print
    ~display_rules:rules
    ~start_cycle:23
    ~wave_width:4
    ~display_width:62
    waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves────────────────────────────────────────┐
    │run          ││──────────────────────────────┐              │
    │             ││                              └─────────     │
    │             ││────────────────────────────────────────     │
    │x            ││ 40000000                                    │
    │             ││────────────────────────────────────────     │
    │             ││────────────────────────────────────────     │
    │y            ││ 40000000                                    │
    │             ││────────────────────────────────────────     │
    │stall        ││──────────────────────────────┐              │
    │             ││                              └─────────     │
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  Stdlib.Printf.printf "FML 2.0 * 2.0  ->  z = 0x%08X\n" z_result;
  [%expect {| FML 2.0 * 2.0  ->  z = 0x40800000 |}]
;;

let%expect_test "FML create_opt_pipelined — stages outside 1..15 fail at elaboration" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  List.iter [ 0; 16 ] ~f:(fun stages ->
    match Sim.create (create_opt_pipelined ~stages) with
    | (_ : Sim.t) -> Stdlib.print_endline "elaborated"
    | exception Failure msg -> Stdlib.print_endline msg);
  [%expect
    {|
    Fp_multiplier.create_opt_pipelined: stages must be in 1..15, got 0
    Fp_multiplier.create_opt_pipelined: stages must be in 1..15, got 16
    |}]
;;
