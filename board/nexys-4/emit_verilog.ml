(* Phase 7 — emit the synthesizable board SoC ({!Nexys4_board.Soc}) as Verilog, with the
   real boot ROM baked in. The hand-written nexys4_top.v (same dir) wraps the emitted
   [soc_board] module with the vendor primitives (MMCM, IOBUFs). Prints to stdout;
   gen_verilog.sh redirects it to board/_generated/nexys-4/soc_board.v.

   Lives in the board layer (not test/): it emits *this board's* SoC and sits next to the
   gen_verilog.sh / build.tcl / nexys4_top.v that consume it. The ROM image comes from the
   design library ({!Risc5.Rom}), so the board emit needs no software oracle.

   Parameters baked into the netlist: 64000 clocks/ms (1 ms at 64 MHz); PSRAM phases read
   6 / write 5 cycles (93.75 / 78.1 ns vs the chip's 70 ns — the read deliberately above
   spec; rationale at the knob below). Tune read/write cycles here if hardware needs it.

   NB (feat/clock-push): retuned for a 64 MHz system clock (nexys4_top.v MMCM VCO 1040,
   CLKOUT0_DIVIDE_F = 16.250 — the VCO that keeps 64 and the 65 pixel clock both exact);
   before that, feat/fast-clock's 60 MHz (VCO 780 ÷ 13.000), enabled by the pipelined DSP
   multiplies (mul_stages:2) that move the multiply off the critical path. At 64 MHz
   (15.625 ns/cycle) the read phase keeps 6 cycles (93.75 ns = 70 for the chip + 23.75 for
   the FPGA round trip; the xdc groups tightened 12.0 → 11.7 to fit) and the SPI slow
   divider stays ÷256 (250 kHz ≤ the 400 kHz SD-init ceiling). Timing note: 64 closes at
   WNS +0.004 only under build.tcl's ExtraTimingOpt placement (Explore plateaus at −0.071)
   — the thinnest rung of the ladder; the structural relief if a rebuild ever refuses is
   registering the icache fill path (or reverting a rung). Revert to 62.4 MHz:
   clocks_per_ms 62400, uart_baud 541/541, MMCM VCO 780 (MULT_F 39.000) / CLKOUT0 12.500 /
   CLKOUT1 12, xdc groups back to 12.0. Revert to 60: likewise with clocks_per_ms 60000,
   uart_baud 521/521, CLKOUT0 13.000. Revert to 50: clocks_per_ms 50000, read/write_cycles
   4, spi_slow_div_log2 7, MMCM VCO 650 (DIVCLK 1 / MULT 6.5), CLKOUT1_DIVIDE 10. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module Circ = Circuit.With_interface (Soc.I) (Soc.O)

let () =
  let circuit =
    Circ.create_exn
    (* the EMITTED Verilog module keeps the name "soc_board" (decoupled from the OCaml
       module, now [Soc]): nexys4_top.v instantiates it by this name and the whole Vivado
       flow reads board/_generated/nexys-4/soc_board.v — renaming the artifact would churn
       the board flow for nothing. *)
      ~name:"soc_board"
      (Soc.create
         ~contents:Risc5.Rom.bootloader
         ~clocks_per_ms:64000
           (* READ phase 6 cycles = 93.75 ns at 64 MHz — deliberately above the 70 ns the
              chip strictly needs. At rc=5 the FPGA I/O round-trip budget was 13.3 ns (at
              60 MHz) and became a standing knife-edge as the design grew (failed once,
              grazed twice: RamUBn -0.163, then +0.130, +0.009 on MemDB-in); rc=6 gives
              the nexys4.xdc groups 23.75 ns at 64 MHz (was 30 at 60, 26.2 at 62.4)
              against their 23.4 ns of constraints (11.7 × 2, tightened from 12.0 for this
              clock; measured use ~10.3). Cost is bounded by construction — PSRAM reads
              are only cache misses since 10a — and measured in bench_boot (rc5 vs rc6
              same-work lockstep, ~0.5%). 65 MHz would leave 22.3 ns — below even the
              tightened split; that step needs rc=7. WRITE phase stays 5 (78.1 ns): its
              group-3 budget never pressured, and drains are background since the 10d
              buffer. *)
         ~read_cycles:6
         ~write_cycles:5
           (* SPI slow divider clk÷256: SD-init clock = 64 MHz / 256 = 250 kHz (≤ the 400
              kHz ceiling). ÷128 would be 500 kHz, over the limit. FAST stays clk÷3 = 21.3
              MHz, under the 25 MHz SD limit. *)
         ~spi_slow_div_log2:8
           (* Phase-9 DSP multipliers: swap the iterative MUL/FML for their DSP48-backed
              variants (proven bit-identical). *)
         ~fast_mul:true
           (* feat/fast-clock: 2-stage *pipelined* DSP multiplies (registers retimed into
              the DSP48 MREG/PREG) move the multiply off the critical path, which is what
              lets the system clock go to 60 MHz. The new limiter is the FPAdder's
              normalize/round arithmetic (see the branch's synth notes). *)
         ~mul_stages:2
           (* Phase-10a: the direct-mapped read/I-cache in front of Cellram. Async-read
              distributed RAM (LUTRAM), so a hit is combinational — check the util report
              infers RAM (distributed), not BRAM/FF, and that the combinational hit path
              (regfile → tag compare → mem_rdata mux → decode) still closes 60 MHz. *)
         ~icache:true
           (* feat/more-cache: bump the I-cache 4 KiB (1024 lines, default) → 16 KiB (4096
              lines, lines_log2 12). DOOM's working set — renderer code + the 30.7 KB
              dither rank tables + texture/pixel streams — thrashes 4 KiB: an
              access-stream replay of the DOOM blob showed read-miss stall = 51% of the
              frame, a CAPACITY problem (not line width — wide lines need PSRAM burst fill
              to not backfire). Measured on hardware (timedemo demo1): baseline 4 KiB ~4.9
              fps → 16 KiB 6.8 fps (+39%). 32 KiB was tried and gave only 7.1 fps (+4% —
              diminishing returns, the miss stream is nearly drained) at a razor-thin
              +0.005 ns vs 16 KiB's +0.019 and 2x the LUTRAM, so 16 KiB is the keeper —
              the knee of the capacity curve. Closes 60 MHz only after the build.tcl
              post-route recovery loop (the deeper async-read LUTRAM lands the
              combinational hit path — the critical cone — just short otherwise). *)
         ~lines_log2:12
           (* Phase-10b: write-update snoop — a word store-hit refreshes the cached line
              in place instead of dropping it (96% of running-OS load misses were
              snoop-invalidate self-inflicted; load hit 59% -> 98%, same-work 1.305x in
              sim — see Cache + test/board/nexys-4/bench_boot.ml). Timing watch: the wd
              mux gained a level (fill_data vs wdata) on the cache-write path, which was
              already the 60 MHz critical path — check WNS still closes. *)
         ~write_update:true
           (* Phase-10c: the framebuffer BRAM shadow — video served from {!Framebuf} (a
              1-cycle on-chip read), Cellram's video port tied off (its video FSM +
              read-preemption logic prune away). Same-work 1.180x in sim, video off the
              PSRAM port entirely; the golden proves shadow ≡ PSRAM window +
              byte-identical desktop (FB_BRAM=1). Synth watch: the four fb* arrays must
              infer as BLOCK RAM (~32 RAMB36, first BRAM use in the design — check the
              util report), and the shadow write path (core_adr -> 22-bit window compare
              -> BRAM write port) must not disturb the cache-write critical path at 60
              MHz. *)
         ~fb_bram:true
           (* feat/halftone v2 (EXPERIMENT): the generalized 8bpp display mode
              ({!Halftone}) — client-uploaded tables + geometry, overlay rect. Claim-muxed
              against Framebuf per request; with the control word never written the
              scanout is the proven mono path (golden byte-identical, HALFTONE=1).
              Cyclesim (v1 measure): 3.38 Mcyc/tick = 17.8 fps (was 7.20/8.3), scanout
              frame ≡ host golden bit-exact. Synth watch: the four ht_pix* byte-lane
              arrays must infer BLOCK RAM (~16 RAMB36 on top of Framebuf's 32) and the
              four ht_thr* byte-lane BRAMs (1024x8) alongside; the CPU-written row map
              (768x22) and the 2x4 ht_lut* tone-LUT replicas stay distributed RAM; all-new
              logic is clk-domain BRAM-to-BRAM, must not disturb the cache-write or
              PSRAM-I/O critical paths at 60 MHz. *)
         ~halftone:true
           (* Phase-10d: the 1-entry write buffer — a PSRAM store retires in one ce cycle
              and drains in the background; reads wait out a pending drain
              (drain-before-read). Sim: same-work + profile in bench_boot; golden proves
              coherence with WBUF=1. Timing watch: [wb_accept] joins the [ce] equation
              (high-fanout — it gates every core register); check WNS still closes at 60
              MHz and where the critical path lands. *)
         ~write_buffer:true
           (* Depth-2 FIFO (Phase-10d follow-up): the depth-1 residual storeW (7.5% of
              clocks) was slot-full waits from Oberon's 2-store procedure prologues —
              depth 2 collects ~3/4 of it (measured 1.066x same-work, long-window CPI 1.45
              -> 1.36, storeW -> 1.7%; bench_boot). The all-depths ceiling from there is
              1.02x, so depth 3+ is measured dead. *)
         ~wbuf_depth:2
           (* UART baud divisors scaled for 64 MHz so the wire is a standard rate — and
              deliberately 555/555: BOTH [fsel] settings ship ~115200 (64e6/556, −0.08%).
              Serial reads are wire-limited, so 115200 is ~5x the throughput of 19200, and
              oat runs 115200 — no 19200 mode is wired on this board. The faithful
              1302/217 constants are 25 MHz-only; the 60 MHz build shipped 521/521, the
              62.4 rung 541/541. (Baud mismatch found via oat over the real serial link.) *)
         ~uart_baud_slow:555
         ~uart_baud_fast:555)
  in
  Rtl.print Verilog circuit
;;
