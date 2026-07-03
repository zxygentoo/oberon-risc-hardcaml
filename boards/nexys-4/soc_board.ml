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
  ?read_cycles
  ?write_cycles
  ?(spi_slow_div_log2 = 6)
  ?(fast_mul = false)
  ?(mul_stages = 0)
  ?(icache = false)
  ?lines_log2
  ?(write_update = false)
  ?(video = true)
  ?(uart_baud_slow = 1302)
  ?(uart_baud_fast = 217)
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
  let vidpar = wire 1 in
  let vid =
    Vid.create
      ~viddata_valid:vid_ack
      ~viddata_par:vidpar
      { Vid.I.clk = i.clock; pclk = i.pclk; inv = bit i.sw ~pos:7; viddata }
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
  Always.(compile [ irq_pend <-- (i.rst_n &: ~:core_ce &: (limit |: irq_pend_v)) ]);
  let irq = (limit |: irq_pend_v) -- "irq" in
  let core =
    Risc5_core.create
      ~ce:core_ce
      ~fast_mul
      ~mul_stages
      { Risc5_core.I.clock = i.clock
      ; rst_n = i.rst_n
      ; irq
      ; stall_x = gnd
      ; inbus
      ; codebus
      }
  in
  (* ── Address decode ── (same constants as soc.ml / RISC5Top) *)
  let core_adr = core.adr -- "core_adr" in
  let core_ben = core.ben -- "core_ben" in
  let rom_region = (select core_adr ~high:23 ~low:14 ==:. 0x3FF) -- "rom_region" in
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
  (* Phase-10a: an optional direct-mapped read/I-cache in front of Cellram. On a hit we
     drop [mem_pend] to Cellram — its [ce] is [~mem_pend | …], so it rises this cycle (a
     0-stall hit) — and serve the word from the cache; misses and stores flow through
     unchanged (write-through), the cache snooping stores to stay coherent ({!Icache}).
     [cache_hit] is driven below (after Cellram, whose [ce]/[rdata] the cache needs); the
     loop is not combinational — [hit] reads the cache array, not Cellram. *)
  let cache_hit = wire 1 in
  (* ── PSRAM controller / CPU+video arbiter ── *)
  let cellram =
    Cellram.create
      ?read_cycles
      ?write_cycles
      { Cellram.I.clock = i.clock
      ; mem_pend = core.mem_pend &: ~:cache_hit
      ; cpu_internal
      ; adr = core_adr
      ; wr = core.wr
      ; ben = core_ben
      ; wdata = core.outbus
      ; vidreq
      ; vidadr
      ; mem_dq_i = i.mem_dq_i
      }
  in
  assign core_ce (cellram.ce -- "core_ce");
  assign viddata cellram.viddata;
  assign vid_ack cellram.vid_ack;
  assign vidpar cellram.vidpar;
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
        Icache.create
          ?lines_log2
          ~write_update
          { Icache.I.clock = i.clock
          ; adr = core_adr
          ; cacheable_read
          ; write = core.wr &: ~:cpu_internal
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
  let prom = Prom.create ~contents { Prom.I.adr = select core_adr ~high:10 ~low:2 } in
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
      ~slow_div_log2:spi_slow_div_log2
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
      ~baud_slow:uart_baud_slow
      ~baud_fast:uart_baud_fast
      { Rs232r.I.clock = i.clock
      ; rst_n = i.rst_n
      ; rxd = i.rxd
      ; fsel = bitrate.value
      ; done_ = core.rd &: ioenb &: (iowadr ==:. 2)
      }
  in
  let uart_tx =
    Rs232t.create
      ~baud_slow:uart_baud_slow
      ~baud_fast:uart_baud_fast
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
  assign codebus (mux2 rom_region prom.data mem_rdata);
  assign inbus (mux2 ioenb io_data mem_rdata);
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

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   [Soc_board] is [Soc] (lib/soc.ml) with the memory layer swapped for {!Cellram} + the
   core on a clock-enable — a hand-copy of soc.ml's peripheral block that can drift from
   it. These mirror soc.ml's own co-located integration tests (a hand-assembled boot stub
   in the boot ROM, run on the interpreter, read back through the core's named [regfile] —
   no oracle, so the board library stays oracle-free, §3/§6), here closed with the
   behavioural {!Cellram_model} on the PSRAM pins. They guard the board-specific paths:
   the Cellram memory round-trip, the free-running (non-ce-gated) timer under wait-states,
   and the MMIO read/write path through the on-chip fast path. (The full boot through this
   SoC is the opt-in [@boot_checkpoint_board].) *)

module Sb_I = I

let sb_create = create

module Tb = struct
  (* the board SoC closed with the behavioural cellular-RAM on its pins; PSRAM phases
     small (the model answers at once — only the control flow is under test). [leds] is
     surfaced for the MMIO test; the core's [regfile]/[cnt1]/[core_ce] are reached by name
     via [trace_all]. *)
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
    type 'a t = { leds : 'a [@bits 8] } [@@deriving hardcaml]
  end

  let create ~contents ?clocks_per_ms (i : _ I.t) : _ O.t =
    let dq = wire 16 in
    let soc =
      sb_create
        ~contents
        ?clocks_per_ms
        ~read_cycles:2
        ~write_cycles:2
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
    { O.leds = soc.leds }
  ;;
end

(* drive every line to its idle level. NB [pclk] low does NOT quiet the video DMA: under
   Cyclesim's one-domain semantics the pclk-clocked raster advances 1:1 with [clk]
   whatever this input holds (lib/soc.ml's video test relies on exactly that), so video
   contends for the PSRAM port in every board sim — gate it with [create]'s [?video] if a
   test needs the bus to itself. *)
let drive_idle (inp : _ Tb.I.t) =
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
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

let%expect_test "soc_board — fetch ROM, store + load round-trip through PSRAM" =
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

let%expect_test "soc_board — ms timer counts clocks, not ce cycles (free-running under \
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
    | None -> failwith "soc_board timer test: no traced node core_ce"
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

let%expect_test "soc_board — a ms tick landing in a frozen (ce=0) cycle still reaches \
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

let%expect_test "soc_board — MMIO word 1: read {btn, sw}; store latches the LEDs" =
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
