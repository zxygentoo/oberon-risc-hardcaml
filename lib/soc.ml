(* Public API and behaviour spec live in [soc.mli].

   Implementation note. Wires the core to [Prom] + [Sram] with RISC5Top's decode. The
   core's [adr] / [codebus] / [inbus] form a loop broken by the core's registers: [adr] is
   combinational from registered state ([pc], the regfile, [ir]), the memories read
   combinationally, and [codebus]/[inbus] only reach [ir] on the next edge — no
   combinational cycle. So [codebus]/[inbus] are Hardcaml wires, assigned after the core
   is built. Stores go to RAM unconditionally, faithful to the SRAM (no [ioenb] gate). The
   {!Spi} master is wired per RISC5Top: a store to MMIO word 4 pulses [start]
   ([spiStart]); word 5 is the 4-bit [spiCtrl] (bit 2 = [fast]); reads of words 4/5 return
   [data_rx]/[rdy]. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; miso : 'a [@bits 1]
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
    ; mosi : 'a [@bits 1]
    ; sclk : 'a [@bits 1]
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
  (* SPI master (RISC5Top wiring): a store to word 4 pulses [start] ([spiStart]); word 5
     is the 4-bit control register ([fast] = bit 2, reset to 0). [miso] is the
     already-ANDed SD/net line, driven test-side by the disk model. *)
  let spi_ctrl = Always.Variable.reg spec ~width:4 in
  Always.(
    compile
      [ spi_ctrl
        <-- mux2
              ~:(i.rst_n)
              (zero 4)
              (mux2
                 (core.wr &: ioenb &: (iowadr ==:. 5))
                 (select core.outbus ~high:3 ~low:0)
                 spi_ctrl.value)
      ]);
  let spi =
    Spi.create
      { Spi.I.clock = i.clock
      ; rst_n = i.rst_n
      ; start = core.wr &: ioenb &: (iowadr ==:. 4)
      ; fast = select (spi_ctrl.value -- "spi_ctrl") ~high:2 ~low:2
      ; data_tx = core.outbus
      ; miso = i.miso
      }
  in
  (* MMIO read mux: word 0 = ms counter; word 4 = SPI data; word 5 =
     {31 'b0, spiRdy}
     ; word 1 (switches) and the rest read 0 — 0 selects disk boot, remaining peripherals
     are Phase 6 *)
  let io_data =
    mux2
      (iowadr ==:. 0)
      cnt1_v
      (mux2
         (iowadr ==:. 4)
         spi.data_rx
         (mux2 (iowadr ==:. 5) (uresize spi.rdy ~width:32) (zero 32)))
  in
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
  ; mosi = spi.mosi
  ; sclk = spi.sclk
  }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Integration on the interpreter (no oracle): a hand-assembled boot stub at ROM[0]
   exercises fetch from ROM, a word store into RAM, and a load back — verified through the
   core's named register file (lookup works on the interpreter — which is what the
   Phase-5.3 boot lockstep uses too). Reset jumps to StartAdr=0x3FF800 → byte 0xFFE000 →
   ROM word 0. *)

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

let%expect_test "soc — SPI slow byte transfer (loopback) via MMIO words 4/5" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  (* A boot-style SPI exchange: start a transfer (store to word 4), poll [rdy] (load word
     5 until non-zero), then read the received byte (load word 4). The SD card is modelled
     as a loopback (MISO echoes MOSI), so the received byte equals the transmitted 0xA5. *)
  let prog =
    [| 0x5100FFD0 (* MOV R1, #0xFFD0 ; R1 = -48 (SPI data) *)
     ; 0x5200FFD4 (* MOV R2, #0xFFD4 ; R2 = -44 (SPI ctrl/status) *)
     ; 0x400000A5 (* MOV R0, #0xA5 *)
     ; 0xA0100000 (* ST R0, [R1] ; start transfer, dataTx = 0xA5 (spiCtrl=0 => slow) *)
     ; 0x83200000 (* LD  R3, [R2]      ; R3 = {31'b0, rdy}; Z = (rdy == 0)   <-- poll *)
     ; 0xE1FFFFFE (* BEQ -2 ; while rdy == 0, loop *)
     ; 0x84100000 (* LD R4, [R1] ; R4 = SPI data_rx = 0xA5 (loopback) *)
     ; 0x40080000 (* nop *)
    |]
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (create ~contents:prog) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  inp.miso := Bits.of_unsigned_int ~width:1 1;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  (* slow byte = 8 bits × clk÷64 = 512 cycles, plus setup + the poll loop *)
  for _ = 1 to 800 do
    inp.miso := !(outp.mosi);
    Cyclesim.cycle sim
  done;
  let r k = Cyclesim.Memory.to_int regfile ~address:k in
  Stdlib.Printf.printf "R4 (SPI data_rx, loopback of 0xA5) = 0x%X\n" (r 4);
  [%expect {| R4 (SPI data_rx, loopback of 0xA5) = 0xA5 |}]
;;
