(* Public API and behaviour spec live in [ps2.mli].

   Port of [PS2.v]. The keyboard provides its OWN clock, so unlike the UART there is no
   baud divider — three ideas carry the design:

   - CLOCK RECOVERY. A 2-FF chain [Q0]/[Q1] synchronizes the asynchronous [ps2c]; [shift]
     = [Q1 & ~Q0] is a one-cycle pulse on each ps2c falling edge — the bit strobe that
     samples [ps2d]. The device's clock is the timing.
   - WALKING START BIT. [shreg] is 11 bits, reset to all-1s; each [shift] brings [ps2d] in
     at the top ([{ps2d, shreg[10:1]}], a right-shift). [endbit = ~shreg[0]]: the start
     bit (0, the first bit in) is always the lowest frame bit, so bit 0 stays 1 until it
     walks down — after exactly the 11 frame bits (start, 8 data, parity, stop). No bit
     counter; the start bit IS the counter, and the byte then sits in [shreg[8:1]].
   - 16-BYTE FIFO. On [endbit] the byte is pushed at [inptr] (inptr++); [rdy] =
     inptr<>outptr (non-empty), [data] = fifo[outptr], and a read pulse [done_] pops
     (outptr++). It buffers keystrokes, decoupling the keyboard from the CPU. Modeled as a
     [multiport_memory] — one synchronous write, one asynchronous read — exactly like the
     register file ([registers.ml]).

   [rst] is active-low and synchronous; per the RTL it resets [shreg] (to all-1s), [inptr]
   and [outptr], so those carry a reset term while [Q0]/[Q1] just track [ps2c]. Clock-only
   [Reg_spec], like the rest of the peripherals. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; done_ : 'a [@bits 1]
    ; ps2c : 'a [@bits 1]
    ; ps2d : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rdy : 'a [@bits 1]
    ; shift : 'a [@bits 1]
    ; data : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  let reset = ~:(i.rst_n) in
  let q0 = Always.Variable.reg spec ~width:1 in
  let q1 = Always.Variable.reg spec ~width:1 in
  let shreg = Always.Variable.reg spec ~width:11 in
  let inptr = Always.Variable.reg spec ~width:4 in
  let outptr = Always.Variable.reg spec ~width:4 in
  let q0_v = q0.value -- "q0" in
  let q1_v = q1.value -- "q1" in
  let shreg_v = shreg.value -- "shreg" in
  let inptr_v = inptr.value -- "inptr" in
  let outptr_v = outptr.value -- "outptr" in
  let endbit = ~:(lsb shreg_v) -- "endbit" in
  let shift = q1_v &: ~:q0_v in
  let rdy = ~:(inptr_v ==: outptr_v) in
  (* 16x8 FIFO: synchronous write of shreg[8:1] at inptr on endbit, asynchronous read at
     outptr (same shape as the register file — let synthesis infer distributed RAM) *)
  let write_port =
    { Write_port.write_clock = i.clock
    ; write_address = inptr_v
    ; write_enable = endbit
    ; write_data = select shreg_v ~high:8 ~low:1
    }
  in
  let reads =
    multiport_memory
      16
      ~name:"fifo"
      ~initialize_to:(Array.init 16 ~f:(fun _ -> Bits.of_unsigned_int ~width:8 0))
      ~write_ports:[| write_port |]
      ~read_addresses:[| outptr_v |]
  in
  let data = reads.(0) in
  Always.(
    compile
      [ q0 <-- i.ps2c
      ; q1 <-- q0_v
      ; shreg
        <-- mux2
              (reset |: endbit)
              (of_unsigned_int ~width:11 0x7FF)
              (mux2 shift (concat_msb [ i.ps2d; select shreg_v ~high:10 ~low:1 ]) shreg_v)
      ; inptr <-- mux2 reset (zero 4) (mux2 endbit (inptr_v +:. 1) inptr_v)
      ; outptr <-- mux2 reset (zero 4) (mux2 (rdy &: i.done_) (outptr_v +:. 1) outptr_v)
      ]);
  { O.rdy; shift; data }
;;

module For_tests = struct
  let odd_parity data =
    let ones = ref 0 in
    for j = 0 to 7 do
      ones := !ones + ((data lsr j) land 1)
    done;
    1 - (!ones land 1)
  ;;

  let frame_bits data =
    (false :: List.init 8 ~f:(fun j -> (data lsr j) land 1 = 1))
    @ [ odd_parity data = 1; true ]
  ;;
end

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── The
   testbench plays the keyboard: clock 11-bit frames on ps2c/ps2d and read the recovered
   bytes back through the FIFO. Functional decode + a multi-byte FIFO order check + a
   qcheck round-trip, plus a waveform of the clock-recovery front end (ps2c edge → shift →
   shreg walking). The exhaustive bit-for-bit fidelity check vs [PS2.v] is the Verilator
   co-sim. *)

let lo = Bits.gnd
let hi = Bits.vdd
let bit b = if b then hi else lo
let h = 4 (* ps2c half-period in clocks (>=2 for the synchronizer to see the edge) *)

let reset_idle sim (inp : _ I.t) =
  inp.rst_n := lo;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.done_ := lo;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  Cyclesim.cycle sim
;;

(* one device clock: present the data bit, then a ps2c falling edge (h high + h low) so
   the DUT's synchronizer sees it *)
let send_bit sim (inp : _ I.t) b =
  inp.ps2d := bit b;
  inp.ps2c := hi;
  for _ = 1 to h do
    Cyclesim.cycle sim
  done;
  inp.ps2c := lo;
  for _ = 1 to h do
    Cyclesim.cycle sim
  done
;;

(* play the keyboard: clock the 11 frame bits ({!For_tests.frame_bits}) on ps2c/ps2d; the
   DUT shifts ps2d in on each ps2c falling edge. Leaves ps2c idle high. *)
let send_byte sim (inp : _ I.t) ~data =
  List.iter (For_tests.frame_bits data) ~f:(send_bit sim inp);
  inp.ps2c := hi;
  for _ = 1 to h do
    Cyclesim.cycle sim
  done
;;

(* pulse [done_] one cycle to pop the FIFO head *)
let pop sim (inp : _ I.t) =
  inp.done_ := hi;
  Cyclesim.cycle sim;
  inp.done_ := lo;
  Cyclesim.cycle sim
;;

let%expect_test "ps2 — recover a scancode, then done pops it" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  send_byte sim inp ~data:0x1C;
  let rdy = Bits.to_int_trunc !(outp.rdy) in
  let data = Bits.to_int_trunc !(outp.data) in
  pop sim inp;
  let rdy_after = Bits.to_int_trunc !(outp.rdy) in
  Stdlib.Printf.printf
    "rdy=%d data=0x%X (sent 0x1C); after done rdy=%d\n"
    rdy
    data
    rdy_after;
  [%expect {| rdy=1 data=0x1C (sent 0x1C); after done rdy=0 |}]
;;

let%expect_test "ps2 — 16-byte FIFO buffers and pops in order" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  (* push three scancodes before reading any *)
  List.iter [ 0x11; 0x22; 0x33 ] ~f:(fun d -> send_byte sim inp ~data:d);
  let read () =
    let d = Bits.to_int_trunc !(outp.data) in
    pop sim inp;
    d
  in
  let a = read () in
  let b = read () in
  let c = read () in
  let rdy_after = Bits.to_int_trunc !(outp.rdy) in
  Stdlib.Printf.printf "popped 0x%X 0x%X 0x%X; rdy now %d\n" a b c rdy_after;
  [%expect {| popped 0x11 0x22 0x33; rdy now 0 |}]
;;

let%expect_test "ps2 — random scancode round-trips [qcheck]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  QCheck.Test.check_exn
    (QCheck.Test.make ~count:64 ~name:"ps2-roundtrip" (QCheck.int_bound 0xFF) (fun data ->
       send_byte sim inp ~data;
       let rdy = Bits.to_int_trunc !(outp.rdy) in
       let got = Bits.to_int_trunc !(outp.data) in
       pop sim inp;
       rdy = 1 && got = data));
  [%expect {| |}]
;;

(* Front end: a ps2c falling edge produces a one-cycle [shift], which clocks [ps2d] into
   the top of [shreg] (the byte walking in LSbit-first). Two bits of 0x1C (=
   ...0,0,1,1,1,0,0; here the start bit then d0=0, d1=0). *)
let%expect_test "ps2 — clock recovery [waveform: ps2c edge → shift → shreg]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  reset_idle sim inp;
  send_bit sim inp false;
  send_bit sim inp false;
  Waveform.print
    ~start_cycle:2
    ~wave_width:2
    ~display_width:74
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "ps2c"
        ; port_name_is ~wave_format:Wave_format.Bit "shift"
        ; port_name_is ~wave_format:Wave_format.Hex "shreg"
        ]
    waves;
  [%expect
    {|
    ┌Signals─────────┐┌Waves─────────────────────────────────────────────────┐
    │ps2c            ││────────────────────────┐                       ┌─────│
    │                ││                        └───────────────────────┘     │
    │shift           ││                              ┌─────┐                 │
    │                ││──────────────────────────────┘     └─────────────────│
    │                ││────────────────────────────────────┬─────────────────│
    │shreg           ││ 7FF                                │3FF              │
    │                ││────────────────────────────────────┴─────────────────│
    └────────────────┘└──────────────────────────────────────────────────────┘
    |}]
;;
