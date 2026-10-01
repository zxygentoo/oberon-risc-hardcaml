(* The contract is in [peripherals.mli].

   Two things stay outside, with the board that needs them: the SD chip select, derived
   from the exported [spi_ctrl], and the stretching of [ms_tick] across cycles in which a
   clock-gated core is frozen. *)

open! Base
open Hardcaml
open Signal

(* RISC5Top's MMIO words. One name each, used by the write strobe, the register and the
   read mux alike. *)
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
  (* ── Millisecond timer ── free-running, without reset, as RISC5Top's: the prescaler
     [cnt0] raises [limit] once a millisecond, which steps the counter [cnt1] and leaves
     as [ms_tick]. *)
  let cnt0 = Always.Variable.reg spec ~width:16 in
  let cnt1 = Always.Variable.reg spec ~width:32 in
  let limit = (cnt0.value ==:. clocks_per_ms - 1) -- "limit" in
  Always.(
    compile
      [ cnt0 <-- mux2 limit (zero 16) (cnt0.value +:. 1)
      ; cnt1 <-- cnt1.value +: uresize limit ~width:32
      ]);
  let cnt1_v = cnt1.value -- "cnt1" in
  (* The write strobes, and the one shape of writable register (RISC5Top l.138-144):
     loaded from [outbus] on a store to its word, and cleared by reset, which wins over a
     store in the same cycle. [rst:false] is for the one register the RTL does not reset,
     [gpout]. *)
  let io_wr word = i.wr &: i.ioenb &: (i.iowadr ==:. word) in
  let io_rd word = i.rd &: i.ioenb &: (i.iowadr ==:. word) in
  let io_reg ?(rst = true) ~word ~width () =
    let r = Always.Variable.reg spec ~width in
    let load = mux2 (io_wr word) (sel_bottom i.outbus ~width) r.value in
    Always.(compile [ (r <-- if rst then mux2 ~:(i.rst_n) (zero width) load else load) ]);
    r.value
  in
  (* ── SPI ── A store to the data word pulses [start]; the control word is a 4-bit
     register whose bit 2 is [fast]. [miso] arrives already combined from the SD card and
     the network port. *)
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
  (* ── UART ── Reading the data word returns the received byte and acknowledges it;
     writing it starts a transmission. The status word reads [{rdyTx, rdyRx}], and a write
     to it sets the rate bit (0 = slow). *)
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
  (* ── PS/2 keyboard and mouse ── The mouse word carries the mouse state in bits 27..0
     and the keyboard-ready flag in bit 28; reading the keyboard word returns a byte and
     pops the FIFO. *)
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
  (* ── Switches and buttons ── RISC5Top reads [~nswi], its board's switches being active
     low; here [sw] is already logical, and the pad inversion is the board's. All off, the
     default, selects booting from disk. *)
  let switches = uresize (i.btn @: i.sw) ~width:32 in
  (* ── LEDs ── a latch, written through the switches' word *)
  let lreg = io_reg ~word:w_switches_leds ~width:8 () in
  (* ── GPIO ── [gpout] is the drive value and [gpoc] the direction. [gpoc] is cleared by
     reset; [gpout] is not, as in the RTL: a pin comes up as an input. The bidirectional
     pad is split as the mouse's lines are. *)
  let gpout = io_reg ~rst:false ~word:w_gpio ~width:8 () in
  let gpoc = io_reg ~word:w_gpio_dir ~width:8 () in
  (* ── Read mux ── Unmapped words read 0. *)
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
  if List.contains_dup extra_read_slots ~compare:(fun (a, _) (b, _) -> Int.compare a b)
  then failwith "Peripherals: two extra read slots claim the same word";
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

(* ── Tests ── The cluster is exercised by real programs in both SoCs' tests and in the
   boot gates. Here, what only this layer has: the writable-register shape (write, read
   back, reset, and [gpout] surviving reset), the extra read slots, and the elaboration
   guards. *)

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
  try_create (create ~extra_read_slots:[ 10, Signal.zero 32; 10, Signal.zero 32 ]);
  try_create (create ~baud_slow:0);
  try_create (create ~baud_fast:4096);
  try_create (create ~extra_read_slots:[ 10, Signal.zero 32 ]);
  [%expect
    {|
    Peripherals: clocks_per_ms must fit the 16-bit cnt0 prescaler (1..65536)
    Peripherals: extra read slot collides with the faithful map
    Peripherals: extra read slot must be 32 bits wide
    Peripherals: two extra read slots claim the same word
    Uart_rx: baud_slow must be in 1..4095 clocks (the 12-bit tick), got 0
    Uart_rx: baud_fast must be in 1..4095 clocks (the 12-bit tick), got 4096
    elaborated
    |}]
;;
