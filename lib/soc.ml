(* Public API and behaviour spec live in [soc.mli].

   Implementation note. Wires the core to [Prom] + [Sram] with RISC5Top's decode. The
   core's [adr] / [codebus] / [inbus] form a loop broken by the core's registers: [adr] is
   combinational from registered state ([pc], the regfile, [ir]), the memories read
   combinationally, and [codebus]/[inbus] only reach [ir] on the next edge — no
   combinational cycle. So [codebus]/[inbus] are Hardcaml wires, assigned after the core
   is built. Stores go to RAM unconditionally, faithful to the SRAM (no [ioenb] gate). *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { adr : 'a [@bits 24]
    ; rd : 'a [@bits 1]
    ; wr : 'a [@bits 1]
    ; ben : 'a [@bits 1]
    ; outbus : 'a [@bits 32]
    ; codebus : 'a [@bits 32]
    ; inbus : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

let create ~contents ?(clocks_per_ms = 25000) (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* Millisecond timer — free-running (no reset), like RISC5Top's. A [clocks_per_ms]
     prescaler [cnt0] raises [limit] once per ms; [limit] both pulses the core's [irq] and
     ticks the ms counter [cnt1] (read at MMIO word 0). *)
  let cnt0 = Always.Variable.reg spec ~width:16 in
  let cnt1 = Always.Variable.reg spec ~width:32 in
  let limit = (cnt0.value ==:. clocks_per_ms - 1) -- "limit" in
  Always.(
    compile
      [ cnt0 <-- mux2 limit (zero 16) (cnt0.value +:. 1)
      ; cnt1 <-- cnt1.value +: uresize limit ~width:32
      ]);
  let cnt1_v = cnt1.value -- "cnt1" in
  (* Core + memory; the fetch/load feedback is broken by the core's pc/ir registers, so
     [codebus]/[inbus] are wires assigned below. *)
  let codebus = wire 32 in
  let inbus = wire 32 in
  let core =
    Risc5_core.create
      { Risc5_core.I.clock = i.clock
      ; rst_n = i.rst_n
      ; irq = limit
      ; stall_x = gnd
      ; inbus
      ; codebus
      }
  in
  let prom = Prom.create ~contents { Prom.I.adr = select core.adr ~high:10 ~low:2 } in
  let ram =
    Sram.create
      { Sram.I.clock = i.clock
      ; adr = select core.adr ~high:19 ~low:0
      ; wr = core.wr
      ; ben = core.ben
      ; wdata = core.outbus
      }
  in
  let rom_region = select core.adr ~high:23 ~low:14 ==:. 0x3FF in
  let ioenb = select core.adr ~high:23 ~low:6 ==:. 0x3FFFF in
  let iowadr = select core.adr ~high:5 ~low:2 in
  (* MMIO read mux: word 0 = ms counter [cnt1]; other words read 0 (peripherals are
     Phase 6) *)
  let io_data = mux2 (iowadr ==:. 0) cnt1_v (zero 32) in
  (* fetch: ROM in the top 16 KiB, else RAM; load: MMIO in the top 64 B, else RAM *)
  assign codebus (mux2 rom_region prom.data ram.rdata);
  assign inbus (mux2 ioenb io_data ram.rdata);
  { O.adr = core.adr
  ; rd = core.rd
  ; wr = core.wr
  ; ben = core.ben
  ; outbus = core.outbus
  ; codebus
  ; inbus
  }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Integration on the interpreter (no oracle): a hand-assembled boot stub at ROM[0]
   exercises fetch from ROM, a word store into RAM, and a load back — verified through the
   core's named register file (lookup works on the interpreter; on hardcaml_c we surface
   state as outputs, 5.2c). Reset jumps to StartAdr=0x3FF800 → byte 0xFFE000 → ROM word 0. *)

let%expect_test "soc — fetch ROM, store + load round-trip through RAM" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let nop = 0x40080000 (* ADD R0,R0,#0 *) in
  let prog =
    [| 0x41000055 (* MOV R1, #0x55 *)
     ; 0xA1000100 (* ST R1, [R0+0x100] *)
     ; 0x82000100 (* LD R2, [R0+0x100] *)
     ; nop
     ; nop
     ; nop
     ; nop
     ; nop
    |]
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (create ~contents:prog) in
  let inp = Cyclesim.inputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  for _ = 1 to 20 do
    Cyclesim.cycle sim
  done;
  let r k = Cyclesim.Memory.to_int regfile ~address:k in
  Stdlib.Printf.printf "R1=0x%X  R2=0x%X\n" (r 1) (r 2);
  [%expect {| R1=0x55  R2=0x55 |}]
;;

let%expect_test "soc — millisecond timer ticks cnt1 every clocks_per_ms cycles" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let nop = 0x40080000 in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (create ~contents:(Array.create ~len:8 nop))
  in
  let inp = Cyclesim.inputs sim in
  let cnt1 = Option.value_exn (Cyclesim.lookup_reg_by_name sim "cnt1") in
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  for _ = 1 to 60000 do
    Cyclesim.cycle sim
  done;
  (* default 25000 clocks/ms ⇒ ticks at 25000 and 50000; 60001 total cycles ⇒ cnt1 = 2 *)
  Stdlib.Printf.printf "cnt1 = %d\n" (Cyclesim.Reg.to_int cnt1);
  [%expect {| cnt1 = 2 |}]
;;

let%expect_test "soc — MMIO read mux: word 0 = ms counter, RAM elsewhere" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let nop = 0x40080000 in
  let prog =
    [| 0x43000055 (* MOV R3, #0x55 *)
     ; 0xA3000100 (* ST R3, [R0+0x100] : RAM[0x100] := 0x55 *)
     ; 0x82000100 (* LD R2, [R0+0x100] : R2 := RAM (RAM path) *)
     ; 0x640000FF (* MOV' R4, #0xFF<<16 : R4 := 0xFF0000 *)
     ; 0x4446FFC0 (* IOR R4, R4, #0xFFC0 : R4 := 0xFFFFC0 *)
     ; 0x81400000 (* LD R1, [R4] : R1 := MMIO word 0 = cnt1 (IO path) *)
     ; nop
     ; nop
     ; nop
     ; nop
    |]
  in
  (* small prescaler so cnt1 is non-zero by the IO load — proving R1 came from the timer *)
  let sim =
    Sim.create ~config:Cyclesim.Config.trace_all (create ~contents:prog ~clocks_per_ms:4)
  in
  let inp = Cyclesim.inputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  for _ = 1 to 20 do
    Cyclesim.cycle sim
  done;
  let r k = Cyclesim.Memory.to_int regfile ~address:k in
  Stdlib.Printf.printf "R2 (RAM load) = 0x%X   R1 (MMIO word 0 = cnt1) = %d\n" (r 2) (r 1);
  [%expect {| R2 (RAM load) = 0x55   R1 (MMIO word 0 = cnt1) = 2 |}]
;;
