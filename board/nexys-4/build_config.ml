(* Public contract in [build_config.mli]. Each [shipped] knob carries its rationale. *)

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

let shipped =
  { clocks_per_ms = 64000 (* 1 ms at the 64 MHz system clock *)
  ; (* READ phase 6 cycles = 93.75 ns at 64 MHz — deliberately above the 70 ns the chip
       strictly needs. At rc=5 the FPGA I/O round-trip budget was 13.3 ns (at 60 MHz) and
       became a standing knife-edge as the design grew (failed once, grazed twice: RamUBn
       -0.163, then +0.130, +0.009 on MemDB-in); rc=6 gives the nexys4.xdc groups 23.75 ns
       at 64 MHz (was 30 at 60, 26.2 at 62.4) against their 23.4 ns of constraints (11.7 ×
       2, tightened from 12.0 for this clock; measured use ~10.3). Cost is bounded by
       construction — PSRAM reads are only cache misses since 10a — and measured in
       bench_boot (rc5 vs rc6 same-work lockstep, ~0.5%). 65 MHz would leave 22.3 ns —
       below even the tightened split; that step needs rc=7. *)
    read_cycles = 6
  ; (* WRITE phase 5 cycles — a deliberate, measured deviation from the datasheet. Cellram
       holds the address, CE#, the byte enables and WE# for [write_cycles - 1] clocks and
       raises WE# for the last one, so 5 gives 4 clocks = 62.5 ns from
       address/CE#/byte-enable valid to the end of the write. The chip's table asks 70 ns
       there (tAW/tCW/tBW; Micron MT45W8MW16BGX Rev. H, table 16) and 45 ns of WE# low
       (tWP, met). 6 would meet all of it (78.1 ns) and was tried on silicon: both pass an
       11 MiB write/read-back test, and 6 costs 6% in DOOM (15.1 -> 14.2 fps), ~2%
       compiling, 15-18% in a store-saturated loop. 5 is kept for the speed; a board that
       shows memory corruption should try 6 first. *)
    write_cycles = 5
  ; (* SPI slow divider clk÷256: SD-init clock = 64 MHz / 256 = 250 kHz (≤ the 400 kHz
       ceiling). ÷128 would be 500 kHz, over the limit. FAST stays clk÷3 = 21.3 MHz, under
       the 25 MHz SD limit. *)
    spi_slow_div_log2 = 8
  ; (* DSP48-backed MUL/FML in place of the iterative units (checked bit-identical), with
       2 pipeline registers on the product (retimed into the DSP48 MREG/PREG): that moves
       the multiply off the critical path, which is what lets the system clock run past
       ~52 MHz (at 60 MHz the next limiter was the FPAdder's normalize/round arithmetic). *)
    multipliers = Dsp { stages = 2 }
  ; (* Phase-10a: the direct-mapped read/I-cache in front of Cellram. Async-read
       distributed RAM (LUTRAM), so a hit is combinational — check the util report infers
       RAM (distributed), not BRAM/FF, and that the combinational hit path (regfile → tag
       compare → mem_rdata mux → decode) still closes 60 MHz. *)
    icache = true
  ; (* feat/more-cache: bump the I-cache 4 KiB (1024 lines, default) → 16 KiB (4096 lines,
       lines_log2 12). DOOM's working set — renderer code + the 30.7 KB dither rank tables
       + texture/pixel streams — thrashes 4 KiB: an access-stream replay of the DOOM blob
         showed read-miss stall = 51% of the frame, a CAPACITY problem (not line width —
         wide lines need PSRAM burst fill to not backfire). Measured on hardware (timedemo
         demo1): baseline 4 KiB ~4.9 fps → 16 KiB 6.8 fps (+39%). 32 KiB was tried and
         gave only 7.1 fps (+4% — diminishing returns, the miss stream is nearly drained)
         at a razor-thin +0.005 ns vs 16 KiB's +0.019 and 2x the LUTRAM, so 16 KiB is the
         keeper — the knee of the capacity curve. Closes 60 MHz only after the build.tcl
         post-route recovery loop (the deeper async-read LUTRAM lands the combinational
         hit path — the critical cone — just short otherwise). *)
    lines_log2 = 12
  ; (* Phase-10b: write-update snoop — a word store-hit refreshes the cached line in place
       instead of dropping it (96% of running-OS load misses were snoop-invalidate
       self-inflicted; load hit 59% -> 98%, same-work 1.305x in sim — see Cache +
       test/board/nexys-4/bench_boot.ml). Timing watch: the wd mux gained a level
       (fill_data vs wdata) on the cache-write path, which was already the 60 MHz critical
       path — check WNS still closes. *)
    write_update = true
  ; (* Phase-10c: the framebuffer BRAM shadow — video served from {!Framebuf} (a 1-cycle
       on-chip read), Cellram's video port tied off (its video FSM + read-preemption logic
       prune away). Same-work 1.180x in sim, video off the PSRAM port entirely; the golden
       proves shadow ≡ PSRAM window + byte-identical desktop. Synth watch: the four fb*
       arrays must infer as BLOCK RAM (~32 RAMB36, first BRAM use in the design — check
       the util report), and the shadow write path (core_adr -> 22-bit window compare ->
       BRAM write port) must not disturb the cache-write critical path at 60 MHz. *)
    fb_bram = true
  ; (* feat/halftone v2: the generalized 8bpp display mode ({!Halftone}) — client-uploaded
       tables + geometry, overlay rect. Claim-muxed against Framebuf per request; with the
       control word never written the scanout is the proven mono path (golden
       byte-identical). Cyclesim (v1 measure): 3.38 Mcyc/tick = 17.8 fps (was 7.20/8.3),
       scanout frame ≡ host golden bit-exact. Synth watch: the four ht_pix* byte-lane
       arrays must infer BLOCK RAM (~16 RAMB36 on top of Framebuf's 32) and the four
       ht_thr* byte-lane BRAMs (1024x8) alongside; the CPU-written row map (768x22) and
       the 2x4 ht_lut* tone-LUT replicas stay distributed RAM; all-new logic is clk-domain
       BRAM-to-BRAM, must not disturb the cache-write or PSRAM-I/O critical paths at 60
       MHz. *)
    halftone = true
  ; (* Phase-10d: the write buffer — a PSRAM store retires in one ce cycle and drains in
       the background; reads wait out a pending drain (drain-before-read). Sim: same-work
       + profile in bench_boot; the golden proves coherence. Timing watch: [wb_accept]
         joins the [ce] equation (high-fanout — it gates every core register); check WNS
         still closes at 60 MHz and where the critical path lands. *)
    write_buffer = true
  ; (* Depth-2 FIFO (Phase-10d follow-up): the depth-1 residual storeW (7.5% of clocks)
       was slot-full waits from Oberon's 2-store procedure prologues — depth 2 collects
       ~3/4 of it (measured 1.066x same-work, long-window CPI 1.45 -> 1.36, storeW ->
       1.7%; bench_boot). The all-depths ceiling from there is 1.02x, so depth 3+ is
       measured dead. *)
    wbuf_depth = 2
  ; (* UART baud divisors scaled for 64 MHz so the wire is a standard rate — and
       deliberately 555/555: BOTH [fsel] settings ship ~115200 (64e6/556, −0.08%). Serial
       reads are wire-limited, so 115200 is ~5x the throughput of 19200, and oat runs
       115200 — no 19200 mode is wired on this board. The faithful 1302/217 constants are
       25 MHz-only; the 60 MHz build shipped 521/521, the 62.4 rung 541/541. (Baud
       mismatch found via oat over the real serial link.) *)
    uart_baud_slow = 555
  ; uart_baud_fast = 555
  }
;;

(* [Cellram]'s and [Cache]'s own defaults and the constants of the original 25 MHz machine
   ([Peripherals] / [Spi] / the UARTs default to the same values). *)
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
   above, the MMCM parameters in nexys4_top.v, and the PSRAM I/O constraints in
   nexys4.xdc. This reads the other two and checks that the three describe one machine. *)

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
