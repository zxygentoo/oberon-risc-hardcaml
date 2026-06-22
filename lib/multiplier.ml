(* Public API and behaviour spec live in [multiplier.mli].

   Implementation note. This is a *sequential* unit, so per AGENT.md §2 we mirror
   RISC5.v's skeleton exactly — which signals are registered and the state/stall timing
   are the spec the oracle checks cycle-by-cycle and synthesis preserves. The original RTL
   is [_po/verilog/src/Multiplier.v] (25 lines); each [create] line below is tagged with
   the wire it ports (formatting these as verbatim multi-line code in a comment doesn't
   survive ocamlformat, so they stay inline).

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

let create (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* S : 6-bit state counter; [run] is both enable and synchronous clear (no reset). *)
  let s = reg_fb spec ~width:6 ~f:(fun s -> mux2 i.run (s +:. 1) (zero 6)) in
  (* P : 64-bit dual-role register. [s] is in scope, so P's feedback can test S==0/S==32. *)
  let p =
    reg_fb spec ~width:64 ~f:(fun p ->
      let w0 = mux2 (lsb p) i.y (zero 32) in
      (* P[0] ? y : 0 *)
      let hi = sresize (select p ~high:63 ~low:32) ~width:33 in
      (* {P[63],P[63:32]} *)
      let pp = sresize w0 ~width:33 in
      (* {w0[31],w0} *)
      let w1 = mux2 (s ==:. 32 &: i.u) (hi -: pp) (hi +: pp) in
      mux2
        (s ==:. 0)
        (zero 32 @: i.x) (* load {32'b0, x} *)
        (w1 @: select p ~high:31 ~low:1)
      (* {w1[32:0], P[31:1]} *))
  in
  { O.stall = i.run &: ~:(s ==:. 33); z = p }
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

let%expect_test "MUL = x*y reference (signed & unsigned) [qcheck, 2000 cases]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  (* run one full multiply on the shared sim, returning the 64-bit product as Int64 *)
  let mul ~u ~x ~y =
    set inp.u u 1;
    set inp.x x 32;
    set inp.y y 32;
    set inp.run 1 1;
    let safety = ref 0 in
    Cyclesim.cycle sim;
    while Bits.to_int_trunc !(outp.stall) = 1 do
      Cyclesim.cycle sim;
      Int.incr safety;
      if !safety > 40 then failwith "multiplier did not terminate"
    done;
    let z = Bits.to_signed_int64 !(outp.z) in
    set inp.run 0 1;
    Cyclesim.cycle sim;
    (* clears S back to 0 *)
    z
  in
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

let%expect_test "MUL timing — signed -3*5: stall envelope head/tail + product" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
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
