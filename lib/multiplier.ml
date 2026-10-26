(* A port of Multiplier.v; the contract is in [multiplier.mli].

   The 64-bit register [P] plays two roles: its low half is the multiplier being consumed,
   bit 0 the current bit; its high half is the running sum. Each step adds the
   multiplicand, gated by that bit, to the high half — a 33-bit add whose carry or sign
   becomes the new top bit — and shifts the whole register right by one. The counter [S]
   sequences it: 0 loads [x], 1..32 add and shift, 33 ends. The signed correction is the
   one subtraction, on the last step. *)

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
    ; z : 'a [@bits 64]
    }
  [@@deriving hardcaml]
end

let create ?(ce = vdd) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* the state freezes with the core under [ce]; see [Divider] *)
  let reg_fb spec ~width ~f = Signal.reg_fb spec ~enable:ce ~width ~f in
  (* [run] is the enable and the synchronous clear. The registers carry the RTL's names,
     [S] and [P]: the equivalence proof pairs registers by name. *)
  let s = reg_fb spec ~width:6 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 6)) -- "S" in
  let p =
    reg_fb spec ~width:64 ~f:(fun p ->
      (* the multiplicand, gated by the current multiplier bit P[0] *)
      let w0 = mux2 (lsb p) i.y (zero 32) in
      (* sign-extend both to 33 bits so the add's carry/sign becomes the new MSB *)
      let hi = sresize (select p ~high:63 ~low:32) ~width:33 in
      let pp = sresize w0 ~width:33 in
      (* the signed correction: subtract on the last step *)
      let w1 = mux2 (s ==:. 32 &: i.u) (hi -: pp) (hi +: pp) in
      (* S=0 loads x into the low half; otherwise accumulate-then-shift-right-by-one *)
      mux2 (s ==:. 0) (zero 32 @: i.x) (w1 @: select p ~high:31 ~low:1))
    -- "P"
  in
  { O.stall = i.run &: ~:(s ==:. 33); z = p }
;;

(* The same product from one signed 33 x 33 multiply. The sign handling follows the RTL
   exactly, so that the high word agrees too: [y] is sign-extended always, [x] only when
   [u]. *)
let create_opt ?(ce = vdd) (i : _ I.t) : _ O.t =
  ignore (ce : Signal.t);
  let x' = mux2 i.u (sresize i.x ~width:33) (uresize i.x ~width:33) in
  let y' = sresize i.y ~width:33 in
  { O.stall = gnd; z = sel_bottom (x' *+ y') ~width:64 }
;;

(* [create_opt] with [stages] registers on the product. The core holds the operands for
   the whole run, so the product is the same from the first cycle on and simply arrives
   [stages] cycles later. *)
let create_opt_pipelined ?(ce = vdd) ?(stages = 2) (i : _ I.t) : _ O.t =
  (* the run counter below is 4 bits and must reach [stages] *)
  if stages < 1 || stages > 15
  then
    failwith
      (Printf.sprintf
         "Multiplier.create_opt_pipelined: stages must be in 1..15, got %d"
         stages);
  let spec = Reg_spec.create () ~clock:i.clock in
  let x' = mux2 i.u (sresize i.x ~width:33) (uresize i.x ~width:33) in
  let y' = sresize i.y ~width:33 in
  let prod = sel_bottom (x' *+ y') ~width:64 in
  (* the synthesizer retimes these into the DSP48 (MREG, PREG) *)
  let z = Fn.apply_n_times ~n:stages (Signal.reg spec ~enable:ce) prod in
  (* [stall] until the run counter reaches [stages] *)
  let s =
    Signal.reg_fb spec ~enable:ce ~width:4 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 4))
  in
  { O.stall = i.run &: ~:(s ==:. stages); z }
;;

(* ── Tests ── A property test against an Int64 reference that has the hardware's
   semantics ([y] always signed, [x] signed when [u]); differential tests of the two DSP
   variants against the iterative unit; and a waveform of the head and the tail of a
   signed -3 x 5. *)

let set r v w = r := Bits.of_unsigned_int ~width:w v

(* One multiply as the core sequences it: [run] up, clock until [stall] drops, read the
   product, then one cycle with [run] low to clear [S]. *)
let run_mul (inp : _ I.t) (out : _ O.t) sim ~u ~x ~y =
  set inp.u u 1;
  set inp.x x 32;
  set inp.y y 32;
  set inp.run 1 1;
  let safety = ref 0 in
  Cyclesim.cycle sim;
  while Bits.to_int_trunc !(out.stall) = 1 do
    Cyclesim.cycle sim;
    Int.incr safety;
    if !safety > 40 then failwith "multiplier did not terminate"
  done;
  let z = Bits.to_signed_int64 !(out.z) in
  set inp.run 0 1;
  Cyclesim.cycle sim;
  (* clears S back to 0 *)
  z
;;

let%expect_test "MUL = x*y reference (signed & unsigned) [qcheck, 2000 cases]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let mul = run_mul inp outp sim in
  let reference ~u ~x ~y =
    let to_s32 v =
      if v >= 0x8000_0000 then Int64.(of_int v - 0x1_0000_0000L) else Int64.of_int v
    in
    let xb = if u = 1 then to_s32 x else Int64.of_int x in
    let yb = to_s32 y in
    Int64.( * ) xb yb
  in
  Test_gen.check_exn
    (QCheck.Test.make
       ~count:2000
       ~name:"mul"
       QCheck.(triple (int_bound 1) Test_gen.word32 Test_gen.word32)
       (fun (u, x, y) -> Int64.equal (mul ~u ~x ~y) (reference ~u ~x ~y)));
  [%expect {| |}]
;;

let%expect_test "MUL create_opt ≡ create (differential qcheck, full 64-bit z, 20000 \
                 cases)"
  =
  (* The DSP variant has no proof of its own: it is compared with the proven iterative
     unit over random (u, x, y), on all 64 bits. Half the cases have y[31] set, where the
     high words must still agree. *)
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
       ~name:"create_opt=create"
       QCheck.(triple (int_bound 1) Test_gen.word32 Test_gen.word32)
       (fun (u, x, y) ->
         Int64.equal (run_mul ri ro ref_sim ~u ~x ~y) (run_mul oi oo opt_sim ~u ~x ~y)));
  [%expect {| |}]
;;

let%expect_test "MUL create_opt_pipelined ≡ create (differential qcheck, stages=2, 20000 \
                 cases)"
  =
  (* The same for the pipelined variant, driven through the run/stall handshake, which
     also checks that [stall] holds for [stages] cycles. *)
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
       ~name:"create_opt_pipelined=create"
       QCheck.(triple (int_bound 1) Test_gen.word32 Test_gen.word32)
       (fun (u, x, y) ->
         Int64.equal (run_mul ri ro ref_sim ~u ~x ~y) (run_mul oi oo opt_sim ~u ~x ~y)));
  [%expect {| |}]
;;

let%expect_test "MUL timing — signed -3*5: stall envelope head/tail + product" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  (* one idle cycle, then signed -3 x 5; [run] is released on the cycle [stall] clears, as
     the core does (otherwise [S] would run past 33 and stall again). The 64-bit product
     does not fit the waveform and is printed below it. *)
  set inp.u 1 1;
  set inp.x 0xFFFF_FFFD 32;
  set inp.y 0x0000_0005 32;
  set inp.run 0 1;
  Cyclesim.cycle sim;
  set inp.run 1 1;
  Cyclesim.cycle sim;
  while Bits.to_int_trunc !(outp.stall) = 1 do
    Cyclesim.cycle sim
  done;
  let z = Bits.to_signed_int64 !(outp.z) in
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
      ]
  in
  (* head: idle → run asserts → stall asserts (the load + first iterations) *)
  Waveform.print ~display_rules:rules ~start_cycle:0 ~wave_width:4 ~display_width:62 waves;
  [%expect
    {|
    ┌Signals──────┐┌Waves────────────────────────────────────────┐
    │run          ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    │u            ││─────────────────────────────────────────────│
    │             ││                                             │
    │             ││─────────────────────────────────────────────│
    │x            ││ FFFFFFFD                                    │
    │             ││─────────────────────────────────────────────│
    │             ││─────────────────────────────────────────────│
    │y            ││ 00000005                                    │
    │             ││─────────────────────────────────────────────│
    │stall        ││          ┌──────────────────────────────────│
    │             ││──────────┘                                  │
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  (* tail: stall drops at S==33, run releases (the 33-cycle middle is uniform stall=1) *)
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
    │x            ││ FFFFFFFD                                    │
    │             ││─────────────────────────────────────────────│
    │             ││─────────────────────────────────────────────│
    │y            ││ 00000005                                    │
    │             ││─────────────────────────────────────────────│
    │stall        ││──────────────────────────────┐              │
    │             ││                              └──────────────│
    └─────────────┘└─────────────────────────────────────────────┘
    |}];
  Stdlib.Printf.printf "signed -3 * 5  ->  z = 0x%016Lx  (= %Ld)\n" z z;
  [%expect {| signed -3 * 5  ->  z = 0xfffffffffffffff1  (= -15) |}]
;;

let%expect_test "MUL create_opt_pipelined — stages outside 1..15 fail at elaboration" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  List.iter [ 0; 16 ] ~f:(fun stages ->
    match Sim.create (create_opt_pipelined ~stages) with
    | (_ : Sim.t) -> Stdlib.print_endline "elaborated"
    | exception Failure msg -> Stdlib.print_endline msg);
  [%expect
    {|
    Multiplier.create_opt_pipelined: stages must be in 1..15, got 0
    Multiplier.create_opt_pipelined: stages must be in 1..15, got 16
    |}]
;;
