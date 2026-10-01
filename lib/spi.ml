(* A port of SPI.v; the contract is in [spi.mli].

   One shift register [shreg], a clock divider [tick] and a bit counter [bitcnt] serve
   both rates. Slow: [endtick] at the divider's maximum, [endbit] at bit 7, and [sclk] is
   the divider's top bit, a clean 50% clock. Fast: [endtick] at 2 (clk/3), [endbit] at bit
   31, and [sclk] is the [endtick] pulse. A bit advances on [endtick]; the transfer ends,
   and [rdy] returns, on [endtick & endbit].

   [mosi] is bit 7 of [shreg], and [miso] is shifted in on [endtick]. The shift is not a
   plain [shreg << 1]: four byte lanes shift in parallel and are chained, each lane's top
   bit feeding the next lane's bottom bit, so that a 32-bit word leaves least significant
   byte first while every byte leaves most significant bit first — the order the SD
   protocol wants. That permutation shows in [data_rx]'s bit order, so it is copied from
   the RTL bit for bit.

   Reset is synchronous and active low, part of each register's next-state logic as in the
   RTL. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; start : 'a [@bits 1]
    ; fast : 'a [@bits 1]
    ; data_tx : 'a [@bits 32]
    ; miso : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { data_rx : 'a [@bits 32]
    ; rdy : 'a [@bits 1]
    ; mosi : 'a [@bits 1]
    ; sclk : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

let create ?(slow_div_log2 = 6) (i : _ I.t) : _ O.t =
  (* [tick] must hold both the slow terminal 2^n - 1 and the fast terminal 2; below n = 2
     the fast one no longer fits *)
  if slow_div_log2 < 2
  then failwith "Spi: slow_div_log2 < 2 cannot hold the fast terminal (tick == 2)";
  let spec = Reg_spec.create () ~clock:i.clock in
  let reset = ~:(i.rst_n) in
  let tick = Always.Variable.reg spec ~width:slow_div_log2 in
  let bitcnt = Always.Variable.reg spec ~width:5 in
  let rdy = Always.Variable.reg spec ~width:1 in
  let shreg = Always.Variable.reg spec ~width:32 in
  let tick_v = tick.value -- "tick" in
  let bitcnt_v = bitcnt.value -- "bitcnt" in
  let rdy_v = rdy.value -- "rdy" in
  (* a qualified name: the UART's and the keyboard's shift registers are [shreg] too, and
     the boot harness looks this one up by name *)
  let shreg_v = shreg.value -- "spi_shreg" in
  let bit n = select shreg_v ~high:n ~low:n in
  (* combinational: end-of-bit / end-of-word, line drivers, received data *)
  let slow_endtick = tick_v ==:. (1 lsl slow_div_log2) - 1 in
  let endtick = mux2 i.fast (tick_v ==:. 2) slow_endtick in
  let endbit = mux2 i.fast (bitcnt_v ==:. 31) (bitcnt_v ==:. 7) in
  let idle = reset |: rdy_v in
  let mosi = mux2 idle vdd (bit 7) in
  (* slow [sclk] is the divider's top bit (50% duty at clk÷2^slow_div_log2); fast is the
     [endtick] pulse *)
  let slow_sclk = select tick_v ~high:(slow_div_log2 - 1) ~low:(slow_div_log2 - 1) in
  let sclk = mux2 idle gnd (mux2 i.fast endtick slow_sclk) in
  let data_rx = mux2 i.fast shreg_v (uresize (select shreg_v ~high:7 ~low:0) ~width:32) in
  (* the four chained byte-lanes: each [{lane[6:0], next-lane-MSB}]; lane 3 takes MISO,
     and lane 0's incoming bit is shreg[15] (fast) or MISO (slow) *)
  let lsb_in = mux2 i.fast (bit 15) i.miso in
  let shifted =
    concat_msb
      [ select shreg_v ~high:30 ~low:24
      ; i.miso
      ; select shreg_v ~high:22 ~low:16
      ; bit 31
      ; select shreg_v ~high:14 ~low:8
      ; bit 23
      ; select shreg_v ~high:6 ~low:0
      ; lsb_in
      ]
  in
  Always.(
    compile
      [ tick <-- mux2 (reset |: rdy_v |: endtick) (zero slow_div_log2) (tick_v +:. 1)
      ; rdy <-- mux2 (reset |: (endtick &: endbit)) vdd (mux2 i.start gnd rdy_v)
      ; bitcnt
        <-- mux2
              (reset |: i.start)
              (zero 5)
              (mux2 (endtick &: ~:endbit) (bitcnt_v +:. 1) bitcnt_v)
      ; shreg
        <-- mux2 reset (ones 32) (mux2 i.start i.data_tx (mux2 endtick shifted shreg_v))
      ]);
  { O.data_rx; rdy = rdy_v; mosi; sclk }
;;

(* ── Tests ── A loopback ([miso] driven from [mosi]) takes data through the whole shift
   and handshake in both modes, and a waveform shows the first bits of a fast transfer.
   Fidelity to SPI.v is the co-simulation's and the proof's job. *)

let lo = Bits.gnd
let hi = Bits.vdd

let reset_then_idle sim (inp : _ I.t) =
  inp.rst_n := lo;
  inp.start := lo;
  inp.fast := lo;
  inp.miso := hi;
  inp.data_tx := Bits.of_unsigned_int ~width:32 0;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  Cyclesim.cycle sim
;;

(* one transfer with MISO looped back from MOSI; returns (cycles-from-start-to-rdy,
   data_rx) *)
let loopback_transfer sim (inp : _ I.t) (outp : _ O.t) ~fast ~data =
  inp.fast := if fast then hi else lo;
  inp.data_tx := Bits.of_unsigned_int ~width:32 data;
  inp.start := hi;
  Cyclesim.cycle sim;
  inp.start := lo;
  let n = ref 0 in
  while Bits.to_unsigned_int !(outp.rdy) = 0 do
    inp.miso := !(outp.mosi);
    Cyclesim.cycle sim;
    Int.incr n
  done;
  !n, Bits.to_unsigned_int !(outp.data_rx)
;;

let%expect_test "spi — slow byte loopback: data round-trips, clk÷64 × 8 bits" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_then_idle sim inp;
  let cycles, rx = loopback_transfer sim inp outp ~fast:false ~data:0xA5 in
  Stdlib.Printf.printf "cycles=%d  data_rx=0x%X\n" cycles rx;
  [%expect {| cycles=512  data_rx=0xA5 |}]
;;

let%expect_test "spi — slow byte loopback at clk÷128 (a deeper divider): 8 bits, 2× the \
                 cycles"
  =
  (* a divider depth other than the default: the same data and handshake at 128 clocks to
     the bit instead of 64 *)
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create (create ~slow_div_log2:7) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_then_idle sim inp;
  let cycles, rx = loopback_transfer sim inp outp ~fast:false ~data:0xA5 in
  Stdlib.Printf.printf "cycles=%d  data_rx=0x%X\n" cycles rx;
  [%expect {| cycles=1024  data_rx=0xA5 |}]
;;

let%expect_test "spi — fast word loopback: data round-trips, clk÷3 × 32 bits" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  reset_then_idle sim inp;
  let cycles, rx = loopback_transfer sim inp outp ~fast:true ~data:0x12345678 in
  Stdlib.Printf.printf "cycles=%d  data_rx=0x%X\n" cycles rx;
  [%expect {| cycles=96  data_rx=0x12345678 |}]
;;

let%expect_test "spi — fast transfer, first bits [waveform: tick÷3, sclk pulse, mosi]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  reset_then_idle sim inp;
  inp.fast := hi;
  inp.data_tx := Bits.of_unsigned_int ~width:32 0xCC;
  inp.start := hi;
  Cyclesim.cycle sim;
  inp.start := lo;
  for _ = 1 to 11 do
    Cyclesim.cycle sim
  done;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "rdy"
        ; port_name_is ~wave_format:Wave_format.Bit "sclk"
        ; port_name_is ~wave_format:Wave_format.Bit "mosi"
        ]
    ~wave_width:2
    ~display_width:74
    waves;
  [%expect
    {|
    ┌Signals─────────┐┌Waves─────────────────────────────────────────────────┐
    │rdy             ││      ┌───────────┐                                   │
    │                ││──────┘           └───────────────────────────────────│
    │sclk            ││                              ┌─────┐           ┌─────│
    │                ││──────────────────────────────┘     └───────────┘     │
    │mosi            ││──────────────────────────────────────────────────────│
    │                ││                                                      │
    └────────────────┘└──────────────────────────────────────────────────────┘
    |}]
;;
