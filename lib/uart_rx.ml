(* A port of RS232R.v; the contract is in [uart_rx.mli].

   Three things beyond the transmitter:
   - A synchroniser. [rxd] is asynchronous, so two flip-flops [Q0]/[Q1] sample it before
     any logic sees it; [Q1 & ~Q0] is a one-cycle pulse on its falling edge, the start
     bit, and sets [run].
   - Sampling at mid-bit. The divider [tick] counts a bit window and the line is sampled
     at its centre ([midtick], half the limit), so that drift between the two clocks
     cannot pick up the neighbouring bit. Each sample enters [shreg] at the top.
   - Nine windows. [bitcnt] counts the start bit and eight data bits. The start bit enters
     [shreg] first and is pushed off the end of the 8-bit register by the data, leaving
     the byte.

   The start edge sets [run]; the end of the ninth window clears it and sets [stat], which
   is [rdy]; [done_] or reset clears [stat]. Only [run] and [stat] have a reset term, as
   in the RTL. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; rxd : 'a [@bits 1]
    ; fsel : 'a [@bits 1]
    ; done_ : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rdy : 'a [@bits 1]
    ; data : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

let create
  ?(baud_slow = Uart_tx.default_baud_slow)
  ?(baud_fast = Uart_tx.default_baud_fast)
  (i : _ I.t)
  : _ O.t
  =
  let spec = Reg_spec.create () ~clock:i.clock in
  let reset = ~:(i.rst_n) in
  let q0 = Always.Variable.reg spec ~width:1 in
  let q1 = Always.Variable.reg spec ~width:1 in
  let run = Always.Variable.reg spec ~width:1 in
  let stat = Always.Variable.reg spec ~width:1 in
  let tick = Always.Variable.reg spec ~width:12 in
  let bitcnt = Always.Variable.reg spec ~width:4 in
  let shreg = Always.Variable.reg spec ~width:8 in
  let q0_v = q0.value -- "q0" in
  let q1_v = q1.value -- "q1" in
  let run_v = run.value -- "run" in
  let stat_v = stat.value -- "stat" in
  let tick_v = tick.value -- "tick" in
  let bitcnt_v = bitcnt.value -- "bitcnt" in
  let shreg_v = shreg.value -- "shreg" in
  List.iter
    [ "baud_slow", baud_slow; "baud_fast", baud_fast ]
    ~f:(fun (name, v) ->
      if v < 1 || v > 4095
      then
        failwith
          (Printf.sprintf
             "Uart_rx: %s must be in 1..4095 clocks (the 12-bit tick), got %d"
             name
             v));
  let limit =
    mux2
      i.fsel
      (of_unsigned_int ~width:12 baud_fast)
      (of_unsigned_int ~width:12 baud_slow)
  in
  let endtick = (tick_v ==: limit) -- "endtick" in
  let midtick = (tick_v ==: srl limit ~by:1) -- "midtick" in
  let endbit = bitcnt_v ==:. 8 in
  (* the end of the ninth window; named so that the mixed [&:] and [|:] below are
     unambiguous (they have equal precedence) *)
  let frame_done = endtick &: endbit in
  let start_edge = (q1_v &: ~:q0_v) -- "start_edge" in
  Always.(
    compile
      [ q0 <-- i.rxd
      ; q1 <-- q0_v
      ; run <-- (start_edge |: (~:(reset |: frame_done) &: run_v))
      ; tick <-- mux2 (run_v &: ~:endtick) (tick_v +:. 1) (zero 12)
      ; bitcnt
        <-- mux2
              (endtick &: ~:endbit)
              (bitcnt_v +:. 1)
              (mux2 frame_done (zero 4) bitcnt_v)
      ; shreg
        <-- mux2 midtick (concat_msb [ q1_v; select shreg_v ~high:7 ~low:1 ]) shreg_v
      ; stat <-- (frame_done |: (~:(reset |: i.done_) &: stat_v))
      ]);
  { O.rdy = stat_v; data = shreg_v }
;;

(* ── Tests ── The testbench plays the sender: it drives a frame on [rxd] at the bit rate
   and checks the recovered byte and the [rdy]/[done_] handshake, for chosen bytes and in
   a round-trip test. One waveform shows the front end: the synchroniser, the start edge,
   [run]. Fidelity to RS232R.v is the co-simulation's and the proof's job. *)

let lo = Bits.gnd
let hi = Bits.vdd
let bit b = if b then hi else lo

let reset_idle sim (inp : _ I.t) =
  inp.rst_n := lo;
  inp.rxd := hi;
  inp.fsel := lo;
  inp.done_ := lo;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  Cyclesim.cycle sim
;;

(* Play the sender: drive start(0), 8 data LSbit-first, stop(1) on [rxd], each held for
   one bit-window ([limit+1] clocks), then cycle until [rdy] rises. Leaves the line idle
   high with [rdy]=1. Returns (rdy, data). *)
let recv_frame sim (inp : _ I.t) (outp : _ O.t) ~fast ~data =
  let period = if fast then 218 else 1303 in
  inp.fsel := if fast then hi else lo;
  let hold lvl =
    inp.rxd := lvl;
    for _ = 1 to period do
      Cyclesim.cycle sim
    done
  in
  hold lo;
  for j = 0 to 7 do
    hold (bit ((data lsr j) land 1 = 1))
  done;
  hold hi;
  let n = ref 0 in
  while Bits.to_int_trunc !(outp.rdy) = 0 && !n < 2 * period do
    Cyclesim.cycle sim;
    Int.incr n
  done;
  Bits.to_int_trunc !(outp.rdy), Bits.to_int_trunc !(outp.data)
;;

(* pulse [done_] one cycle to acknowledge the byte (clears [rdy]) *)
let ack sim (inp : _ I.t) =
  inp.done_ := hi;
  Cyclesim.cycle sim;
  inp.done_ := lo;
  Cyclesim.cycle sim
;;

let%expect_test "rs232r — recover a byte, then done clears rdy" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  let rdy, data = recv_frame sim inp outp ~fast:true ~data:0x4B in
  ack sim inp;
  let rdy_after = Bits.to_int_trunc !(outp.rdy) in
  Stdlib.Printf.printf
    "rdy=%d data=0x%X (sent 0x4B); after done rdy=%d\n"
    rdy
    data
    rdy_after;
  [%expect {| rdy=1 data=0x4B (sent 0x4B); after done rdy=0 |}]
;;

let%expect_test "rs232r — both baud rates recover the byte" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  let _, fast = recv_frame sim inp outp ~fast:true ~data:0xC3 in
  ack sim inp;
  let _, slow = recv_frame sim inp outp ~fast:false ~data:0x3C in
  Stdlib.Printf.printf "fast=0x%X  slow=0x%X\n" fast slow;
  [%expect {| fast=0xC3  slow=0x3C |}]
;;

let%expect_test "rs232r — every byte round-trips" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  for data = 0 to 255 do
    let rdy, got = recv_frame sim inp outp ~fast:true ~data in
    ack sim inp;
    if not (rdy = 1 && got = data)
    then Stdlib.Printf.printf "sent 0x%02X: rdy=%d data=0x%02X\n" data rdy got
  done;
  [%expect {| |}]
;;

(* Front-end onset: [rxd] falls (start bit), the synchronizer [q0]/[q1] follows a cycle
   later, [start_edge] = [q1 & ~q0] pulses, and [run] arms — the receiver locking onto a
   frame. (The mid-bit sample is ~limit/2 cycles later, past a tight window.) *)
let%expect_test "rs232r — start detect [waveform: rxd↓ → q0/q1 → start_edge → run]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  reset_idle sim inp;
  inp.fsel := hi;
  inp.rxd := lo;
  (* start bit: rxd falls *)
  for _ = 1 to 8 do
    Cyclesim.cycle sim
  done;
  Waveform.print
    ~start_cycle:0
    ~wave_width:3
    ~display_width:84
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "rxd"
        ; port_name_is ~wave_format:Wave_format.Bit "q0"
        ; port_name_is ~wave_format:Wave_format.Bit "q1"
        ; port_name_is ~wave_format:Wave_format.Bit "start_edge"
        ; port_name_is ~wave_format:Wave_format.Bit "run"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "tick"
        ]
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves─────────────────────────────────────────────────────────┐
    │rxd               ││────────────────┐                                             │
    │                  ││                └─────────────────────────────────────────────│
    │q0                ││        ┌───────────────┐                                     │
    │                  ││────────┘               └─────────────────────────────────────│
    │q1                ││                ┌───────────────┐                             │
    │                  ││────────────────┘               └─────────────────────────────│
    │start_edge        ││                        ┌───────┐                             │
    │                  ││────────────────────────┘       └─────────────────────────────│
    │run               ││                                ┌─────────────────────────────│
    │                  ││────────────────────────────────┘                             │
    │                  ││────────────────────────────────────────┬───────┬───────┬─────│
    │tick              ││ 0                                      │1      │2      │3    │
    │                  ││────────────────────────────────────────┴───────┴───────┴─────│
    └──────────────────┘└──────────────────────────────────────────────────────────────┘
    |}]
;;
