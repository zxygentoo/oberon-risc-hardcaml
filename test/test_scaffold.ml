(* Phase 0 scaffold test.

   Not a hardware test — it confirms the project's plumbing works on the ox switch: the
   vendored [risc_core] oracle builds and is callable, and Hardcaml can build, simulate,
   and render waveforms with the v0.18 API. Real RISC5 modules and lockstep tests arrive
   from Phase 1. *)

open Hardcaml
module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform

(* 1. The oracle (vendored OCaml emulator) builds under ox and is callable. [Oracle] is
      the emulator's lib/ compiled into our project (see vendor/oracle). *)
let test_oracle () =
  let module R = Oracle.Risc in
  let cpu = R.make () in
  let st = R.cpu_state cpu in
  assert (Array.length st.R.r = 16);
  Printf.printf
    "oracle  : risc_core ok — reset pc=0x%X, %d regs, flags=0x%X\n"
    st.R.pc
    (Array.length st.R.r)
    st.R.flags
;;

(* 2. Hardcaml builds and simulates a combinational circuit. A throwaway left shifter in
   the v0.18 API (shifts take [~by]); the real LeftShifter port is a Phase 1 lesson. *)
module Shift_i = struct
  type 'a t =
    { x : 'a [@bits 32]
    ; sc : 'a [@bits 5]
    }
  [@@deriving hardcaml]
end

module Shift_o = struct
  type 'a t = { y : 'a [@bits 32] } [@@deriving hardcaml]
end

let left_shift (i : Signal.t Shift_i.t) : Signal.t Shift_o.t =
  { Shift_o.y = Signal.log_shift ~f:Signal.sll i.x ~by:i.sc }
;;

let test_hardcaml () =
  let module Sim = Cyclesim.With_interface (Shift_i) (Shift_o) in
  let sim = Sim.create left_shift in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.x := Bits.of_unsigned_int ~width:32 0xFF;
  inp.sc := Bits.of_unsigned_int ~width:5 4;
  Cyclesim.cycle sim;
  let got = Bits.to_int_trunc !(outp.y) in
  assert (got = 0xFF0);
  Printf.printf "hardcaml: cyclesim ok — 0xFF << 4 = 0x%X\n" got
;;

(* 3. Sequential logic + waveform rendering. A 4-bit counter (a register fed back through
   +1), simulated for a few clocks and dumped as an ASCII waveform via hardcaml_waveterm.
   Certifies the waveform path and shows the idiom we'll lean on heavily from Phase 1. *)
module Count_i = struct
  type 'a t =
    { clock : 'a
    ; clear : 'a
    }
  [@@deriving hardcaml]
end

module Count_o = struct
  type 'a t = { count : 'a [@bits 4] } [@@deriving hardcaml]
end

let counter (i : Signal.t Count_i.t) : Signal.t Count_o.t =
  let open Signal in
  let spec = Reg_spec.create ~clock:i.clock ~clear:i.clear () in
  { Count_o.count = reg_fb spec ~width:4 ~f:(fun d -> d +:. 1) }
;;

let test_waveform () =
  let module Sim = Cyclesim.With_interface (Count_i) (Count_o) in
  let sim = Sim.create counter in
  let waves, sim = Waveform.create sim in
  for _ = 1 to 8 do
    Cyclesim.cycle sim
  done;
  print_endline "waveterm: 4-bit counter —";
  Waveform.print ~wave_width:2 ~display_width:80 waves
;;

let () =
  test_oracle ();
  test_hardcaml ();
  test_waveform ();
  print_endline "phase-0 scaffold: all green"
;;
