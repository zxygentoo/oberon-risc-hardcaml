(* Public API and behaviour spec live in [multiplier.mli].

   Implementation note. This is a *sequential* unit, so per AGENT.md §2 we mirror
   RISC5.v's skeleton exactly — which signals are registered and the state/stall timing
   are the spec the oracle checks cycle-by-cycle and synthesis preserves. The original RTL
   is [test/_po/verilog/src/Multiplier.v] (25 lines).

   The 64-bit [P] register is dual-role: its low half is the multiplier being consumed
   (its LSB is the current bit), its high half is the running accumulator. Each step adds
   the gated multiplicand to the top — a 33-bit add, whose carry/sign becomes the new MSB
   — then shifts the whole register right by one, so the multiplier slides down and the
   sum lands above it. The 6-bit counter [S] sequences it: S=0 loads x, S=1..32
   accumulate-and-shift, S=33 ends. No reset — [run] gates [S] (run=0 → S:=0), and S=0
   forces the load, faithful to the RTL. The signed correction is the lone subtract on the
   last step (S=32; see §8). *)

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
  (* Phase 7: ce-gate the unit's state so it freezes with the ce-gated core during a
     multi-cycle PSRAM wait (else the counter overruns the fetch-wait and the op restarts
     — see [Divider]). [ce = vdd] (the default) ⇒ byte-identical. *)
  let reg_fb spec ~width ~f = Signal.reg_fb spec ~enable:ce ~width ~f in
  (* S : 6-bit state counter; [run] is both enable and synchronous clear (no reset). *)
  (* Registers named to match the RTL ([S]/[P]) so the Phase-8 formal harness can pair the
     flip-flops with Multiplier.v's (yosys [equiv_make] matches FFs by name —
     test/formal). *)
  let s = reg_fb spec ~width:6 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 6)) -- "S" in
  (* P : 64-bit dual-role register. [s] is in scope, so P's feedback can test S==0/S==32. *)
  let p =
    reg_fb spec ~width:64 ~f:(fun p ->
      (* the multiplicand, gated by the current multiplier bit P[0] *)
      let w0 = mux2 (lsb p) i.y (zero 32) in
      (* sign-extend both to 33 bits so the add's carry/sign becomes the new MSB *)
      let hi = sresize (select p ~high:63 ~low:32) ~width:33 in
      let pp = sresize w0 ~width:33 in
      (* signed correction: the lone subtract on the last step (S=32; §8) *)
      let w1 = mux2 (s ==:. 32 &: i.u) (hi -: pp) (hi +: pp) in
      (* S=0 loads x into the low half; otherwise accumulate-then-shift-right-by-one *)
      mux2 (s ==:. 0) (zero 32 @: i.x) (w1 @: select p ~high:31 ~low:1))
    -- "P"
  in
  { O.stall = i.run &: ~:(s ==:. 33); z = p }
;;

(* Phase-9 optimised variant (AGENT.md §5). The structural 33-cycle shift-add above is
   just computing one product; here we say that directly — a single signed 33×33 multiply
   ([*+]) that Vivado lowers onto the board's idle DSP48 slices. Combinational, so the op
   retires in ONE cycle ([stall] tied low) instead of 33. It reproduces [Multiplier.v]'s
   §8 sign handling exactly so it stays bit-identical to [create]: [y] is sign-extended
   unconditionally, [x] only when signed ([u]) — so unsigned [MUL'] still yields
   [x_unsigned × y_signed] (the low 32 bits, R.a, always agree; only [H] carries the
   quirk). The whole structural multiplier collapses to operand-prep + one [*+]. Verified
   by the co-located differential qcheck against the formally-proven [create] (not
   re-formalised). [ce] is irrelevant to a stateless unit — accepted only to match
   [create]'s signature. *)
let create_opt ?(ce = vdd) (i : _ I.t) : _ O.t =
  ignore (ce : Signal.t);
  let x' = mux2 i.u (sresize i.x ~width:33) (uresize i.x ~width:33) in
  let y' = sresize i.y ~width:33 in
  { O.stall = gnd; z = sel_bottom (x' *+ y') ~width:64 }
;;

(* Phase-9 experiment (feat/fast-clock) — a *pipelined* DSP multiply, for pushing the
   system clock past ~52 MHz. {!create_opt} is combinational (regfile→DSP→result in one
   cycle), which is the critical path at 50 MHz; here the 64-bit product is pushed through
   [stages] output flops that Vivado retimes into the DSP48's own MREG/PREG, splitting
   that one long hop into [stages] short ones. The op is then multi-cycle again: a small
   counter holds [stall] for [stages] cycles — the core's ordinary multi-cycle protocol
   (like the iterative unit, but 2 cycles instead of 33). The core freezes PC/IR across
   the run, so [x]/[y] are held stable and the product is constant from cycle 0 — it just
   arrives [stages] cycles later, bit-identical to {!create_opt}/{!create} (differential
   qcheck). [stages = 0] would be the combinational case, but that is {!create_opt}; use
   [stages >= 1] here. *)
let create_opt_pipelined ?(ce = vdd) ?(stages = 2) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  let x' = mux2 i.u (sresize i.x ~width:33) (uresize i.x ~width:33) in
  let y' = sresize i.y ~width:33 in
  let prod = sel_bottom (x' *+ y') ~width:64 in
  (* [stages] registers on the product; Vivado pulls them into the DSP (PREG/MREG/…) *)
  let z = Fn.apply_n_times ~n:stages (Signal.reg spec ~enable:ce) prod in
  (* counter: run-gated (run=0 ⇒ S:=0, no reset); [stall] high until S reaches [stages] *)
  let s =
    Signal.reg_fb spec ~enable:ce ~width:4 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 4))
  in
  { O.stall = i.run &: ~:(s ==:. stages); z }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness: qcheck the full multiply against a pure-OCaml Int64 reference (3a's oracle
   — no fp_vectors, no emulator). The reference encodes the *hardware* semantics: [y] is
   always signed, [x] is signed iff [u=1] (so unsigned [MUL'] = x_unsigned × y_signed,
   §8). One sim is reused across cases; a multiply ends when [stall] drops, after which
   [run] is dropped for one cycle to clear [S]=0 for the next case — exactly how the core
   sequences it. Behaviour: since the full run is 33 cycles, two tight windows of a signed
   −3×5 — the head (run→stall asserts) and the tail (stall drops, run releases) — bracket
   the uniform middle; the 64-bit product is too wide for the wave, so it's printed below. *)

let set r v w = r := Bits.of_unsigned_int ~width:w v

(* Run one multiply through the run/stall handshake, exactly as the core sequences it: run
   asserts, cycle until stall drops, read the 64-bit product, then a run=0 cycle to clear
   S for the next case. Also drives the combinational [create_opt] (stall never asserts;
   the first cycle evaluates it). Guards against a wedged stall. *)
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
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:2000
       ~name:"mul"
       QCheck.(triple (int_bound 1) (int_bound 0xFFFF_FFFF) (int_bound 0xFFFF_FFFF))
       (fun (u, x, y) -> Int64.equal (mul ~u ~x ~y) (reference ~u ~x ~y)));
  [%expect {| |}]
;;

let%expect_test "MUL create_opt ≡ create (differential qcheck, full 64-bit z, 20000 \
                 cases)"
  =
  (* The Phase-9 fast variant rides [create]'s Phase-8 proof: show the combinational DSP
     multiply is bit-identical to the formally-proven iterative unit over random (u, x,
     y), comparing the full 64-bit product. The §8 unsigned-MUL' quirk is covered for free
     — half the cases have y[31]=1, where the H words must still agree. *)
  let module Sim = Cyclesim.With_interface (I) (O) in
  let ref_sim = Sim.create create
  and opt_sim = Sim.create create_opt in
  let ri = Cyclesim.inputs ref_sim
  and ro = Cyclesim.outputs ref_sim
  and oi = Cyclesim.inputs opt_sim
  and oo = Cyclesim.outputs opt_sim in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:20_000
       ~name:"create_opt=create"
       QCheck.(triple (int_bound 1) (int_bound 0xFFFF_FFFF) (int_bound 0xFFFF_FFFF))
       (fun (u, x, y) ->
         Int64.equal (run_mul ri ro ref_sim ~u ~x ~y) (run_mul oi oo opt_sim ~u ~x ~y)));
  [%expect {| |}]
;;

let%expect_test "MUL create_opt_pipelined ≡ create (differential qcheck, stages=2, 20000 \
                 cases)"
  =
  (* Same differential check as above, but the fast side is the *pipelined* DSP variant:
     drive it through the run/stall handshake exactly as the core does (it is multi-cycle
     now), and confirm the registered product matches the iterative unit bit-for-bit. This
     also exercises the pipeline's counter/stall timing — [stall] must hold for [stages]
     cycles then drop with the product valid. *)
  let module Sim = Cyclesim.With_interface (I) (O) in
  let ref_sim = Sim.create create
  and opt_sim = Sim.create (create_opt_pipelined ~stages:2) in
  let ri = Cyclesim.inputs ref_sim
  and ro = Cyclesim.outputs ref_sim
  and oi = Cyclesim.inputs opt_sim
  and oo = Cyclesim.outputs opt_sim in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:20_000
       ~name:"create_opt_pipelined=create"
       QCheck.(triple (int_bound 1) (int_bound 0xFFFF_FFFF) (int_bound 0xFFFF_FFFF))
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
  (* one idle cycle (run=0) so the run/stall rising edges are visible, then a full signed
     −3 × 5 = −15; run is released the cycle stall clears, exactly as the core sequences
     it (otherwise S would tick past 33 and re-stall). z is 64-bit — too wide to render at
     wave_width 4 — so the wave shows the control/timing and the product is printed below. *)
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
