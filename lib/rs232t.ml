(* Public API and behaviour spec live in [rs232t.mli].

   Port of [RS232T.v]. The hardware idea: a baud-rate divider ([tick]) plus a 9-bit shift
   register ([shreg]) serialise one byte as a UART frame on [txd] — start bit, 8 data bits
   LSbit-first, stop bit — with the framing carried *implicitly* by the shift register
   rather than an explicit start/stop state machine.

   Loading [{data, 1'b0}] on [start] drops the start bit (0) into [shreg]'s LSB, and [txd]
   is always [shreg[0]]. Each elapsed bit-time ([endtick]) shifts right and feeds a 1 in
   at the top, so the stop bit and the idle-high line fall out for free. [bitcnt] counts
   the ten bit-times (start + 8 + stop, [endbit] at 9); [run]/[rdy] frame the transfer
   ([start] sets [run], [endtick & endbit] clears it, [rdy = ~run]).

   Two baud rates share the one datapath via the [tick] threshold: [fsel] picks 19200 baud
   (clk/1302) or 115200 (clk/217), at 25 MHz. Unlike [Spi] this is output-only (no
   sampling) and shifts LSbit-out (vs SPI's MSbit-out tap at bit 7).

   [rst] is active-low and synchronous — woven into each register's next-state as in the
   RTL, so a plain clock-only [Reg_spec] with no separate reset port (matches [Spi] /
   [risc5_core]). *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; start : 'a [@bits 1]
    ; fsel : 'a [@bits 1]
    ; data : 'a [@bits 8]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { rdy : 'a [@bits 1]
    ; txd : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

let create ?(baud_slow = 1302) ?(baud_fast = 217) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  let reset = ~:(i.rst_n) in
  let run = Always.Variable.reg spec ~width:1 in
  let tick = Always.Variable.reg spec ~width:12 in
  let bitcnt = Always.Variable.reg spec ~width:4 in
  let shreg = Always.Variable.reg spec ~width:9 in
  let run_v = run.value -- "run" in
  let tick_v = tick.value -- "tick" in
  let bitcnt_v = bitcnt.value -- "bitcnt" in
  let shreg_v = shreg.value -- "shreg" in
  (* combinational: end-of-bit / end-of-frame, line driver, ready *)
  (* [baud_fast]/[baud_slow] default to RS232T.v's 25 MHz constants (clk/217 = 115200,
     clk/1302 = 19200); the board passes clock-scaled values (feat/fast-clock: 60 MHz ⇒
     521/3125) so the wire stays at a standard rate. *)
  let endtick =
    mux2 i.fsel (tick_v ==:. baud_fast) (tick_v ==:. baud_slow) -- "endtick"
  in
  let endbit = bitcnt_v ==:. 9 in
  let rdy = ~:run_v in
  let txd = select shreg_v ~high:0 ~low:0 in
  (* {data, 1'b0} loads the start bit; {1'b1, shreg[8:1]} shifts a 1 in for stop/idle *)
  let load = concat_msb [ i.data; gnd ] in
  let shifted = concat_msb [ vdd; select shreg_v ~high:8 ~low:1 ] in
  Always.(
    compile
      [ run <-- mux2 (reset |: (endtick &: endbit)) gnd (mux2 i.start vdd run_v)
      ; tick <-- mux2 (run_v &: ~:endtick) (tick_v +:. 1) (zero 12)
      ; bitcnt
        <-- mux2
              (endtick &: ~:endbit)
              (bitcnt_v +:. 1)
              (mux2 (endtick &: endbit) (zero 4) bitcnt_v)
      ; shreg
        <-- mux2
              reset
              (of_unsigned_int ~width:9 1)
              (mux2 i.start load (mux2 endtick shifted shreg_v))
      ]);
  { O.rdy; txd }
;;

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── A frozen
   waveform can't show a whole frame (clk/217 per bit), so the functional doc is a decode
   — drive a byte, sample [txd] at each bit-centre like a UART receiver and recover the
   frame — plus a qcheck round-trip; a tight waveform (below) freezes one bit boundary
   instead. The exhaustive bit-for-bit fidelity check vs [RS232T.v] is the Verilator
   co-sim (layer 3). *)

let lo = Bits.of_unsigned_int ~width:1 0
let hi = Bits.of_unsigned_int ~width:1 1
let w8 v = Bits.of_unsigned_int ~width:8 v

let reset_idle sim (inp : _ I.t) =
  inp.rst_n := lo;
  inp.start := lo;
  inp.fsel := lo;
  inp.data := w8 0;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  Cyclesim.cycle sim
;;

(* Send one byte and sample [txd] at the centre of all 10 bit-times, like a receiver. One
   bit-time is [limit+1] clocks (fast: 217+1, slow: 1302+1). Leaves the TX idle (rdy=1).
   Returns the 10 sampled bits [|start; d0..d7; stop|] and the minimum [rdy] seen (0 while
   the frame is in flight). *)
let send_frame sim (inp : _ I.t) (outp : _ O.t) ~fast ~data =
  let period = if fast then 218 else 1303 in
  inp.fsel := if fast then hi else lo;
  inp.data := w8 data;
  inp.start := hi;
  Cyclesim.cycle sim;
  (* edge: run<=1, shreg<={data,0}; post-edge txd = start bit *)
  inp.start := lo;
  let adv n =
    for _ = 1 to n do
      Cyclesim.cycle sim
    done
  in
  let rdy () = Bits.to_int_trunc !(outp.rdy) in
  let frame = Array.create ~len:10 0 in
  let rdy_busy = ref 1 in
  adv (period / 2);
  (* into the centre of bit 0's window *)
  for k = 0 to 9 do
    frame.(k) <- Bits.to_int_trunc !(outp.txd);
    rdy_busy := Int.min !rdy_busy (rdy ());
    if k < 9 then adv period
  done;
  (* run out the stop bit so rdy returns high, leaving the TX idle for the next frame *)
  let guard = ref 0 in
  while rdy () = 0 && !guard < 2 * period do
    Cyclesim.cycle sim;
    Int.incr guard
  done;
  frame, !rdy_busy
;;

(* frame = [|start; d0..d7; stop|]; the byte is LSbit-first in frame.(1..8) *)
let decode_byte frame =
  let b = ref 0 in
  for j = 0 to 7 do
    b := !b lor (frame.(1 + j) lsl j)
  done;
  !b
;;

let%expect_test "rs232t — UART frame: start, 8 data LSB-first, stop + rdy handshake" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  let before = Bits.to_int_trunc !(outp.rdy) in
  let frame, busy = send_frame sim inp outp ~fast:true ~data:0xB5 in
  let after = Bits.to_int_trunc !(outp.rdy) in
  let dbits = String.concat (List.init 8 ~f:(fun j -> Int.to_string frame.(1 + j))) in
  Stdlib.Printf.printf "rdy: before=%d busy=%d after=%d\n" before busy after;
  Stdlib.Printf.printf
    "frame: start=%d data(LSB-first)=%s stop=%d\n"
    frame.(0)
    dbits
    frame.(9);
  Stdlib.Printf.printf "decoded = 0x%X (sent 0x%X)\n" (decode_byte frame) 0xB5;
  [%expect
    {|
    rdy: before=1 busy=0 after=1
    frame: start=0 data(LSB-first)=10101101 stop=1
    decoded = 0xB5 (sent 0xB5)
    |}]
;;

let%expect_test "rs232t — both baud rates decode (fsel selects the divider)" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  let ff, _ = send_frame sim inp outp ~fast:true ~data:0x4B in
  let sf, _ = send_frame sim inp outp ~fast:false ~data:0xB4 in
  Stdlib.Printf.printf
    "fast decode=0x%X  slow decode=0x%X\n"
    (decode_byte ff)
    (decode_byte sf);
  [%expect {| fast decode=0x4B  slow decode=0xB4 |}]
;;

let%expect_test "rs232t — random byte round-trips [qcheck]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_idle sim inp;
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:64
       ~name:"rs232t-roundtrip"
       (QCheck.int_bound 0xFF)
       (fun data ->
          let frame, _ = send_frame sim inp outp ~fast:true ~data in
          frame.(0) = 0 && frame.(9) = 1 && decode_byte frame = data));
  [%expect {| |}]
;;

(* A tight window around the first bit boundary: when [endtick] pulses, [shreg] shifts
   right (a 1 entering the top), [txd] advances start(0)→d0, and [bitcnt] increments — the
   cycle-accurate heart of the port. *)
let%expect_test "rs232t — bit boundary [waveform: endtick shifts shreg, txd start→d0]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  reset_idle sim inp;
  inp.fsel := hi;
  inp.data := w8 0xB5;
  inp.start := hi;
  Cyclesim.cycle sim;
  inp.start := lo;
  for _ = 1 to 235 do
    Cyclesim.cycle sim
  done;
  Waveform.print
    ~start_cycle:216
    ~wave_width:2
    ~display_width:84
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "endtick"
        ; port_name_is ~wave_format:Wave_format.Bit "txd"
        ; port_name_is ~wave_format:Wave_format.Binary "shreg"
        ; port_name_is ~wave_format:Wave_format.Hex "bitcnt"
        ; port_name_is ~wave_format:Wave_format.Bit "rdy"
        ]
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves─────────────────────────────────────────────────────────┐
    │endtick           ││                        ┌─────┐                               │
    │                  ││────────────────────────┘     └───────────────────────────────│
    │txd               ││                              ┌───────────────────────────────│
    │                  ││──────────────────────────────┘                               │
    │                  ││──────────────────────────────┬───────────────────────────────│
    │shreg             ││ 101101010                    │110110101                      │
    │                  ││──────────────────────────────┴───────────────────────────────│
    │                  ││──────────────────────────────┬───────────────────────────────│
    │bitcnt            ││ 0                            │1                              │
    │                  ││──────────────────────────────┴───────────────────────────────│
    │rdy               ││                                                              │
    │                  ││──────────────────────────────────────────────────────────────│
    └──────────────────┘└──────────────────────────────────────────────────────────────┘
    |}]
;;
