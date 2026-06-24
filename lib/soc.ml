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

let create ~contents (i : _ I.t) : _ O.t =
  let codebus = wire 32 in
  let inbus = wire 32 in
  let core =
    Risc5_core.create
      { Risc5_core.I.clock = i.clock
      ; rst_n = i.rst_n
      ; irq = gnd
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
  let io_data = zero 32 in
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
