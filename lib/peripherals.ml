(* Public API and behaviour spec live in [peripherals.mli].

   Implementation note. The RISC5Top peripheral/MMIO cluster, extracted from the sim SoC
   (lib/soc.ml) so the board SoC instantiates the same faithful block instead of keeping a
   hand-copy (the copies drifted as diffs buried in copied text; the board's deltas are
   now the explicit seams on [create]). The block consumes the *decoded* bus — each SoC
   keeps its own address decode and passes the strobes + the MMIO window/word — and drives
   the pad-side lines directly. The board-only concerns stay outside on purpose: [sd_cs]
   derives from the exported [spi_ctrl], and the ce-domain IRQ stretch wraps the exported
   [ms_tick] (this block itself is never ce-gated — a wait-stated CPU polls full-speed
   peripherals, exactly as on real hardware). *)

open! Base
open Hardcaml
open Signal

(* The MMIO word map (RISC5Top's [iowadr] decode). One name per word, shared by the write
   strobes, the writable registers and the read-mux slot below, so a word can't drift
   between its decode site and its read slot. *)
let w_ms_timer = 0 (* R: ms counter *)
let w_switches_leds = 1 (* R: {btn, sw}; W: the LED latch *)
let w_uart_data = 2 (* R: dataRx (pulses doneRx); W: start a transmit *)
let w_uart_status = 3 (* R: {rdyTx, rdyRx}; W: the bitrate select *)
let w_spi_data = 4 (* R: data_rx; W: start a transfer *)
let w_spi_ctrl = 5 (* R: rdy; W: the 4-bit spiCtrl *)
let w_mouse_kbd = 6 (* R: {rdyKbd, dataMs} *)
let w_kbd_data = 7 (* R: dataKbd (pops the FIFO) *)
let w_gpio = 8 (* R: gpin; W: gpout *)
let w_gpio_dir = 9 (* R/W: gpoc *)

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; wr : 'a [@bits 1] (* the core's write strobe *)
    ; rd : 'a [@bits 1] (* the core's read strobe *)
    ; ioenb : 'a [@bits 1] (* the SoC's MMIO-window decode (top 64 B) *)
    ; iowadr : 'a [@bits 4] (* the MMIO word address (adr[5:2]) *)
    ; outbus : 'a [@bits 32] (* the core's store-data bus *)
    ; miso : 'a [@bits 1] (* SPI: the already-ANDed SD/net line *)
    ; rxd : 'a [@bits 1] (* RS-232 receive line; idles high *)
    ; btn : 'a [@bits 4] (* buttons (RISC5Top [btn]); read-only via word 1 *)
    ; sw : 'a [@bits 8] (* switches, logical/active-high (see the SoC) *)
    ; gpio_in : 'a [@bits 8] (* resolved GPIO pad inputs (RISC5Top [gpin]) *)
    ; ps2c : 'a [@bits 1] (* PS/2 keyboard clock *)
    ; ps2d : 'a [@bits 1] (* PS/2 keyboard data *)
    ; msclk : 'a [@bits 1] (* PS/2 mouse clock — resolved open-drain line in *)
    ; msdat : 'a [@bits 1] (* PS/2 mouse data — resolved open-drain line in *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { io_data : 'a [@bits 32] (* the MMIO read word for [iowadr] *)
    ; ms_tick : 'a [@bits 1] (* [limit]: a 1-clock pulse per ms (the sim SoC's irq) *)
    ; spi_ctrl : 'a [@bits 4] (* the spiCtrl register (the board derives sd_cs) *)
    ; mouse_out : 'a [@bits 28] (* the mouse state word (board [mouse_dbg]) *)
    ; mosi : 'a [@bits 1]
    ; sclk : 'a [@bits 1]
    ; txd : 'a [@bits 1] (* RS-232 transmit line; idles high *)
    ; leds : 'a [@bits 8] (* RISC5Top [leds] = the [Lreg] latch *)
    ; gpio_out : 'a [@bits 8] (* GPIO drive value (RISC5Top [gpout]) *)
    ; gpio_oe : 'a [@bits 8] (* GPIO output-enable / direction (RISC5Top [gpoc]) *)
    ; msclk_oe : 'a [@bits 1] (* mouse open-drain: 1 = host pulls low *)
    ; msdat_oe : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

let create
  ?(clocks_per_ms = 25000)
  ?slow_div_log2
  ?baud_slow
  ?baud_fast
  ?(extra_read_slots = [])
  (i : _ I.t)
  : _ O.t
  =
  if clocks_per_ms < 1 || clocks_per_ms > 1 lsl 16
  then failwith "Peripherals: clocks_per_ms must fit the 16-bit cnt0 prescaler (1..65536)";
  let spec = Reg_spec.create () ~clock:i.clock in
  (* ── Millisecond timer ── free-running (no reset), like RISC5Top's. A [clocks_per_ms]
     prescaler [cnt0] raises [limit] once per ms; [limit] ticks the ms counter [cnt1]
     (read at [w_ms_timer]) and leaves as [ms_tick] — the sim SoC wires it straight to the
     core's [irq]; the board stretches it across frozen (ce=0) cycles first. *)
  let cnt0 = Always.Variable.reg spec ~width:16 in
  let cnt1 = Always.Variable.reg spec ~width:32 in
  let limit = (cnt0.value ==:. clocks_per_ms - 1) -- "limit" in
  Always.(
    compile
      [ cnt0 <-- mux2 limit (zero 16) (cnt0.value +:. 1)
      ; cnt1 <-- cnt1.value +: uresize limit ~width:32
      ]);
  let cnt1_v = cnt1.value -- "cnt1" in
  (* the per-word MMIO strobes, and the one writable-register shape (RISC5Top l.138-144):
     loaded from [outbus]'s low bits on a store to [word]; reset (which beats a same-cycle
     write) clears it unless [rst:false] — the faithful no-reset exception ([gpout]
     below). *)
  let io_wr word = i.wr &: i.ioenb &: (i.iowadr ==:. word) in
  let io_rd word = i.rd &: i.ioenb &: (i.iowadr ==:. word) in
  let io_reg ?(rst = true) ~word ~width () =
    let r = Always.Variable.reg spec ~width in
    let load = mux2 (io_wr word) (sel_bottom i.outbus ~width) r.value in
    Always.(compile [ (r <-- if rst then mux2 ~:(i.rst_n) (zero width) load else load) ]);
    r.value
  in
  (* ── SPI master ── (RISC5Top wiring): a store to [w_spi_data] pulses [start]
     ([spiStart]); [w_spi_ctrl] is the 4-bit control register ([fast] = bit 2, reset to
     0). [miso] is the already-ANDed SD/net line. [?slow_div_log2] is {!Spi}'s
     divider-depth seam (the 60 MHz board passes 8). *)
  let spi_ctrl = io_reg ~word:w_spi_ctrl ~width:4 () -- "spi_ctrl" in
  let spi =
    Spi.create
      ?slow_div_log2
      { Spi.I.clock = i.clock
      ; rst_n = i.rst_n
      ; start = io_wr w_spi_data
      ; fast = bit spi_ctrl ~pos:2
      ; data_tx = i.outbus
      ; miso = i.miso
      }
  in
  (* ── UART ── RS232R receiver + RS232T transmitter at [bitrate] baud. A [w_uart_data]
     read returns the received byte [dataRx] and pulses [done_] (acks it, clearing rdyRx);
     a write starts a transmit ([start], [data] = outbus[7:0]). [w_uart_status] reads
     [{rdyTx, rdyRx}]; a write sets the 1-bit [bitrate] select (0 = 19200, 1 = 115200;
     reset 0). [?baud_*] are the units' clock-scaling seams (both directions share the one
     [bitrate] bit, so the pair travels together). *)
  let bitrate = io_reg ~word:w_uart_status ~width:1 () in
  let uart_rx =
    Uart_rx.create
      ?baud_slow
      ?baud_fast
      { Uart_rx.I.clock = i.clock
      ; rst_n = i.rst_n
      ; rxd = i.rxd
      ; fsel = bitrate
      ; done_ = io_rd w_uart_data
      }
  in
  let uart_tx =
    Uart_tx.create
      ?baud_slow
      ?baud_fast
      { Uart_tx.I.clock = i.clock
      ; rst_n = i.rst_n
      ; start = io_wr w_uart_data
      ; fsel = bitrate
      ; data = select i.outbus ~high:7 ~low:0
      }
  in
  (* ── PS/2 keyboard ({!Ps2}) + mouse ({!Mouse}) ── a [w_mouse_kbd] read carries the
     mouse state [dataMs] in bits [27:0] and the keyboard-ready bit [rdyKbd] at bit 28; a
     [w_kbd_data] read returns the keyboard byte [dataKbd] and pulses [doneKbd] (pops the
     keyboard FIFO). The mouse's open-drain [msclk]/[msdat] split into resolved-line
     inputs and drive-low [*_oe] outputs (the pad / a testbench does the wired-AND). *)
  let kbd =
    Ps2.create
      { Ps2.I.clock = i.clock
      ; rst_n = i.rst_n
      ; done_ = io_rd w_kbd_data
      ; ps2c = i.ps2c
      ; ps2d = i.ps2d
      }
  in
  let mouse =
    Mouse.create
      { Mouse.I.clock = i.clock; rst_n = i.rst_n; msclk = i.msclk; msdat = i.msdat }
  in
  let mouse_out = mouse.out -- "mouse_out" in
  (* ── Switches/buttons ([w_switches_leds] read) ── [{btn, sw}] zero-extended to 32 bits.
     RISC5Top reads [~nswi] — the OberonStation switches are active-low (board pullups);
     we take the already-logical [sw] (Nexys switches are active-high) and leave that pad
     inversion to the board shim. Default 0 = all-off = the oracle's [switches], so disk
     boot is unaffected. *)
  let switches = uresize (i.btn @: i.sw) ~width:32 in
  (* ── LEDs ([w_switches_leds] write) ── [Lreg]: cleared by reset, else latched from
     [outbus[7:0]]; driven out on [leds]. *)
  let lreg = io_reg ~word:w_switches_leds ~width:8 () in
  (* ── GPIO ── [gpout] (drive value) and [gpoc] (direction), each 8-bit. [gpoc] is
     reset-cleared; [gpout] is NOT (faithful — a pin powers up as input, drive value
     undefined). The bidirectional pad is split mouse-style: [gpio_in] in, [gpio_out] =
     [gpout] and [gpio_oe] = [gpoc] out; the board shim rebuilds the IOBUFs. *)
  let gpout = io_reg ~rst:false ~word:w_gpio ~width:8 () in
  let gpoc = io_reg ~word:w_gpio_dir ~width:8 () in
  (* ── MMIO read map ── muxed by [iowadr] (RISC5Top's [iowadr ==] chain); unmapped words
     read 0, like the RTL's [: 0]. [extra_read_slots] fills SoC-specific words (the
     board's Halftone status at 10) — collisions with the faithful map fail loudly. *)
  let base_read_map =
    [ w_ms_timer, cnt1_v
    ; w_switches_leds, switches
    ; w_uart_data, uresize uart_rx.data ~width:32
    ; w_uart_status, uresize (uart_tx.rdy @: uart_rx.rdy) ~width:32
    ; w_spi_data, spi.data_rx
    ; w_spi_ctrl, uresize spi.rdy ~width:32
    ; w_mouse_kbd, uresize (kbd.rdy @: mouse_out) ~width:32
    ; w_kbd_data, uresize kbd.data ~width:32
    ; w_gpio, uresize i.gpio_in ~width:32
    ; w_gpio_dir, uresize gpoc ~width:32
    ]
  in
  List.iter extra_read_slots ~f:(fun (word, s) ->
    if word < 0 || word > 15
    then failwith "Peripherals: extra read slot outside the 16-word MMIO window";
    if List.Assoc.mem base_read_map word ~equal:Int.equal
    then failwith "Peripherals: extra read slot collides with the faithful map";
    if width s <> 32 then failwith "Peripherals: extra read slot must be 32 bits wide");
  let io_read_map = base_read_map @ extra_read_slots in
  let io_data =
    mux
      i.iowadr
      (List.init 16 ~f:(fun w ->
         match List.Assoc.find io_read_map w ~equal:Int.equal with
         | Some s -> s
         | None -> zero 32))
  in
  { O.io_data
  ; ms_tick = limit
  ; spi_ctrl
  ; mouse_out
  ; mosi = spi.mosi
  ; sclk = spi.sclk
  ; txd = uart_tx.txd
  ; leds = lreg
  ; gpio_out = gpout
  ; gpio_oe = gpoc
  ; msclk_oe = mouse.msclk_oe
  ; msdat_oe = mouse.msdat_oe
  }
;;

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── The
   block's behaviour under a real program is covered where it always was — the two SoCs'
   co-located integration tests plus the boot/golden gates run every word of the map
   through this one instance. Here: direct-bus pokes for what only this layer owns — the
   writable-register shape (write, readback, reset-clear, gpout's no-reset), the
   extra-slot seam, and its elaboration guards. *)

let%expect_test "peripherals — direct bus: LED latch, gpout no-reset, extra slot at 10" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let extra = Signal.of_unsigned_int ~width:32 0xCAFE_F00D in
  let sim = Sim.create (create ~extra_read_slots:[ 10, extra ]) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let cyc () = Cyclesim.cycle sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  inp.rst_n := b1 1;
  inp.rxd := b1 1;
  inp.miso := b1 1;
  inp.ps2c := b1 1;
  inp.ps2d := b1 1;
  inp.msclk := b1 1;
  inp.msdat := b1 1;
  (* store 0xAB to word 1 (LEDs) and 0x3C to word 8 (gpout) *)
  let store word v =
    inp.wr := b1 1;
    inp.ioenb := b1 1;
    inp.iowadr := Bits.of_unsigned_int ~width:4 word;
    inp.outbus := Bits.of_unsigned_int ~width:32 v;
    cyc ();
    inp.wr := b1 0;
    inp.ioenb := b1 0;
    cyc ()
  in
  store w_switches_leds 0xAB;
  store w_gpio 0x3C;
  (* the combinational read mux: word 10 is the extra slot *)
  inp.iowadr := Bits.of_unsigned_int ~width:4 10;
  cyc ();
  let word10 = Bits.to_unsigned_int !(outp.io_data) in
  let leds = Bits.to_unsigned_int !(outp.leds) in
  (* reset: leds (faithful set) clear, gpout survives *)
  inp.rst_n := b1 0;
  cyc ();
  Stdlib.Printf.printf
    "leds=0x%X word10=0x%X | in reset: leds=0x%X gpout=0x%X\n"
    leds
    word10
    (Bits.to_unsigned_int !(outp.leds))
    (Bits.to_unsigned_int !(outp.gpio_out));
  [%expect {| leds=0xAB word10=0xCAFEF00D | in reset: leds=0x0 gpout=0x3C |}]
;;

let%expect_test "peripherals — elaboration guards fail loudly" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let try_create f =
    match Sim.create f with
    | (_ : Sim.t) -> Stdlib.print_endline "elaborated"
    | exception Failure msg -> Stdlib.print_endline msg
  in
  try_create (create ~clocks_per_ms:100_000);
  try_create (create ~extra_read_slots:[ 5, Signal.zero 32 ]);
  try_create (create ~extra_read_slots:[ 10, Signal.zero 8 ]);
  try_create (create ~extra_read_slots:[ 10, Signal.zero 32 ]);
  [%expect
    {|
    Peripherals: clocks_per_ms must fit the 16-bit cnt0 prescaler (1..65536)
    Peripherals: extra read slot collides with the faithful map
    Peripherals: extra read slot must be 32 bits wide
    elaborated
    |}]
;;
