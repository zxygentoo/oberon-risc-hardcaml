(* The contract is in [build_config.mli]. *)

type t =
  { clocks_per_ms : int
  ; read_cycles : int
  ; write_cycles : int
  ; spi_slow_div_log2 : int
  ; multipliers : Risc5.Cpu.multipliers
  ; icache : bool
  ; lines_log2 : int
  ; write_update : bool
  ; fb_bram : bool
  ; halftone : bool
  ; write_buffer : bool
  ; wbuf_depth : int
  ; uart_baud_slow : int
  ; uart_baud_fast : int
  }

(* Why each value is what it is. The clock-dependent ones assume the 64 MHz system clock
   that nexys4_top.v generates; the test at the end of this file checks that the two, and
   the constraints, agree. *)
let shipped =
  { clocks_per_ms = 64000
  ; (* 6 clocks = 93.75 ns: the chip's 70 ns plus 23.75 ns for the FPGA's I/O round trip,
       which nexys4.xdc constrains to 11.7 ns out and 11.7 ns back. One clock fewer would
       leave that round trip 8 ns. The sixth clock is paid only on cache misses (0.86% on
       the same work when it was introduced); a 65 MHz clock would need a seventh. *)
    read_cycles = 6
  ; (* 5 clocks, a deliberate deviation from the datasheet. The controller holds the
       address, CE#, the byte enables and WE# for 4 of them, so the address is valid 62.5
       ns before the end of the write where the chip asks for 70 (tAW/tCW/tBW; Micron
       MT45W8MW16BGX rev. H, table 16). The 45 ns write pulse (tWP) is met. 6 clocks would
       meet all of it and was tried on silicon: it costs 6% in DOOM and about 2% when
       compiling. A board that shows memory corruption should try 6 first. *)
    write_cycles = 5
  ; (* clk/256 = 250 kHz for SD-card initialisation, which allows at most 400 kHz; clk/128
       would be 500. The fast SPI clock stays clk/3 = 21.3 MHz, under the card's 25. *)
    spi_slow_div_log2 = 8
  ; (* DSP48 products with two pipeline registers, which take the multiply off the
       critical path. With the combinational DSP products the clock stops near 52 MHz. *)
    multipliers = Dsp { stages = 2 }
  ; (* The read cache in front of the PSRAM. It must infer distributed RAM, not block RAM:
       a hit is a combinational read and costs no cycle. *)
    icache = true
  ; (* 16 KiB. The OS fits in 4; DOOM (the renderer plus 30.7 KB of dither tables) does
       not, and gained 39% in frame rate on hardware from 16. 32 KiB added 4% more for
       twice the LUTRAM and almost no timing slack. *)
    lines_log2 = 12
  ; (* A word store that hits refreshes the cached line instead of dropping it. Oberon
       stores to a stack slot and loads it straight back: with invalidation, 96% of the
       load misses were on lines a store had just dropped. *)
    write_update = true
  ; (* Video reads the framebuffer from a block-RAM shadow, off the PSRAM port, which it
       would otherwise hold for about 23% of all clocks. The shadow must infer block RAM
       (32 RAMB36). *)
    fb_bram = true
  ; (* The 8-bit display mode. Until a client writes its control word no video request is
       claimed and the screen is the plain mono path. Its pixel and threshold RAMs must
       infer block RAM (16 RAMB36 more). *)
    halftone = true
  ; (* A store retires in one cycle and drains to the chip in the background. *)
    write_buffer = true
  ; (* 2: Oberon's procedure prologues store in pairs. One entry left 7.5% of clocks
       waiting on a full buffer, two leave 1.7%, and a deeper one could win back at most
       2% more. *)
    wbuf_depth = 2
  ; (* 64 MHz / 556 = 115,108 baud, 0.08% under 115200, for both settings of the UART's
       rate-select bit. The original machine's slower rate, 19200, is not offered: the
       serial agent talks at 115200 and nothing on this board needs the other. *)
    uart_baud_slow = 555
  ; uart_baud_fast = 555
  }
;;

(* [Cellram]'s and [Cache]'s own defaults, and the constants of the original 25 MHz
   machine, which [Peripherals] defaults to as well *)
let bare =
  { clocks_per_ms = 25000
  ; read_cycles = 2
  ; write_cycles = 2
  ; spi_slow_div_log2 = 6
  ; multipliers = Iterative
  ; icache = false
  ; lines_log2 = 10
  ; write_update = false
  ; fb_bram = false
  ; halftone = false
  ; write_buffer = false
  ; wbuf_depth = 1
  ; uart_baud_slow = 1302
  ; uart_baud_fast = 217
  }
;;

(* ceil (ns / clock period), the period being 1e6 / clocks_per_ms ns *)
let cycles_of_ns c ~ns = ((ns * c.clocks_per_ms) + 999_999) / 1_000_000

let to_string c =
  Printf.sprintf
    "clocks_per_ms=%d rc=%d wc=%d spi_slow_div_log2=%d multipliers=%s icache=%b \
     lines_log2=%d write_update=%b fb_bram=%b halftone=%b write_buffer=%b wbuf_depth=%d \
     uart_baud=%d/%d"
    c.clocks_per_ms
    c.read_cycles
    c.write_cycles
    c.spi_slow_div_log2
    (match c.multipliers with
     | Iterative -> "iterative"
     | Dsp { stages } -> Printf.sprintf "dsp/%d" stages)
    c.icache
    c.lines_log2
    c.write_update
    c.fb_bram
    c.halftone
    c.write_buffer
    c.wbuf_depth
    c.uart_baud_slow
    c.uart_baud_fast
;;

(* ── Tests ── The clock is stated in three places that no tool ties together: [shipped]
   above, the MMCM parameters in nexys4_top.v and the PSRAM constraints in nexys4.xdc.
   This reads the other two and checks that the three describe one machine. *)

let%expect_test "the shipped clock: Build_config, the MMCM and the constraints agree" =
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let top = read "nexys4_top.v"
  and xdc = read "nexys4.xdc" in
  (* where [key] next occurs in [text] at or after [from] *)
  let find text key ~from =
    let n = String.length key in
    let rec go i =
      if i + n > String.length text
      then None
      else if String.equal (String.sub text i n) key
      then Some i
      else go (i + 1)
    in
    go from
  in
  (* the first number after position [i] *)
  let number_at text i =
    let is_digit c = Char.code c >= Char.code '0' && Char.code c <= Char.code '9' in
    let rec start i = if is_digit text.[i] then i else start (i + 1) in
    let a = start i in
    let rec stop i =
      if i < String.length text && (is_digit text.[i] || Char.equal text.[i] '.')
      then stop (i + 1)
      else i
    in
    float_of_string (String.sub text a (stop a - a))
  in
  let number_after text key =
    match find text key ~from:0 with
    | Some i -> number_at text (i + String.length key)
    | None -> failwith ("not found: " ^ key)
  in
  let clkin_ns = number_after top ".CLKIN1_PERIOD"
  and divclk = number_after top ".DIVCLK_DIVIDE"
  and mult = number_after top ".CLKFBOUT_MULT_F"
  and div_sys = number_after top ".CLKOUT0_DIVIDE_F"
  and div_pix = number_after top ".CLKOUT1_DIVIDE" in
  (* the three PSRAM groups, in file order: read-critical outputs, the data input, the
     loose write-side group *)
  let max_delays =
    let key = "\nset_max_delay" in
    let rec all from =
      match find xdc key ~from with
      | Some i -> number_at xdc (i + String.length key) :: all (i + 1)
      | None -> []
    in
    all 0
  in
  let out_ns, in_ns =
    match max_delays with
    | [ o; i; _loose ] -> o, i
    | l -> failwith (Printf.sprintf "%d set_max_delay lines, expected 3" (List.length l))
  in
  let c = shipped in
  let vco = 1000.0 /. clkin_ns /. divclk *. mult in
  let f_sys = vco /. div_sys
  and f_pix = vco /. div_pix in
  let period = 1e6 /. float c.clocks_per_ms in
  let read_phase = float c.read_cycles *. period in
  let baud d = f_sys *. 1e6 /. float (d + 1) in
  let spi_slow = f_sys *. 1e3 /. float (1 lsl c.spi_slow_div_log2)
  and spi_fast = f_sys /. 3.0 in
  Printf.printf
    "system clock: %.0f MHz / %.0f * %.0f / %.2f = %.3f MHz;  shipped: %d clocks per ms\n"
    (1000.0 /. clkin_ns)
    divclk
    mult
    div_sys
    f_sys
    c.clocks_per_ms;
  Printf.printf
    "pixel clock: %.3f MHz;  board clock in the constraints: %.3f ns\n"
    f_pix
    (number_after xdc "create_clock -period");
  Printf.printf
    "PSRAM read phase: %d clocks = %.2f ns;  the chip's 70 + constraints %.1f out + %.1f \
     in = %.2f ns\n"
    c.read_cycles
    read_phase
    out_ns
    in_ns
    (70.0 +. out_ns +. in_ns);
  Printf.printf
    "UART: %.0f / %.0f baud;  SPI: %.1f kHz slow, %.2f MHz fast\n"
    (baud c.uart_baud_slow)
    (baud c.uart_baud_fast)
    spi_slow
    spi_fast;
  let near a b = Float.abs (a -. b) < 1e-6 in
  let checks =
    [ ( "the MMCM's system clock is the one clocks_per_ms counts"
      , near (f_sys *. 1000.0) (float c.clocks_per_ms) )
    ; "the pixel clock is VID's 65 MHz", near f_pix 65.0
    ; ( "the constraints and the MMCM agree on the board clock"
      , near (number_after xdc "create_clock -period") clkin_ns )
    ; ( "the read phase covers the chip plus both constrained I/O paths"
      , read_phase >= 70.0 +. out_ns +. in_ns )
    ; ( "both UART settings are within 2% of 115200 baud"
      , List.for_all
          (fun d -> Float.abs ((baud d /. 115200.0) -. 1.0) < 0.02)
          [ c.uart_baud_slow; c.uart_baud_fast ] )
    ; "SD initialisation runs at 400 kHz or less", spi_slow <= 400.0
    ; "fast SPI stays under the SD card's 25 MHz", spi_fast <= 25.0
    ]
  in
  List.iter
    (fun (what, ok) -> if not ok then Printf.printf "INCONSISTENT: %s\n" what)
    checks;
  Printf.printf "consistent: %b\n" (List.for_all snd checks);
  [%expect
    {|
    system clock: 100 MHz / 5 * 52 / 16.25 = 64.000 MHz;  shipped: 64000 clocks per ms
    pixel clock: 65.000 MHz;  board clock in the constraints: 10.000 ns
    PSRAM read phase: 6 clocks = 93.75 ns;  the chip's 70 + constraints 11.7 out + 11.7 in = 93.40 ns
    UART: 115108 / 115108 baud;  SPI: 250.0 kHz slow, 21.33 MHz fast
    consistent: true
    |}]
;;
