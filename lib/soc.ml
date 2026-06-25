(* Public API and behaviour spec live in [soc.mli].

   Implementation note. Wires the core to [Prom] + [Sram] with RISC5Top's decode. The
   core's [adr] / [codebus] / [inbus] form a loop broken by the core's registers: [adr] is
   combinational from registered state ([pc], the regfile, [ir]), the memories read
   combinationally, and [codebus]/[inbus] only reach [ir] on the next edge — no
   combinational cycle. So [codebus]/[inbus] are Hardcaml wires, assigned after the core
   is built. Stores go to RAM unconditionally, faithful to the SRAM (no [ioenb] gate). The
   {!Spi} master is wired per RISC5Top: a store to MMIO word 4 pulses [start]
   ([spiStart]); word 5 is the 4-bit [spiCtrl] (bit 2 = [fast]); reads of words 4/5 return
   [data_rx]/[rdy]. Word 1 reads [{btn, sw}] and latches the LEDs ([lreg]) on a store; the
   read mux is an [iowadr]-indexed [mux] with one labelled slot per MMIO word. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; miso : 'a [@bits 1]
    ; rxd : 'a [@bits 1] (* RS-232 receive line; idles high *)
    ; btn : 'a [@bits 4] (* buttons (RISC5Top [btn]); read-only via word 1 *)
    ; sw : 'a
         [@bits 8] (* switches, logical/active-high (RISC5Top's [~nswi], de-inverted) *)
    ; gpio_in : 'a [@bits 8] (* resolved GPIO pad inputs (RISC5Top [gpin]) *)
    ; pclk : 'a
         [@bits 1] (* 65 MHz pixel clock for VID (DCM/MMCM; a Phase-7 board input) *)
    ; ps2c : 'a [@bits 1] (* PS/2 keyboard clock *)
    ; ps2d : 'a [@bits 1] (* PS/2 keyboard data *)
    ; msclk : 'a [@bits 1] (* PS/2 mouse clock — resolved open-drain line in *)
    ; msdat : 'a [@bits 1] (* PS/2 mouse data — resolved open-drain line in *)
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
    ; txd : 'a [@bits 1] (* RS-232 transmit line; idles high *)
    ; leds : 'a [@bits 8] (* RISC5Top [leds] = the [Lreg] latch *)
    ; gpio_out : 'a [@bits 8] (* GPIO drive value (RISC5Top [gpout]) *)
    ; gpio_oe : 'a [@bits 8] (* GPIO output-enable / direction (RISC5Top [gpoc]) *)
    ; hsync : 'a [@bits 1] (* VGA horizontal sync (active low) *)
    ; vsync : 'a [@bits 1] (* VGA vertical sync (active low) *)
    ; rgb : 'a [@bits 6] (* 1 bpp pixel replicated across the 6 RGB pins *)
    ; msclk_oe : 'a
         [@bits 1] (* mouse msclk open-drain: 1 = host pulls low (req-to-send) *)
    ; msdat_oe : 'a [@bits 1]
    (* mouse msdat open-drain: 1 = host pulls low (command bit) *)
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
  (* Video controller (RISC5Top's [VID]). Two clocks: the system [clk] and the
     DCM/MMCM-generated pixel clock [pclk] (a Phase-7 board-shim input). [inv] = switch 7
     (RISC5Top [~nswi[7]], here the de-inverted [sw[7]]). Its framebuffer-read data
     [viddata] is the shared SRAM read bus, assigned once [ram] exists below. *)
  let viddata = wire 32 in
  let vid =
    Vid.create { Vid.I.clk = i.clock; pclk = i.pclk; inv = bit i.sw ~pos:7; viddata }
  in
  let vidreq = vid.req -- "vidreq" in
  let vidadr = vid.vidadr -- "vidadr" in
  (* [vidreq] is the core's [stallX]: a one-cycle DMA hold every 32 px. While it is high
     the core freezes — and [RISC5.v] gates its [wr]/[rd]/[ben] off with [~stallX] (our
     core mirrors this), so no store can fire — and the single SRAM port is steered to the
     framebuffer word [vidadr] instead of the CPU's address. The classic single-port video
     cycle-steal. Because [wr ⇒ ~vidreq], the unconditional RAM write can never land at
     [vidadr]. *)
  let core =
    Risc5_core.create
      { Risc5_core.I.clock = i.clock
      ; rst_n = i.rst_n
      ; irq = limit
      ; stall_x = vidreq
      ; inbus
      ; codebus
      }
  in
  let prom = Prom.create ~contents { Prom.I.adr = select core.adr ~high:10 ~low:2 } in
  (* SRAM address arbitration ([SRadr = vidreq ? vidadr : adr[19:2]]). [vidadr] is an
     18-bit word address; our [Sram] takes a 20-bit byte address, so shift in two zero
     bits. *)
  let sram_adr =
    mux2 vidreq (vidadr @: zero 2) (select core.adr ~high:19 ~low:0) -- "sram_adr"
  in
  let ram =
    Sram.create
      { Sram.I.clock = i.clock
      ; adr = sram_adr
      ; wr = core.wr
      ; ben = core.ben
      ; wdata = core.outbus
      }
  in
  assign viddata ram.rdata;
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
  (* UART (words 2/3): RS232R receiver + RS232T transmitter at [bitrate] baud. Word 2 read
     returns the received byte [dataRx] and pulses [done_] (acks it, clearing rdyRx); word
     2 write starts a transmit ([start], [data] = outbus[7:0]). Word 3 read =
     [{rdyTx, rdyRx}]; word 3 write sets the 1-bit [bitrate] select (0 = 19200, 1 =
     115200; reset 0). *)
  let bitrate = Always.Variable.reg spec ~width:1 in
  Always.(
    compile
      [ bitrate
        <-- mux2
              ~:(i.rst_n)
              gnd
              (mux2 (core.wr &: ioenb &: (iowadr ==:. 3)) (lsb core.outbus) bitrate.value)
      ]);
  let uart_rx =
    Rs232r.create
      { Rs232r.I.clock = i.clock
      ; rst_n = i.rst_n
      ; rxd = i.rxd
      ; fsel = bitrate.value
      ; done_ = core.rd &: ioenb &: (iowadr ==:. 2)
      }
  in
  let uart_tx =
    Rs232t.create
      { Rs232t.I.clock = i.clock
      ; rst_n = i.rst_n
      ; start = core.wr &: ioenb &: (iowadr ==:. 2)
      ; fsel = bitrate.value
      ; data = select core.outbus ~high:7 ~low:0
      }
  in
  (* PS/2 keyboard ({!Ps2}) + mouse ({!Mouse}), words 6/7. Word 6 read carries the mouse
     state [dataMs] in bits [27:0] and the keyboard-ready bit [rdyKbd] at bit 28; word 7
     read returns the keyboard byte [dataKbd] and pulses [doneKbd] (pops the keyboard
     FIFO). The mouse's open-drain [msclk]/[msdat] split into resolved-line inputs and
     drive-low [*_oe] outputs (the Phase-7 pad / a testbench does the wired-AND). *)
  let kbd =
    Ps2.create
      { Ps2.I.clock = i.clock
      ; rst_n = i.rst_n
      ; done_ = core.rd &: ioenb &: (iowadr ==:. 7)
      ; ps2c = i.ps2c
      ; ps2d = i.ps2d
      }
  in
  let mouse =
    Mouse.create
      { Mouse.I.clock = i.clock; rst_n = i.rst_n; msclk = i.msclk; msdat = i.msdat }
  in
  let mouse_out = mouse.out -- "mouse_out" in
  (* Switches/buttons (word 1 read): [{btn, sw}] zero-extended to 32 bits. RISC5Top reads
     [~nswi] — the OberonStation switches are active-low (board pullups); we take the
     already-logical [sw] (Nexys switches are active-high) and leave that pad inversion to
     the Phase-7 shim. Default 0 = all-off = the oracle's [switches], so disk boot is
     unaffected. *)
  let switches = uresize (i.btn @: i.sw) ~width:32 in
  (* LEDs (word 1 write): [Lreg] — cleared by reset, else loaded from [outbus[7:0]] on a
     store to word 1 (same shape as [spi_ctrl]); driven out on [leds]. *)
  let lreg = Always.Variable.reg spec ~width:8 in
  Always.(
    compile
      [ lreg
        <-- mux2
              ~:(i.rst_n)
              (zero 8)
              (mux2
                 (core.wr &: ioenb &: (iowadr ==:. 1))
                 (select core.outbus ~high:7 ~low:0)
                 lreg.value)
      ]);
  (* GPIO (words 8/9): [gpout] (drive value, word 8) and [gpoc] (direction, word 9), each
     8-bit. [gpoc] is reset-cleared; [gpout] is NOT (faithful — a pin powers up as input,
     drive value undefined). The bidirectional pad is split mouse-style: [gpio_in] in,
     [gpio_out] = [gpout] and [gpio_oe] = [gpoc] out; the Phase-7 shim rebuilds the IOBUFs
     ([.T(~oe)]). *)
  let gpout = Always.Variable.reg spec ~width:8 in
  Always.(
    compile
      [ gpout
        <-- mux2
              (core.wr &: ioenb &: (iowadr ==:. 8))
              (select core.outbus ~high:7 ~low:0)
              gpout.value
      ]);
  let gpoc = Always.Variable.reg spec ~width:8 in
  Always.(
    compile
      [ gpoc
        <-- mux2
              ~:(i.rst_n)
              (zero 8)
              (mux2
                 (core.wr &: ioenb &: (iowadr ==:. 9))
                 (select core.outbus ~high:7 ~low:0)
                 gpoc.value)
      ]);
  (* MMIO read mux, indexed by the word address [iowadr] (RISC5Top's [iowadr ==] chain).
     Slots fill in as their peripherals land; unmapped words read 0, like the RTL's [: 0]. *)
  let io_data =
    mux
      iowadr
      ([ cnt1_v (* 0 ms counter *)
       ; switches (* 1  {btn, switches} *)
       ; uresize uart_rx.data ~width:32 (* 2 RS-232 data (dataRx) *)
       ; uresize
           (uart_tx.rdy @: uart_rx.rdy)
           ~width:32 (* 3 RS-232 status {rdyTx,rdyRx} *)
       ; spi.data_rx (* 4 SPI data *)
       ; uresize spi.rdy ~width:32 (* 5 SPI status *)
       ; uresize (kbd.rdy @: mouse_out) ~width:32 (* 6 {rdyKbd, dataMs} *)
       ; uresize kbd.data ~width:32 (* 7 keyboard data (dataKbd) *)
       ; uresize i.gpio_in ~width:32 (* 8 gpio data (gpin) *)
       ; uresize gpoc.value ~width:32 (* 9 gpio tristate (gpoc) *)
       ]
       @ List.init 6 ~f:(fun _ -> zero 32) (* 10..15 unmapped *))
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
  ; txd = uart_tx.txd
  ; leds = lreg.value
  ; gpio_out = gpout.value
  ; gpio_oe = gpoc.value
  ; hsync = vid.hsync
  ; vsync = vid.vsync
  ; rgb = vid.rgb
  ; msclk_oe = mouse.msclk_oe
  ; msdat_oe = mouse.msdat_oe
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

let%expect_test "soc — word 1: read {btn, sw}; store latches the LEDs" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let nop = 0x40080000 in
  let prog =
    [| 0x640000FF (* MOV' R4, #0xFF<<16 R4 = 0xFF0000 *)
     ; 0x4446FFC4 (* IOR R4, R4, #0xFFC4 R4 = 0xFFFFC4 (word 1) *)
     ; 0x82400000 (* LD   R2, [R4]          R2 = {btn, sw} *)
     ; 0x430000AB (* MOV R3, #0xAB *)
     ; 0xA3400000 (* ST R3, [R4] Lreg := 0xAB *)
     ; nop
     ; nop
     ; nop
    |]
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (create ~contents:prog) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  inp.sw := Bits.of_unsigned_int ~width:8 0x0F;
  inp.btn := Bits.of_unsigned_int ~width:4 0x5;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  for _ = 1 to 20 do
    Cyclesim.cycle sim
  done;
  let r k = Cyclesim.Memory.to_int regfile ~address:k in
  (* {btn=5, sw=0x0F} = (5<<8) | 0x0F = 0x50F; the store latched 0xAB onto the LEDs *)
  Stdlib.Printf.printf
    "R2 (switches {btn,sw}) = 0x%X   leds = 0x%X\n"
    (r 2)
    (Bits.to_unsigned_int !(outp.leds));
  [%expect {| R2 (switches {btn,sw}) = 0x50F   leds = 0xAB |}]
;;

let%expect_test "soc — GPIO words 8/9: gpout/gpoc registers + gpin readback" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let nop = 0x40080000 in
  let prog =
    [| 0x640000FF (* MOV' R4, #0xFF<<16 R4 = 0xFF0000 *)
     ; 0x4546FFE4 (* IOR R5, R4, #0xFFE4 R5 = 0xFFFFE4 (word 9) *)
     ; 0x4446FFE0 (* IOR R4, R4, #0xFFE0 R4 = 0xFFFFE0 (word 8) *)
     ; 0x410000FF (* MOV R1, #0xFF *)
     ; 0xA1500000 (* ST R1, [R5] gpoc := 0xFF (all drive) *)
     ; 0x4200003C (* MOV R2, #0x3C *)
     ; 0xA2400000 (* ST R2, [R4] gpout := 0x3C *)
     ; 0x83400000 (* LD R3, [R4] R3 = gpin, the pin input (word 8 read) *)
     ; 0x86500000 (* LD R6, [R5] R6 = gpoc readback (word 9 read) *)
     ; nop
     ; nop
     ; nop
    |]
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (create ~contents:prog) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  (* the pin input is independent of what we drive — word-8 read returns it verbatim *)
  inp.gpio_in := Bits.of_unsigned_int ~width:8 0x5A;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  for _ = 1 to 24 do
    Cyclesim.cycle sim
  done;
  let r k = Cyclesim.Memory.to_int regfile ~address:k in
  Stdlib.Printf.printf
    "gpio_out=0x%X gpio_oe=0x%X   R3(gpin read)=0x%X R6(gpoc read)=0x%X\n"
    (Bits.to_unsigned_int !(outp.gpio_out))
    (Bits.to_unsigned_int !(outp.gpio_oe))
    (r 3)
    (r 6);
  [%expect {| gpio_out=0x3C gpio_oe=0xFF   R3(gpin read)=0x5A R6(gpoc read)=0xFF |}]
;;

let%expect_test "soc — video DMA: vidreq steals a core cycle and steers the SRAM" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let nop = 0x40080000 in
  (* A long run of nops: each is a 1-cycle instruction with no stall of its own, so [pc]
     simply counts retired instructions — the only thing that can freeze it is the video
     [stall_x]. (Default trace_all = All_one_domain, so the [pclk] raster advances 1:1
     with [clk] here; the true 13:5 ratio is a By_input_clocks concern for a raster-timing
     test.) *)
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (create ~contents:(Array.create ~len:400 nop))
  in
  let inp = Cyclesim.inputs sim in
  let node name =
    match Cyclesim.lookup_node_or_reg_by_name sim name with
    | Some n -> n
    | None -> failwith ("soc video test: no traced node " ^ name)
  in
  let pc = Option.value_exn (Cyclesim.lookup_reg_by_name sim "pc") in
  let vidreq = node "vidreq"
  and sram_adr = node "sram_adr"
  and vidadr = node "vidadr" in
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  (* fill the pipeline so [pc] is moving, then measure a clean window *)
  for _ = 1 to 4 do
    Cyclesim.cycle sim
  done;
  let pc0 = Cyclesim.Reg.to_int pc in
  let n = 200 in
  let stalls = ref 0
  and addr_ok = ref true in
  for _ = 1 to n do
    Cyclesim.cycle sim;
    if Cyclesim.Node.to_int vidreq = 1
    then (
      Int.incr stalls;
      (* on a steal cycle the shared port carries the framebuffer word [vidadr << 2] *)
      if Cyclesim.Node.to_int sram_adr <> Cyclesim.Node.to_int vidadr * 4
      then addr_ok := false)
  done;
  let pc1 = Cyclesim.Reg.to_int pc in
  Stdlib.Printf.printf
    "over %d cycles: vidreq pulses=%d (>0 %b)\n\
     pc advanced=%d; advanced+stalls=%d (≈ cycles)\n\
     SRAM steered to vidadr<<2 on every steal: %b\n"
    n
    !stalls
    (!stalls > 0)
    (pc1 - pc0)
    (pc1 - pc0 + !stalls)
    !addr_ok;
  [%expect
    {|
    over 200 cycles: vidreq pulses=6 (>0 true)
    pc advanced=194; advanced+stalls=200 (≈ cycles)
    SRAM steered to vidadr<<2 on every steal: true
    |}]
;;

let%expect_test "soc — UART loopback through MMIO words 2/3" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let nop = 0x40080000 in
  (* Set [bitrate]=1 (115200, clk/217) for a short frame, transmit 0x5A from word 2, poll
     rdyRx (word 3 bit 0) until set, then read the byte back from word 2. The line is
     looped back ([rxd] := [txd]) test-side, so the received byte equals the transmitted
     0x5A — end-to-end proof of the TX → line → RX → MMIO path plus the [bitrate] /
     [doneRx] wiring. *)
  let prog =
    [| 0x610000FF (* MOV' R1, #0xFF<<16 R1 = 0xFF0000 *)
     ; 0x4216FFC8 (* IOR R2, R1, #0xFFC8 R2 = 0xFFFFC8 (word 2, UART data) *)
     ; 0x4316FFCC (* IOR R3, R1, #0xFFCC R3 = 0xFFFFCC (word 3, UART status/ctrl) *)
     ; 0x44000001 (* MOV R4, #1 *)
     ; 0xA4300000 (* ST R4, [R3] bitrate := 1 (115200) *)
     ; 0x4500005A (* MOV R5, #0x5A *)
     ; 0xA5200000 (* ST R5, [R2] startTx, dataTx = 0x5A *)
     ; 0x86300000 (* LD   R6, [R3]          R6 = {rdyTx, rdyRx}        <- poll *)
     ; 0x47640001 (* AND R7, R6, #1 R7 = rdyRx; Z = (rdyRx==0) *)
     ; 0xE1FFFFFD (* BEQ -3 while rdyRx==0, back to the LD *)
     ; 0x80200000 (* LD R0, [R2] R0 = dataRx (pulses doneRx) *)
     ; nop
    |]
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (create ~contents:prog) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  inp.rst_n := lo;
  inp.rxd := hi (* idle high *);
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  (* ~10 bit-times × 217 cycles + setup/poll; loop the serial line back each cycle *)
  for _ = 1 to 5000 do
    inp.rxd := !(outp.txd);
    Cyclesim.cycle sim
  done;
  Stdlib.Printf.printf
    "R0 (UART data_rx, loopback of 0x5A) = 0x%X\n"
    (Cyclesim.Memory.to_int regfile ~address:0);
  [%expect {| R0 (UART data_rx, loopback of 0x5A) = 0x5A |}]
;;

let%expect_test "soc — PS/2 keyboard: a scancode frame surfaces at words 6/7" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let nop = 0x40080000 in
  (* Poll word 6 bit 28 (rdyKbd) — [LSL #3] lifts it to the sign bit, [BPL] loops while
     clear — then read the byte from word 7. The word-6 value captured at exit doubles as
     a structural check: rdyKbd at bit 28, mouse state (idle = 0) in [27:0], top 3 bits
     zero. (The mouse's own outputs/accumulation are covered by mouse.ml + its cosim.) *)
  let prog =
    [| 0x610000FF (* MOV' R1, #0xFF<<16 R1 = 0xFF0000 *)
     ; 0x4216FFD8 (* IOR R2, R1, #0xFFD8 R2 = 0xFFFFD8 (word 6) *)
     ; 0x4316FFDC (* IOR R3, R1, #0xFFDC R3 = 0xFFFFDC (word 7) *)
     ; 0x84200000 (* LD   R4, [R2]          R4 = {rdyKbd, dataMs}    <- poll *)
     ; 0x45410003 (* LSL R5, R4, #3 bit 28 -> bit 31; N = rdyKbd *)
     ; 0xE8FFFFFD (* BPL -3 while rdyKbd==0, back to the LD *)
     ; 0x80300000 (* LD R0, [R3] R0 = keyboard byte (pops the FIFO) *)
     ; nop
    |]
  in
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (create ~contents:prog) in
  let inp = Cyclesim.inputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  (* Drive a device->host PS/2 frame: start(0), 8 data LSbit-first, odd parity, stop(1).
     [ps2c] idles high; the module samples [ps2d] on each ps2c falling edge (2-FF
     synchronized), so hold each level a few clk cycles. The CPU runs throughout. *)
  let feed_bit b =
    inp.ps2d := b1 b;
    inp.ps2c := b1 1;
    for _ = 1 to 4 do
      Cyclesim.cycle sim
    done;
    inp.ps2c := b1 0;
    for _ = 1 to 4 do
      Cyclesim.cycle sim
    done
  in
  let feed_byte byte =
    let ones = ref 0 in
    feed_bit 0;
    for k = 0 to 7 do
      let d = (byte lsr k) land 1 in
      ones := !ones + d;
      feed_bit d
    done;
    feed_bit ((!ones + 1) land 1) (* odd parity *);
    feed_bit 1 (* stop *)
  in
  inp.rst_n := b1 0;
  inp.ps2c := b1 1;
  inp.ps2d := b1 1;
  inp.msclk := b1 1;
  inp.msdat := b1 1 (* mouse idle: open-drain lines released *);
  Cyclesim.cycle sim;
  inp.rst_n := b1 1;
  feed_byte 0x1C;
  for _ = 1 to 60 do
    Cyclesim.cycle sim
  done;
  let r k = Cyclesim.Memory.to_int regfile ~address:k in
  Stdlib.Printf.printf
    "word6 @rdyKbd = 0x%X (rdyKbd=bit28, mouse=0)   R0 (word7 scancode) = 0x%X\n"
    (r 4)
    (r 0);
  [%expect
    {| word6 @rdyKbd = 0x10000000 (rdyKbd=bit28, mouse=0)   R0 (word7 scancode) = 0x1C |}]
;;
