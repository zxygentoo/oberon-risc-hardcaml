(* Public API and behaviour spec live in [soc_board.mli].

   Implementation note. This is [Soc] (lib/soc.ml) with the memory layer swapped for the
   PSRAM controller {!Cellram} and the core run on its clock-enable. The peripheral / MMIO
   block (timer, SPI, UART, PS/2 kbd + mouse, GPIO, LEDs, switches, the io_data read mux)
   is a faithful copy of soc.ml — see there for the per-MMIO-word rationale; only the
   comments load-bearing for the board differences are repeated here. *)

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

let create
  ~contents
  ?(clocks_per_ms = 25000)
  ?(read_cycles = 3)
  ?(write_cycles = 3)
  (i : _ I.t)
  : _ O.t
  =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* ── Millisecond timer (free-running, like soc.ml / RISC5Top) ── peripherals run on the
     system clock, NOT ce-gated: a slow (wait-stated) CPU polling full-speed peripherals,
     exactly as on real hardware. *)
  let cnt0 = Always.Variable.reg spec ~width:16 in
  let cnt1 = Always.Variable.reg spec ~width:32 in
  let limit = (cnt0.value ==:. clocks_per_ms - 1) -- "limit" in
  Always.(
    compile
      [ cnt0 <-- mux2 limit (zero 16) (cnt0.value +:. 1)
      ; cnt1 <-- cnt1.value +: uresize limit ~width:32
      ]);
  let cnt1_v = cnt1.value -- "cnt1" in
  (* fetch/load feedback, broken by the core's pc/ir registers *)
  let codebus = wire 32 in
  let inbus = wire 32 in
  (* ── Video ── two clocks; the framebuffer word is supplied by the arbiter and latched
     on its [vid_ack] (the PSRAM read is multi-cycle, so not on [req] as the BRAM SoC
     does). *)
  let viddata = wire 32 in
  let vid_ack = wire 1 in
  let vid =
    Vid.create
      ~viddata_valid:vid_ack
      { Vid.I.clk = i.clock; pclk = i.pclk; inv = bit i.sw ~pos:7; viddata }
  in
  let vidreq = vid.req -- "vidreq" in
  let vidadr = vid.vidadr -- "vidadr" in
  (* ── Core ── on the arbiter's clock-enable; [stall_x] tied off (video is arbitrated in
     {!Cellram}, which freezes the core via [ce] instead). The
     [core_ce → core → cellram → core_ce] path is not combinational — [ce] gates only the
     core's registers, not its combinational [adr]/[mem_pend] — so [core_ce] is a forward
     wire. *)
  let core_ce = wire 1 in
  let core =
    Risc5_core.create
      ~ce:core_ce
      { Risc5_core.I.clock = i.clock
      ; rst_n = i.rst_n
      ; irq = limit
      ; stall_x = gnd
      ; inbus
      ; codebus
      }
  in
  (* ── Address decode ── (same constants as soc.ml / RISC5Top) *)
  let rom_region = (select core.adr ~high:23 ~low:14 ==:. 0x3FF) -- "rom_region" in
  let ioenb = (select core.adr ~high:23 ~low:6 ==:. 0x3FFFF) -- "ioenb" in
  let iowadr = select core.adr ~high:5 ~low:2 in
  (* on-chip fast path: a ROM-region fetch (codebus from PROM) or any MMIO load/store (top
     64 B). These take {!Cellram}'s 1-cycle path — never touching the PSRAM — which also
     keeps each MMIO access one CPU-cycle long, so the write strobes below pulse exactly
     once. *)
  let is_fetch = core.mem_pend &: ~:(core.rd) &: ~:(core.wr) in
  let data_access = core.rd |: core.wr in
  let cpu_internal =
    (rom_region &: is_fetch |: (ioenb &: data_access)) -- "cpu_internal"
  in
  (* ── PSRAM controller / CPU+video arbiter ── *)
  let cellram =
    Cellram.create
      ~read_cycles
      ~write_cycles
      { Cellram.I.clock = i.clock
      ; mem_pend = core.mem_pend
      ; cpu_internal
      ; adr = core.adr
      ; wr = core.wr
      ; ben = core.ben
      ; wdata = core.outbus
      ; vidreq
      ; vidadr
      ; mem_dq_i = i.mem_dq_i
      }
  in
  assign core_ce (cellram.ce -- "core_ce");
  assign viddata cellram.viddata;
  assign vid_ack cellram.vid_ack;
  let prom = Prom.create ~contents { Prom.I.adr = select core.adr ~high:10 ~low:2 } in
  (* ── SPI master (words 4/5) ── *)
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
  (* SD chip select = ~spiCtrl[0] (RISC5Top's SS[0]); active low *)
  let sd_cs = ~:(lsb spi_ctrl.value) in
  (* ── UART (words 2/3) ── *)
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
  (* ── PS/2 keyboard + mouse (words 6/7) ── the mouse's open-drain [msclk]/[msdat] split
     into resolved-line inputs + drive-low [*_oe] outputs (the board IOBUF does the
     wired-AND). Plain decode for M1 boot; the listen-only PIC override is an M3 concern. *)
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
  (* ── Switches/buttons (word 1 read) + LEDs (word 1 write) ── *)
  let switches = uresize (i.btn @: i.sw) ~width:32 in
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
  (* ── GPIO (words 8/9) ── *)
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
  (* ── MMIO read mux (RISC5Top's iowadr chain) ── *)
  let io_data =
    mux
      iowadr
      ([ cnt1_v
       ; switches
       ; uresize uart_rx.data ~width:32
       ; uresize (uart_tx.rdy @: uart_rx.rdy) ~width:32
       ; spi.data_rx
       ; uresize spi.rdy ~width:32
       ; uresize (kbd.rdy @: mouse_out) ~width:32
       ; uresize kbd.data ~width:32
       ; uresize i.gpio_in ~width:32
       ; uresize gpoc.value ~width:32
       ]
       @ List.init 6 ~f:(fun _ -> zero 32))
  in
  (* fetch: ROM in the top 16 KiB, else PSRAM; load: MMIO in the top 64 B, else PSRAM *)
  assign codebus (mux2 rom_region prom.data cellram.rdata);
  assign inbus (mux2 ioenb io_data cellram.rdata);
  { O.mosi = spi.mosi
  ; sclk = spi.sclk
  ; sd_cs
  ; txd = uart_tx.txd
  ; leds = lreg.value
  ; gpio_out = gpout.value
  ; gpio_oe = gpoc.value
  ; hsync = vid.hsync
  ; vsync = vid.vsync
  ; rgb = vid.rgb
  ; msclk_oe = mouse.msclk_oe
  ; msdat_oe = mouse.msdat_oe
  ; mouse_dbg = mouse_out
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
