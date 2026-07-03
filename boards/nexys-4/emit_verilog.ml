(* Phase 7 — emit the synthesizable board SoC ({!Nexys4_board.Soc}) as Verilog, with the
   real boot ROM baked in. The hand-written nexys4_top.v (same dir) wraps the emitted
   [soc_board] module with the vendor primitives (MMCM, IOBUFs). Prints to stdout;
   gen_verilog.sh redirects it to boards/_generated/nexys-4/soc_board.v.

   Lives in the board layer (not test/): it emits *this board's* SoC and sits next to the
   gen_verilog.sh / build.tcl / nexys4_top.v that consume it. The ROM image comes from the
   design library ({!Risc5.Rom}), so the board emit needs no software oracle.

   Parameters baked into the netlist: 60000 clocks/ms (1 ms at 60 MHz); 5-cycle PSRAM
   phases (83 ns > the chip's 70 ns at 60 MHz). Tune read/write cycles here if hardware
   needs it.

   NB (feat/fast-clock): retuned for a 60 MHz system clock (nexys4_top.v MMCM VCO 780,
   CLKOUT0_DIVIDE_F = 13.000). Enabled by the pipelined DSP multiplies (mul_stages:2) that
   move the multiply off the critical path. At 60 MHz (16.67 ns/cycle) the memory phase
   needs 5 cycles for ≥70 ns (4 would be 66.7 ns, under spec) and the SPI slow divider
   goes ÷256 (÷128 would be 469 kHz, over the 400 kHz SD-init ceiling). Revert to 50 MHz:
   clocks_per_ms 50000, read/write_cycles 4, spi_slow_div_log2 7, MMCM VCO 650 (DIVCLK 1 /
   MULT 6.5), CLKOUT1_DIVIDE 10. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module Circ = Circuit.With_interface (Soc.I) (Soc.O)

let () =
  let circuit =
    Circ.create_exn
    (* the EMITTED Verilog module keeps the name "soc_board" (decoupled from the OCaml
       module, now [Soc]): nexys4_top.v instantiates it by this name and the whole Vivado
       flow reads boards/_generated/nexys-4/soc_board.v — renaming the artifact would
       churn the board flow for nothing. *)
      ~name:"soc_board"
      (Soc.create
         ~contents:Risc5.Rom.bootloader
         ~clocks_per_ms:60000
           (* READ phase 6 cycles = 100 ns at 60 MHz — deliberately one above the 5 (83
              ns) the 70 ns chip strictly needs. At rc=5 the FPGA I/O round-trip budget
              was 13.3 ns and became a standing knife-edge as the design grew (failed
              once, grazed twice: RamUBn -0.163, then +0.130, +0.009 on MemDB-in); rc=6
              gives the nexys4.xdc groups 30 ns. Cost is bounded by construction — PSRAM
              reads are only cache misses since 10a — and measured in bench_boot (rc5 vs
              rc6 same-work lockstep, ~0.5%). WRITE phase stays 5 (83 ns): its group-3
              budget never pressured, and drains are background since the 10d buffer. *)
         ~read_cycles:6
         ~write_cycles:5
           (* SPI slow divider clk÷256: SD-init clock = 60 MHz / 256 = 234 kHz (≤ the 400
              kHz ceiling). ÷128 would be 469 kHz, over the limit at 60 MHz. FAST stays
              clk÷3 = 20 MHz, under the 25 MHz SD limit. *)
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
           (* Phase-10b: write-update snoop — a word store-hit refreshes the cached line
              in place instead of dropping it (96% of running-OS load misses were
              snoop-invalidate self-inflicted; load hit 59% -> 98%, same-work 1.305x in
              sim — see Cache + test/boards/nexys-4/bench_boot.ml). Timing watch: the wd
              mux gained a level (fill_data vs wdata) on the cache-write path, which was
              already the 60 MHz critical path — check WNS still closes. *)
         ~write_update:true
           (* Phase-10c: the framebuffer BRAM shadow — video served from {!Framebuf} (a
              1-cycle on-chip read), Cellram's video port tied off (its video FSM +
              read-preemption logic prune away). Same-work 1.180x in sim, video off the
              PSRAM port entirely; the golden proves shadow ≡ PSRAM window +
              byte-identical desktop (FB_BRAM=1). Synth watch: the four fb* arrays must
              infer as BLOCK RAM (~32 RAMB36, first BRAM use in the design — check the
              util report), and the shadow write path (core_adr -> 18-bit window compare
              -> BRAM write port) must not disturb the cache-write critical path at 60
              MHz. *)
         ~fb_bram:true
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
           (* UART baud divisors scaled for 60 MHz so the wire is a standard rate — and
              deliberately 521/521: BOTH [fsel] settings ship ~115200 (60e6/522, −0.2%).
              Serial reads are wire-limited, so 115200 is ~5x the throughput of 19200, and
              oat runs 115200 — no 19200 mode is wired on this board. The faithful
              1302/217 constants are 25 MHz-only — at 60 MHz they'd give 46083 baud
              (nonstandard), which no host UART can lock to. (Found via oat over the real
              serial link.) *)
         ~uart_baud_slow:521
         ~uart_baud_fast:521)
  in
  Rtl.print Verilog circuit
;;
