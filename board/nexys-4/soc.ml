(* Public API and behaviour spec live in [soc.mli].

   Implementation note. This is [Soc] (lib/soc.ml) with the memory layer swapped for the
   PSRAM controller {!Cellram} and the core run on its clock-enable. The peripheral / MMIO
   block is the shared {!Risc5.Peripherals} cluster (the per-MMIO-word rationale lives
   there); the board's departures ride its seams — [slow_div_log2]/[baud_*] retunes, the
   Halftone status word as an extra read slot — and its exports ([sd_cs] from [spi_ctrl],
   the ce-domain IRQ stretch on [ms_tick], both below). *)

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
  ?read_cycles
  ?write_cycles
  ?(spi_slow_div_log2 = 6)
  ?(fast_mul = false)
  ?(mul_stages = 0)
  ?(icache = false)
  ?lines_log2
  ?(write_update = false)
  ?(video = true)
  ?(fb_bram = false)
  ?(halftone = false)
  ?(write_buffer = false)
  ?wbuf_depth
  ?(uart_baud_slow = 1302)
  ?(uart_baud_fast = 217)
  (i : _ I.t)
  : _ O.t
  =
  (* [halftone] without [fb_bram] would silently elaborate with no Halftone at all (its
     claim muxes against the Framebuf shadow) — an A/B run would then "measure" a build
     that never instantiated the module. Fail loudly instead, like the lib guards. *)
  if halftone && not fb_bram
  then failwith "Soc: halftone requires fb_bram (the claim muxes the Framebuf shadow)";
  let spec = Reg_spec.create () ~clock:i.clock in
  (* fetch/load feedback, broken by the core's pc/ir registers; [ms_tick] closes the same
     kind of loop with the shared {!Peripherals} cluster (built after the core, whose
     strobes it consumes) — it comes straight off the timer register, so nothing
     combinational cycles *)
  let codebus = wire 32 in
  let inbus = wire 32 in
  let ms_tick = wire 1 in
  (* ── Video ── two clocks; the framebuffer word is supplied by the arbiter and latched
     on its [vid_ack] (the PSRAM read is multi-cycle, so not on [req] as the BRAM SoC
     does). *)
  let viddata = wire 32 in
  let vid_ack = wire 1 in
  let vidpar = wire 1 in
  (* feat/halftone v2: the display-mode status word (vblank + frame counter), read at MMIO
     slot 10 — zero unless the Halftone elaboration below drives it *)
  let ht_status = wire 32 in
  let vid =
    Video.create
      ~viddata_valid:vid_ack
      ~viddata_par:vidpar
      { Video.I.clk = i.clock; pclk = i.pclk; inv = bit i.sw ~pos:7; viddata }
  in
  (* [?video] is a sim-only A/B seam: gating [vidreq] takes the video DMA off the PSRAM
     port entirely — the framebuffer-in-BRAM counterfactual (bench_boot). Elaboration-time
     and default [true], so the board netlist is untouched. (The [pclk] *input* cannot
     serve as the gate: under Cyclesim's one-domain semantics the pclk raster advances 1:1
     with [clk] regardless of the input's level — video DMA is live in every board sim.) *)
  let vidreq = (if video then vid.req else gnd) -- "vidreq" in
  let vidadr = vid.vidadr -- "vidadr" in
  (* ── Core ── on the arbiter's clock-enable; [stall_x] tied off (video is arbitrated in
     {!Cellram}, which freezes the core via [ce] instead). The
     [core_ce → core → cellram → core_ce] path is not combinational — [ce] gates only the
     core's registers, not its combinational [adr]/[mem_pend] — so [core_ce] is a forward
     wire. *)
  let core_ce = wire 1 in
  (* ── IRQ stretch (board-only) ── RISC5.v clocks its interrupt capture every cycle
     ([irq1]/[intPnd] latch even under stallX), but this board freezes those flops with
     [ce] — a 1-clock [limit] tick landing in a PSRAM/video wait (ce=0) would vanish (~39%
     of running-OS cycles are frozen; bench_boot). Hold the request across frozen cycles
     and drop it once a ce=1 cycle has sampled it: the wire stays continuously high from
     tick to delivery, so the core's edge-detect sees exactly one edge per tick — and with
     [ce] always 1 the hold term is identically 0, reducing this to [irq = limit], the lib
     [Soc] semantics. Inert to Oberon (never runs STI, so [int_enb] stays 0); the
     co-located [irq stretch] test pins the delivery count. *)
  let irq_pend = Always.Variable.reg spec ~width:1 in
  let irq_pend_v = irq_pend.value -- "irq_pend" in
  Always.(compile [ irq_pend <-- (i.rst_n &: ~:core_ce &: (ms_tick |: irq_pend_v)) ]);
  let irq = (ms_tick |: irq_pend_v) -- "irq" in
  let core =
    Cpu.create
      ~ce:core_ce
      ~fast_mul
      ~mul_stages
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
  (* on-chip fast path: a ROM-region fetch (codebus from PROM) or any MMIO load/store (top
     64 B). These take {!Cellram}'s 1-cycle path — never touching the PSRAM — which also
     keeps each MMIO access one CPU-cycle long, so the write strobes below pulse exactly
     once. *)
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
  (* Phase-10a: an optional direct-mapped read/I-cache in front of Cellram. On a hit we
     drop [mem_pend] to Cellram — its [ce] is [~mem_pend | …], so it rises this cycle (a
     0-stall hit) — and serve the word from the cache; misses and stores flow through
     unchanged (write-through), the cache snooping stores to stay coherent ({!Cache}).
     [cache_hit] is driven below (after Cellram, whose [ce]/[rdata] the cache needs); the
     loop is not combinational — [hit] reads the cache array, not Cellram. *)
  let cache_hit = wire 1 in
  (* ── PSRAM controller / CPU+video arbiter ── *)
  let cellram =
    Cellram.create
      ?read_cycles
      ?write_cycles
      ~write_buffer
      ?wbuf_depth
      { Cellram.I.clock = i.clock
      ; mem_pend = core.mem_pend &: ~:cache_hit
      ; cpu_internal
      ; adr = core_adr
      ; wr = core.wr
      ; ben = core_ben
      ; wdata = core.outbus
      ; vidreq = (if fb_bram then gnd else vidreq)
      ; vidadr
      ; mem_dq_i = i.mem_dq_i
      }
  in
  assign core_ce (cellram.ce -- "core_ce");
  (* Phase-10c: [fb_bram] serves the video DMA from the {!Framebuf} BRAM shadow (a 1-cycle
     on-chip read) instead of the PSRAM port — Cellram's [vidreq] is tied low above, so
     its video FSM + read-preemption logic go dead (pruned at synthesis). The shadow's
     write port taps exactly the store the cache snoops ([psram_store]) in the same
     write-through transaction, so shadow ≡ PSRAM framebuffer window at every instant. *)
  let viddata_src, vid_ack_src, vidpar_src, ht_status_src =
    if fb_bram
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
      (* feat/halftone v2: the generalized 8bpp display mode ({!Halftone}), taps the same
         store transaction the Framebuf shadow and the cache snoop ride. [claim] — latched
         per accepted request: mode on AND the fetch word inside the client's rect — muxes
         which shadow answers the DMA, so the mono path serves everything outside the rect
         (v1 muxed on the whole-screen mode bit). With the control word never written no
         request ever claims, and this elaboration is display-identical to
         [halftone:false] (the do-no-harm gate below is the visual golden). *)
      if halftone
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
  (* Phase-10a: drive [cache_hit] and pick the CPU read word. When on, a fetch/load to
     PSRAM (not ROM/MMIO — [cpu_internal] takes the 1-cycle path) can hit the cache; a
     store to PSRAM snoops. When off, [cache_hit] is tied low and the word is Cellram's,
     verbatim. *)
  let mem_rdata =
    if icache
    then (
      let cacheable_read = core.mem_pend &: ~:(core.wr) &: ~:cpu_internal in
      let cacheable_read = cacheable_read -- "cache_read" in
      let cache =
        Cache.create
          ?lines_log2
          ~write_update
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
  (* ── The shared peripheral/MMIO cluster ({!Peripherals}) ── never ce-gated: a slow
     (wait-stated) CPU polls full-speed peripherals, exactly as on real hardware. Board
     seams: the SPI slow divider + UART bauds retuned for the 60 MHz clock
     (emit_verilog.ml), and the Halftone status word (vblank + frame counter, the v2 seam)
     at read slot 10 (0xFFFFE8). *)
  let per =
    Peripherals.create
      ~clocks_per_ms
      ~slow_div_log2:spi_slow_div_log2
      ~baud_slow:uart_baud_slow
      ~baud_fast:uart_baud_fast
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

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── [Soc] is
   [Soc] (lib/soc.ml) with the memory layer swapped for {!Cellram} + the core on a
   clock-enable, sharing the {!Peripherals} cluster. These mirror soc.ml's own co-located
   integration tests (a hand-assembled boot stub in the boot ROM, run on the interpreter,
   read back through the core's named [regfile] — no oracle, so the board library stays
   oracle-free, §3/§6), here closed with the behavioural {!Cellram_model} on the PSRAM
   pins. They guard the board-specific paths: the Cellram memory round-trip, the shared
   timer's free-run under wait-states (ce interplay the lib SoC can't see), and the MMIO
   read/write path through the on-chip fast path. (The full boot through this SoC is the
   opt-in [@boot_checkpoint_board].) *)

module Sb_I = I

let sb_create = create

module For_tests = struct
  module Tb = struct
    (* the board SoC closed with the behavioural cellular-RAM double on its PSRAM pins —
       the ONE closure shared by the co-located tests below and the test/board harnesses
       (board_tb: the board gates + bench_boot). [leds] serves the MMIO test; [sclk]
       drives the gates' SD bridge; [hsync]/[vsync]/[rgb] keep the whole video pixel path
       (the Framebuf shadow BRAMs included) live under Cyclesim's dead-code elimination —
       with them unobserved the fetched-word path drives no output and is pruned, and a
       [lookup_mem_by_name "fb0".."fb3"] readback finds nothing. Internal state
       ([regfile]/[cnt1]/[core_ce]/...) is reached by name via [trace_all]. *)
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

    (* [addr_bits] defaults to a tiny 2^12-halfword model: the co-located tests confine
       CPU stimulus under byte 0x200, and the faithful 1 MB model cost seconds of runtest
       (the video DMA reads alias in the shrunk model, but nothing observes [viddata]
       here). The boot gates pass 19 — the full 1 MiB — to load the real disk image. *)
    let create
      ~contents
      ?clocks_per_ms
      ?(read_cycles = 2)
      ?(write_cycles = 2)
      ?icache
      ?lines_log2
      ?write_update
      ?video
      ?fb_bram
      ?halftone
      ?write_buffer
      ?wbuf_depth
      ?fast_mul
      ?mul_stages
      ?spi_slow_div_log2
      ?(addr_bits = 12)
      (i : _ I.t)
      : _ O.t
      =
      let dq = wire 16 in
      let soc =
        sb_create
          ~contents
          ?clocks_per_ms
          ~read_cycles
          ~write_cycles
          ?icache
          ?lines_log2
          ?write_update
          ?video
          ?fb_bram
          ?halftone
          ?write_buffer
          ?wbuf_depth
          ?fast_mul
          ?mul_stages
          ?spi_slow_div_log2
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
      let m =
        Cellram_model.create
          ~addr_bits
          { Cellram_model.I.clock = i.clock
          ; mem_adr = soc.mem_adr
          ; mem_dq_o = soc.mem_dq_o
          ; ce_n = soc.ram_ce_n
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

  (* drive every line to its idle level ([rst_n] excluded — reset sequencing is the test's
     own). NB [pclk] low does NOT quiet the video DMA: under Cyclesim's one-domain
     semantics the pclk-clocked raster advances 1:1 with [clk] whatever this input holds
     (lib/soc.ml's video test relies on exactly that), so video contends for the PSRAM
     port in every board sim — gate it with [create]'s [?video] if a test needs the bus to
     itself. *)
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
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (Tb.create ~contents:prog) in
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
      (Tb.create ~contents:prog ~clocks_per_ms:50)
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
  (* the timer test's freeze-heavy load loop again — most cycles have [ce]=0, so most
     1-clock [limit] ticks land while the core's ce-gated [irq1]/[int_pnd] flops are
     frozen. The board-layer IRQ stretch must deliver every tick anyway: each tick makes
     the (stretched) [irq] wire rise and stay high until a ce=1 cycle samples it, so the
     core's [irq1] (which follows [irq] on enabled cycles, independent of [int_enb]) rises
     exactly once per tick. Without the stretch, ticks in frozen cycles vanish and [irq1]
     rises far fewer times than [cnt1]. *)
  let prog =
    [| 0x41000100 (* MOV R1, #0x100 *)
     ; 0x82100000 (* LD R2, [R1] : PSRAM read (multi-cycle) *)
     ; 0xE7FFFFFE (* B -2 : loop back to the LD *)
    |]
  in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~contents:prog ~clocks_per_ms:50)
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
  (* The timer is the shared {!Peripherals}' now, but the property stays guarded through
     THIS harness too: RISC5Top's cnt0/cnt1 carry no rst term (l.139-140), EO's
     abort-recovery relies on [Kernel.Time()] never rewinding across a button reset, and
     only the board composition has a ce-gated core underneath (a reset term would show as
     a rewind AND undercount here). *)
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let nop = 0x40080000 in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~contents:(Array.create ~len:8 nop) ~clocks_per_ms:10)
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
  let sim = Sim.create ~config:Cyclesim.Config.trace_all (Tb.create ~contents:prog) in
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
