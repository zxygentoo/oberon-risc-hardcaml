(* The contract is in [soc.mli]. *)

open! Base
open Hardcaml
open Signal
open Risc5

module I = struct
  type 'a t =
    { clock : 'a
    ; pclk : 'a [@bits 1]
    ; rst_n : 'a [@bits 1]
    ; miso : 'a [@bits 1]
    ; rxd : 'a [@bits 1]
    ; btn : 'a [@bits 4]
    ; sw : 'a [@bits 8]
    ; gpio_in : 'a [@bits 8]
    ; ps2c : 'a [@bits 1]
    ; ps2d : 'a [@bits 1]
    ; msclk : 'a [@bits 1]
    ; msdat : 'a [@bits 1]
    ; mem_dq_i : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { mosi : 'a [@bits 1]
    ; sclk : 'a [@bits 1]
    ; sd_cs : 'a [@bits 1]
    ; txd : 'a [@bits 1]
    ; leds : 'a [@bits 8]
    ; gpio_out : 'a [@bits 8]
    ; gpio_oe : 'a [@bits 8]
    ; hsync : 'a [@bits 1]
    ; vsync : 'a [@bits 1]
    ; rgb : 'a [@bits 6]
    ; msclk_oe : 'a [@bits 1]
    ; msdat_oe : 'a [@bits 1]
    ; mouse_dbg : 'a [@bits 28]
    ; mem_adr : 'a [@bits 23]
    ; mem_dq_o : 'a [@bits 16]
    ; mem_dq_t : 'a [@bits 1]
    ; ram_ce_n : 'a [@bits 1]
    ; ram_oe_n : 'a [@bits 1]
    ; ram_we_n : 'a [@bits 1]
    ; ram_ub_n : 'a [@bits 1]
    ; ram_lb_n : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

let create ~contents (c : Build_config.t) (i : _ I.t) : _ O.t =
  (* [halftone] without [fb_bram] would elaborate with no Halftone at all, and a
     measurement of that build would be of a machine without the module *)
  if c.halftone && not c.fb_bram
  then failwith "Soc: halftone requires fb_bram (the claim muxes the Framebuf shadow)";
  let spec = Reg_spec.create () ~clock:i.clock in
  (* the fetch and load buses are wires, closed after the core; so is [ms_tick], from the
     peripherals built after it *)
  let codebus = wire 32 in
  let inbus = wire 32 in
  let ms_tick = wire 1 in
  (* ── Video ── the framebuffer word arrives on an acknowledge, not on the request as
     with single-cycle RAM *)
  let viddata = wire 32 in
  let vid_ack = wire 1 in
  let vidpar = wire 1 in
  (* the display-mode status word read at MMIO slot 10; zero without Halftone *)
  let ht_status = wire 32 in
  let vid =
    Video.create
      ~viddata_valid:vid_ack
      ~viddata_par:vidpar
      { Video.I.clk = i.clock; pclk = i.pclk; inv = bit i.sw ~pos:7; viddata }
  in
  let vidreq = vid.req -- "vidreq" in
  let vidadr = vid.vidadr -- "vidadr" in
  (* ── Core ── [core_ce → core → cellram → core_ce] is not a combinational loop: [ce]
     gates the core's registers, not its combinational [adr] and [mem_pend]. *)
  let core_ce = wire 1 in
  (* ── Interrupt stretch ── RISC5.v captures its interrupt every clock, even when
     stalled. Here the capture registers are frozen with the core, so a one-clock tick
     arriving in a frozen cycle would vanish. The request is held across frozen cycles and
     dropped once an enabled cycle has sampled it: the line stays high from the tick to
     its delivery, and the core's edge detector sees one edge per tick. With [ce] always
     high the hold term is 0 and this is [irq = limit], as in the simulation SoC. (Oberon
     never enables interrupts; the test below counts the deliveries.) *)
  let irq_pend = Always.Variable.reg spec ~width:1 in
  let irq_pend_v = irq_pend.value -- "irq_pend" in
  Always.(compile [ irq_pend <-- (i.rst_n &: ~:core_ce &: (ms_tick |: irq_pend_v)) ]);
  let irq = (ms_tick |: irq_pend_v) -- "irq" in
  let core =
    Cpu.create
      ~ce:core_ce
      ~multipliers:c.multipliers
      { Cpu.I.clock = i.clock; rst_n = i.rst_n; irq; stall_x = gnd; inbus; codebus }
  in
  (* ── Address decode ── (same constants as soc.ml / RISC5Top) *)
  let core_adr = core.adr -- "core_adr" in
  let core_ben = core.ben -- "core_ben" in
  let rom_region =
    (select core_adr ~high:23 ~low:14 ==:. Cpu.start_adr lsr 12) -- "rom_region"
  in
  let ioenb = (select core_adr ~high:23 ~low:6 ==:. 0x3FFFF) -- "ioenb" in
  let iowadr = select core_adr ~high:5 ~low:2 in
  (* served on the FPGA in one cycle: a fetch from the ROM region, or any MMIO access. One
     cycle per MMIO access is what makes each write strobe fire once. *)
  let core_rd = core.rd -- "core_rd" in
  let core_wr = core.wr -- "core_wr" in
  let is_fetch = (core.mem_pend &: ~:core_rd &: ~:core_wr) -- "is_fetch" in
  let data_access = core_rd |: core_wr in
  let cpu_internal =
    (rom_region &: is_fetch |: (ioenb &: data_access)) -- "cpu_internal"
  in
  (* the one store transaction every shadow rides (the cache snoop, Framebuf, Halftone) —
     bound once so their write-coherence cannot drift apart *)
  let psram_store = core_wr &: ~:cpu_internal in
  (* On a cache hit [mem_pend] is withheld from Cellram, so [ce] is high this cycle and
     the word comes from the cache. [cache_hit] is driven further down, after Cellram,
     whose [ce] and [rdata] the cache needs; the loop is not combinational, the hit being
     a read of the cache's own array. *)
  let cache_hit = wire 1 in
  (* ── PSRAM controller / CPU+video arbiter ── *)
  let cellram =
    Cellram.create
      ~read_cycles:c.read_cycles
      ~write_cycles:c.write_cycles
      ~write_buffer:c.write_buffer
      ~wbuf_depth:c.wbuf_depth
      { Cellram.I.clock = i.clock
      ; mem_pend = core.mem_pend &: ~:cache_hit
      ; cpu_internal
      ; adr = core_adr
      ; wr = core.wr
      ; ben = core_ben
      ; wdata = core.outbus
      ; vidreq = (if c.fb_bram then gnd else vidreq)
      ; vidadr
      ; mem_dq_i = i.mem_dq_i
      }
  in
  assign core_ce (cellram.ce -- "core_ce");
  (* With [fb_bram] the video DMA is served from the framebuffer shadow, and Cellram's
     [vidreq] is tied low above. The shadow takes exactly the store the cache watches. *)
  let viddata_src, vid_ack_src, vidpar_src, ht_status_src =
    if c.fb_bram
    then (
      let fb =
        Framebuf.create
          { Framebuf.I.clock = i.clock
          ; adr = core_adr
          ; write = psram_store
          ; ben = core_ben
          ; wdata = core.outbus
          ; vidreq
          ; vidadr
          }
      in
      (* Halftone takes the same store. [claim], latched per request — the mode on, and
         the word inside the client's rect — selects which shadow answers; outside the
         rect, and whenever the control word has never been written, the mono path does. *)
      if c.halftone
      then (
        let ht =
          Halftone.create
            { Halftone.I.clock = i.clock
            ; adr = core_adr
            ; write = psram_store
            ; ben = core_ben
            ; wdata = core.outbus
            ; vidreq
            ; vidadr
            }
        in
        ( mux2 ht.claim ht.viddata fb.viddata
        , mux2 ht.claim ht.vid_ack fb.vid_ack
        , mux2 ht.claim ht.vidpar fb.vidpar
        , ht.status ))
      else fb.viddata, fb.vid_ack, fb.vidpar, zero 32)
    else cellram.viddata, cellram.vid_ack, cellram.vidpar, zero 32
  in
  assign viddata viddata_src;
  assign vid_ack vid_ack_src;
  assign vidpar vidpar_src;
  assign ht_status ht_status_src;
  (* the CPU's read word: from the cache on a hit, else Cellram's *)
  let mem_rdata =
    if c.icache
    then (
      let cacheable_read = core.mem_pend &: ~:(core.wr) &: ~:cpu_internal in
      let cacheable_read = cacheable_read -- "cache_read" in
      let cache =
        Cache.create
          ~lines_log2:c.lines_log2
          ~write_update:c.write_update
          { Cache.I.clock = i.clock
          ; adr = core_adr
          ; cacheable_read
          ; write = psram_store
          ; ben = core_ben
          ; ce = cellram.ce
          ; fill_data = cellram.rdata
          ; wdata = core.outbus
          }
      in
      assign cache_hit (cache.hit -- "cache_hit");
      mux2 cache_hit cache.rdata cellram.rdata)
    else (
      assign cache_hit gnd;
      cellram.rdata)
  in
  let prom = Rom.create ~contents { Rom.I.adr = select core_adr ~high:10 ~low:2 } in
  (* ── Peripherals ── never clock-gated. The Halftone status word is an extra read slot. *)
  let per =
    Peripherals.create
      ~clocks_per_ms:c.clocks_per_ms
      ~slow_div_log2:c.spi_slow_div_log2
      ~baud_slow:c.uart_baud_slow
      ~baud_fast:c.uart_baud_fast
      ~extra_read_slots:[ Halftone.status_slot, ht_status ]
      { Peripherals.I.clock = i.clock
      ; rst_n = i.rst_n
      ; wr = core_wr
      ; rd = core_rd
      ; ioenb
      ; iowadr
      ; outbus = core.outbus
      ; miso = i.miso
      ; rxd = i.rxd
      ; btn = i.btn
      ; sw = i.sw
      ; gpio_in = i.gpio_in
      ; ps2c = i.ps2c
      ; ps2d = i.ps2d
      ; msclk = i.msclk
      ; msdat = i.msdat
      }
  in
  assign ms_tick per.ms_tick;
  (* SD chip select = ~spiCtrl[0] (RISC5Top's SS[0]); active low *)
  let sd_cs = ~:(lsb per.spi_ctrl) in
  (* fetch: ROM in the top 16 KiB, else PSRAM; load: MMIO in the top 64 B, else PSRAM *)
  assign codebus (mux2 rom_region prom.data mem_rdata);
  assign inbus (mux2 ioenb per.io_data mem_rdata);
  { O.mosi = per.mosi
  ; sclk = per.sclk
  ; sd_cs
  ; txd = per.txd
  ; leds = per.leds
  ; gpio_out = per.gpio_out
  ; gpio_oe = per.gpio_oe
  ; hsync = vid.hsync
  ; vsync = vid.vsync
  ; rgb = vid.rgb
  ; msclk_oe = per.msclk_oe
  ; msdat_oe = per.msdat_oe
  ; mouse_dbg = per.mouse_out
  ; mem_adr = cellram.mem_adr
  ; mem_dq_o = cellram.mem_dq_o
  ; mem_dq_t = cellram.mem_dq_t
  ; ram_ce_n = cellram.ce_n
  ; ram_oe_n = cellram.oe_n
  ; ram_we_n = cellram.we_n
  ; ram_ub_n = cellram.ub_n
  ; ram_lb_n = cellram.lb_n
  }
;;

(* ── Tests ── Small programs in the ROM, as in lib/soc.ml, here with the chip model on
   the PSRAM pins: the memory round trip, the timer running through memory waits, the
   interrupt stretch, MMIO through the one-cycle path, and Halftone switched on. *)

module Sb_I = I

let sb_create = create

module For_tests = struct
  module Tb = struct
    (* the board SoC closed with the chip model. [leds] is for the MMIO test, [sclk] for
       the gates' SD card; [hsync], [vsync] and [rgb] keep the pixel path from being
       pruned (see soc.mli). *)
    module I = struct
      type 'a t =
        { clock : 'a
        ; pclk : 'a [@bits 1]
        ; rst_n : 'a [@bits 1]
        ; miso : 'a [@bits 1]
        ; rxd : 'a [@bits 1]
        ; btn : 'a [@bits 4]
        ; sw : 'a [@bits 8]
        ; gpio_in : 'a [@bits 8]
        ; ps2c : 'a [@bits 1]
        ; ps2d : 'a [@bits 1]
        ; msclk : 'a [@bits 1]
        ; msdat : 'a [@bits 1]
        }
      [@@deriving hardcaml]
    end

    module O = struct
      type 'a t =
        { leds : 'a [@bits 8]
        ; sclk : 'a [@bits 1]
        ; hsync : 'a [@bits 1]
        ; vsync : 'a [@bits 1]
        ; rgb : 'a [@bits 6]
        }
      [@@deriving hardcaml]
    end

    (* A small model by default: the tests here stay under byte 0x200. The boot gates pass
       19 bits, the whole 1 MiB.

       [datasheet_chip] holds the model to the -70 part's datasheet at [c]'s clock: 70 ns
       from address, CE# or byte enable to read data (tAA/tCO/tBA) and a 45 ns write pulse
       (tWP). The write-side access figure (tAW/tCW/tBW) is held to 62 ns, not the
       datasheet's 70: the shipped write phase provides 62.5 ns by decision (see
       {!Build_config.shipped}), and this keeps a shorter phase from slipping in
       unnoticed. *)
    let create
      ~contents
      ?(addr_bits = 12)
      ?(datasheet_chip = false)
      (c : Build_config.t)
      (i : _ I.t)
      : _ O.t
      =
      let dq = wire 16 in
      let soc =
        sb_create
          ~contents
          c
          { Sb_I.clock = i.clock
          ; pclk = i.pclk
          ; rst_n = i.rst_n
          ; miso = i.miso
          ; rxd = i.rxd
          ; btn = i.btn
          ; sw = i.sw
          ; gpio_in = i.gpio_in
          ; ps2c = i.ps2c
          ; ps2d = i.ps2d
          ; msclk = i.msclk
          ; msdat = i.msdat
          ; mem_dq_i = dq
          }
      in
      let chip_cycles ~ns =
        if datasheet_chip then Build_config.cycles_of_ns c ~ns else 1
      in
      let m =
        Cellram_model.create
          ~addr_bits
          ~read_access_cycles:(chip_cycles ~ns:70)
          ~write_access_cycles:(chip_cycles ~ns:62)
          ~write_pulse_cycles:(chip_cycles ~ns:45)
          { Cellram_model.I.clock = i.clock
          ; mem_adr = soc.mem_adr
          ; mem_dq_o = soc.mem_dq_o
          ; mem_dq_t = soc.mem_dq_t
          ; ce_n = soc.ram_ce_n
          ; oe_n = soc.ram_oe_n
          ; we_n = soc.ram_we_n
          ; ub_n = soc.ram_ub_n
          ; lb_n = soc.ram_lb_n
          }
      in
      assign dq m.mem_dq_i;
      { O.leds = soc.leds
      ; sclk = soc.sclk
      ; hsync = soc.hsync
      ; vsync = soc.vsync
      ; rgb = soc.rgb
      }
    ;;
  end

  (* the idle level of every input but [rst_n], which the test sequences. Holding [pclk]
     low does not stop the video DMA: in a one-domain simulation the raster advances with
     [clk] whatever this input does. *)
  let drive_idle (inp : _ Tb.I.t) =
    let lo = Bits.gnd
    and hi = Bits.vdd in
    inp.pclk := lo;
    inp.miso := hi;
    inp.rxd := hi;
    inp.ps2c := hi;
    inp.ps2d := hi;
    inp.msclk := hi;
    inp.msdat := hi;
    inp.btn := Bits.of_unsigned_int ~width:4 0;
    inp.sw := Bits.of_unsigned_int ~width:8 0;
    inp.gpio_in := Bits.of_unsigned_int ~width:8 0
  ;;
end

(* the co-located tests keep their short names *)
module Tb = For_tests.Tb

let drive_idle = For_tests.drive_idle

let%expect_test "board soc — fetch ROM, store + load round-trip through PSRAM" =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
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
     ; nop
     ; nop
     ; nop
     ; nop
    |]
  in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~contents:prog Build_config.bare)
  in
  let inp = Cyclesim.inputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  drive_idle inp;
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  (* PSRAM accesses are multi-cycle, so allow generously more than soc.ml's 20 *)
  for _ = 1 to 120 do
    Cyclesim.cycle sim
  done;
  let r k = Cyclesim.Memory.to_int regfile ~address:k in
  Stdlib.Printf.printf "R1=0x%X  R2=0x%X\n" (r 1) (r 2);
  [%expect {| R1=0x55  R2=0x55 |}]
;;

let%expect_test "board soc — ms timer counts clocks, not ce cycles (free-running under \
                 wait-states)"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  (* a tight loop of back-to-back PSRAM loads, so the core is frozen ([ce] low) most
     cycles. The free-running ms timer must still tick on the *clock* — a ce-gated timer
     would badly undercount. *)
  let prog =
    [| 0x41000100 (* MOV R1, #0x100 *)
     ; 0x82100000 (* LD R2, [R1] : PSRAM read (multi-cycle) *)
     ; 0xE7FFFFFE (* B -2 : loop back to the LD *)
    |]
  in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~contents:prog { Build_config.bare with clocks_per_ms = 50 })
  in
  let inp = Cyclesim.inputs sim in
  let cnt1 = Option.value_exn (Cyclesim.lookup_reg_by_name sim "cnt1") in
  let core_ce =
    match Cyclesim.lookup_node_or_reg_by_name sim "core_ce" with
    | Some n -> n
    | None -> failwith "board soc timer test: no traced node core_ce"
  in
  drive_idle inp;
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  let total = 1000 in
  let ce_high = ref 0 in
  for _ = 1 to total do
    Cyclesim.cycle sim;
    if Cyclesim.Node.to_int core_ce = 1 then Int.incr ce_high
  done;
  Stdlib.Printf.printf
    "after %d clocks @ 50 clk/ms: cnt1 = %d   (CPU advanced on only %d ce cycles — \
     wait-stated: %b)\n"
    total
    (Cyclesim.Reg.to_int cnt1)
    !ce_high
    (!ce_high < total);
  [%expect
    {| after 1000 clocks @ 50 clk/ms: cnt1 = 20   (CPU advanced on only 373 ce cycles — wait-stated: true) |}]
;;

let%expect_test "board soc — a ms tick landing in a frozen (ce=0) cycle still reaches \
                 the core [irq stretch]"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  (* The same loop, in which the core is frozen most of the time, so most ticks arrive in
     a frozen cycle. Every tick must still be delivered: [irq1], which follows [irq] on
     enabled cycles whether or not interrupts are enabled, must rise once per tick. *)
  let prog =
    [| 0x41000100 (* MOV R1, #0x100 *)
     ; 0x82100000 (* LD R2, [R1] : PSRAM read (multi-cycle) *)
     ; 0xE7FFFFFE (* B -2 : loop back to the LD *)
    |]
  in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~contents:prog { Build_config.bare with clocks_per_ms = 50 })
  in
  let inp = Cyclesim.inputs sim in
  let cnt1 = Option.value_exn (Cyclesim.lookup_reg_by_name sim "cnt1") in
  let irq1 = Option.value_exn (Cyclesim.lookup_reg_by_name sim "irq1") in
  drive_idle inp;
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  let rises = ref 0
  and prev = ref 0 in
  for _ = 1 to 2000 do
    Cyclesim.cycle sim;
    let now = Cyclesim.Reg.to_int irq1 in
    if now = 1 && !prev = 0 then Int.incr rises;
    prev := now
  done;
  let ticks = Cyclesim.Reg.to_int cnt1 in
  Stdlib.Printf.printf
    "after 2000 clocks @ 50 clk/ms: ticks (cnt1) = %d   delivered (irq1 rises) = %d   \
     every tick delivered (<=1 in flight): %b\n"
    ticks
    !rises
    (!rises >= ticks - 1);
  [%expect
    {| after 2000 clocks @ 50 clk/ms: ticks (cnt1) = 40   delivered (irq1 rises) = 40   every tick delivered (<=1 in flight): true |}]
;;

let%expect_test "board soc — ms timer free-runs across a mid-run reset (RESET-FINDINGS)" =
  (* The timer must run through a reset here too (see lib/soc.ml), under a core that is
     frozen part of the time. *)
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let nop = 0x40080000 in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create
         ~contents:(Array.create ~len:8 nop)
         { Build_config.bare with clocks_per_ms = 10 })
  in
  let inp = Cyclesim.inputs sim in
  let cnt1 = Option.value_exn (Cyclesim.lookup_reg_by_name sim "cnt1") in
  let rst v = inp.rst_n := Bits.of_unsigned_int ~width:1 v in
  let run n =
    for _ = 1 to n do
      Cyclesim.cycle sim
    done
  in
  drive_idle inp;
  rst 0;
  run 1;
  rst 1;
  run 55;
  let before = Cyclesim.Reg.to_int cnt1 in
  rst 0;
  run 27;
  let at_release = Cyclesim.Reg.to_int cnt1 in
  rst 1;
  run 29;
  let after = Cyclesim.Reg.to_int cnt1 in
  (* 10 clocks/ms ⇒ a tick every 10th clock regardless of rst_n; ticks land inside the
     asserted reset. cnt1 must be strictly non-decreasing across the whole sequence. *)
  Stdlib.Printf.printf
    "cnt1: before=%d at-release=%d after=%d   monotonic across reset: %b\n"
    before
    at_release
    after
    (at_release >= before && after >= at_release);
  [%expect {| cnt1: before=5 at-release=8 after=11   monotonic across reset: true |}]
;;

let%expect_test "board soc — MMIO word 1: read {btn, sw}; store latches the LEDs" =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let nop = 0x40080000 in
  let prog =
    [| 0x640000FF (* MOV' R4, #0xFF<<16 : R4 = 0xFF0000 *)
     ; 0x4446FFC4 (* IOR R4, R4, #0xFFC4 : R4 = 0xFFFFC4 (word 1) *)
     ; 0x82400000 (* LD R2, [R4] : R2 = {btn, sw} *)
     ; 0x430000AB (* MOV R3, #0xAB *)
     ; 0xA3400000 (* ST R3, [R4] : Lreg := 0xAB *)
     ; nop
     ; nop
     ; nop
     ; nop
     ; nop
     ; nop
     ; nop
    |]
  in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~contents:prog Build_config.bare)
  in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  drive_idle inp;
  inp.sw := Bits.of_unsigned_int ~width:8 0x0F;
  inp.btn := Bits.of_unsigned_int ~width:4 0x5;
  inp.rst_n := Bits.of_unsigned_int ~width:1 0;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.of_unsigned_int ~width:1 1;
  for _ = 1 to 120 do
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

(* The display mode switched ON, through the SoC: a boot stub uploads a 32-px-wide, 2-row
   rect (tone LUT, pixels, geometry, mode bit) over a known mono framebuffer, and the test
   reads what leaves the rgb pins. Inside the rect the composed Halftone word must scan
   out; beside and below it the mono framebuffer. That exercises what the unit tests and
   the mode-off golden cannot: the per-request claim mux between the two shadows, the
   store tap, and the status word's MMIO slot. *)
let%expect_test "board soc — Halftone on: the rect scans out composed pixels, the rest \
                 stays mono; status at MMIO slot 10"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  (* a minimal assembler for the stub *)
  let reg_imm ~u ~op a b imm =
    0x4000_0000 lor (u lsl 29) lor (a lsl 24) lor (b lsl 20) lor (op lsl 16) lor imm
  in
  let mov a imm = reg_imm ~u:0 ~op:0 a 0 imm (* R.a := imm *)
  and movh a imm = reg_imm ~u:1 ~op:0 a 0 imm (* R.a := imm << 16 *)
  and ior a b imm = reg_imm ~u:0 ~op:6 a b imm in
  let mem ~store ~byte a b off =
    0x8000_0000
    lor (Bool.to_int store lsl 29)
    lor (Bool.to_int byte lsl 28)
    lor (a lsl 24)
    lor (b lsl 20)
    lor (off land 0xF_FFFF)
  in
  let st = mem ~store:true ~byte:false
  and stb = mem ~store:true ~byte:true
  and ld = mem ~store:false ~byte:false in
  let ctl = Halftone.ctl_off in
  (* scanline 0, panel words 2 and 3 (x = 64..127): the framebuffer byte address *)
  let fb_adr = 4 * (Video.org + (1023 * 32) + 2) in
  let prog =
    Array.concat
      [ [| movh 1 (Halftone.base lsr 16) (* R1 = the pixel window *) |]
      ; (* 32 pixel bytes 1,0,1,0,… (little-endian words of 0x00010001) *)
        [| movh 2 1; ior 2 2 1 |]
      ; Array.init 8 ~f:(fun k -> st 2 1 (4 * k))
      ; (* tone: index 1 -> white; the threshold map and row map stay zero, so a pixel is
           lit iff its tone is above 0, and every rect row reads source row 0 *)
        [| mov 3 0xFF; stb 3 1 (Halftone.lut_off + 1) |]
      ; (* geometry: x = 64, y = 0, w = 32, h = 2, 1:1 scale *)
        [| mov 4 64; st 4 1 (ctl + 4) |]
      ; [| mov 4 0; st 4 1 (ctl + 8) |]
      ; [| mov 4 32; st 4 1 (ctl + 12) |]
      ; [| mov 4 2; st 4 1 (ctl + 16) |]
      ; [| mov 4 1; st 4 1 (ctl + 20); st 4 1 (ctl + 24); st 4 1 ctl (* mode on *) |]
      ; (* mono framebuffer under and beside the rect on scanline 0 *)
        [| movh 5 (fb_adr lsr 16); ior 5 5 (fb_adr land 0xFFFF) |]
      ; [| movh 6 0xF0F0; ior 6 6 0xF0F0; st 6 5 0; st 6 5 4 |]
      ; (* then poll the status word forever *)
        [| movh 8 0xFF; ior 8 8 (0xFFC0 + (4 * Halftone.status_slot)) |]
      ; [| ld 7 8 0; 0xE7FFFFFE (* B -2 *) |]
      ]
  in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create
         ~contents:prog
         { Build_config.bare with fb_bram = true; halftone = true })
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let reg name = Option.value_exn (Cyclesim.lookup_reg_by_name sim name) in
  let hcnt = reg "hcnt"
  and vcnt = reg "vcnt" in
  let regfile = Option.value_exn (Cyclesim.lookup_mem_by_name sim "regfile") in
  drive_idle inp;
  inp.rst_n := Bits.gnd;
  Cyclesim.cycle sim;
  inp.rst_n := Bits.vdd;
  (* run the stub (stores are multi-cycle PSRAM writes) *)
  for _ = 1 to 2_000 do
    Cyclesim.cycle sim
  done;
  (* The geometry is latched at vblank entry. Skip the raster to its last visible line
     rather than simulate a whole frame, then run through blanking into the next frame. *)
  Cyclesim.Reg.of_int vcnt 767;
  let lines = Array.create ~len:3 (0, 0) in
  let stop = ref false in
  while not !stop do
    Cyclesim.cycle sim;
    let v = Cyclesim.Reg.to_int vcnt
    and x = Cyclesim.Reg.to_int hcnt - 32 (* a pixel leaves rgb one group after hcnt *) in
    if v < 3 && x >= 64 && x < 128 && Bits.to_unsigned_int !(outp.rgb) <> 0
    then (
      let rect, beside = lines.(v) in
      lines.(v)
      <- (if x < 96
          then rect lor (1 lsl (x - 64)), beside
          else rect, beside lor (1 lsl (x - 96))));
    if v = 3 then stop := true
  done;
  Array.iteri lines ~f:(fun v (rect, beside) ->
    Stdlib.Printf.printf "scanline %d: x 64..95 = %08X   x 96..127 = %08X\n" v rect beside);
  let status = Cyclesim.Memory.to_int regfile ~address:7 in
  Stdlib.Printf.printf
    "status word read at MMIO slot %d: frame counter = %d\n"
    Halftone.status_slot
    ((status lsr 8) land 0xFF);
  [%expect
    {|
    scanline 0: x 64..95 = 55555555   x 96..127 = F0F0F0F0
    scanline 1: x 64..95 = 55555555   x 96..127 = 00000000
    scanline 2: x 64..95 = 00000000   x 96..127 = 00000000
    status word read at MMIO slot 10: frame counter = 1
    |}]
;;
