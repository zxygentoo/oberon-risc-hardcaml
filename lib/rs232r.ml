(* Public API and behaviour spec live in [rs232r.mli].

   Port of [RS232R.v]. The receiver's job, and its three ideas beyond the transmitter:

   - SYNCHRONIZER + edge detect. [rxd] is asynchronous to our clock, so a 2-FF chain
     [Q0]/[Q1] samples it before any logic looks at it (metastability hygiene); [Q1 & ~Q0]
     is a one-cycle pulse on [rxd]'s falling edge — the UART start bit — which arms the
     receiver ([run]).
   - SAMPLE AT MID-BIT. Once running, the baud divider [tick] counts a bit-window; the
     line is sampled not at the edge but at the window CENTRE ([midtick],
     [tick = limit/2]), the point furthest from both bit boundaries, so clock-vs-baud
     drift can't catch the wrong bit. Each sample shifts [Q1] into [shreg] from the top.
   - NINE windows, start bit discarded. [bitcnt] counts to 8 ([endbit]): the start bit
     (window 0) plus 8 data bits (windows 1..8). The start bit enters [shreg] first and is
     pushed off the 8-bit register by the 8 data samples, so [shreg] ends holding the byte
     LSbit-first ([data = shreg]).

   [run]/[stat] frame the receive: the start edge sets [run]; [endtick & endbit] clears it
   and sets [stat] ([rdy]); [done_] (or reset) clears [stat]. [fsel] picks the [limit]
   (clk/1302 = 19200 or clk/217 = 115200 at 25 MHz); [midtick] is [limit/2].

   [rst] is active-low and synchronous; per the RTL only [run] and [stat] carry a reset
   term (the datapath regs follow from [run]=0), so a plain clock-only [Reg_spec] like
   [Spi] / [Rs232t]. *)

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

let create ?(baud_slow = 1302) ?(baud_fast = 217) (i : _ I.t) : _ O.t =
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
  (* baud divider thresholds; [midtick] (window centre) = limit/2 =
     {1 'b0, limit[11:1]}
     . [baud_fast]/[baud_slow] default to RS232R.v's 25 MHz constants (115200 = clk/217,
     19200 = clk/1302); the board passes clock-scaled values so the wire stays at a
     standard rate (feat/fast-clock: 60 MHz ⇒ 521/3125), like {!Spi}'s [slow_div_log2]. *)
  let limit =
    mux2
      i.fsel
      (of_unsigned_int ~width:12 baud_fast)
      (of_unsigned_int ~width:12 baud_slow)
  in
  let endtick = (tick_v ==: limit) -- "endtick" in
  let midtick =
    (tick_v ==: concat_msb [ gnd; select limit ~high:11 ~low:1 ]) -- "midtick"
  in
  let endbit = bitcnt_v ==:. 8 in
  (* end of the 9th window (start + 8 data) = the frame is complete; bound by name so the
     mixed &:/|: uses below stay unambiguous (equal precedence, left-assoc) *)
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

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── The
   receiver is input-driven, so the testbench plays the sender: drive a UART frame on
   [rxd] at the baud timing and check the recovered [data] + the [rdy]/[done_] handshake.
   As with [Rs232t] a whole frame is too long for a frozen waveform (clk/217 per bit), so
   the living doc is a functional decode + qcheck round-trip, plus a tight waveform of the
   distinctive front end (synchronizer + start-edge → [run]). The exhaustive bit-for-bit
   fidelity check vs [RS232R.v] is the Verilator co-sim (layer 3). *)

let lo = Bits.of_unsigned_int ~width:1 0
let hi = Bits.of_unsigned_int ~width:1 1
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

let%expect_test "rs232r — random byte round-trips [qcheck]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:64
       ~name:"rs232r-roundtrip"
       (QCheck.int_bound 0xFF)
       (fun data ->
          let rdy, got = recv_frame sim inp outp ~fast:true ~data in
          ack sim inp;
          rdy = 1 && got = data));
  [%expect {| |}]
;;

(* Front-end onset: [rxd] falls (start bit), the synchronizer [q0]/[q1] follows a cycle
   later, [start_edge] = [q1 & ~q0] pulses, and [run] arms — the receiver locking onto a
   frame. (The mid-bit sample is ~limit/2 cycles later, past a tight window.) *)
let%expect_test "rs232r — start detect [waveform: rxd↓ → q0/q1 → start_edge → run]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
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
