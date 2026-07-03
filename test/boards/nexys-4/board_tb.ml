(* Shared board-SoC test harness: {!Nexys4_board.Soc} closed with the behavioural PSRAM
   double {!Nexys4_board.Cellram_model} on its memory pins. Both board integration tests
   here (the boot-handoff checkpoint and the visual golden) — and the board gauge
   bench_boot (this dir) — wire the SoC to the model identically and reconstruct 32-bit
   words from its two byte lanes the same way; this factors that out. The
   [fast_mul]/[mul_stages] knobs exist for the bench's DSP-multiplier sweep (the tests
   leave them at the Soc defaults). The public contract is in board_tb.mli. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module Cellram_model = Nexys4_board.Cellram_model

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
    { sclk : 'a [@bits 1]
    ; hsync : 'a [@bits 1]
    ; vsync : 'a [@bits 1]
    ; rgb : 'a [@bits 6]
    }
  [@@deriving hardcaml]
end

let create
  ?(read_cycles = 2)
  ?(write_cycles = 2)
  ?(icache = false)
  ?lines_log2
  ?(write_update = false)
  ?(video = true)
  ?(fb_bram = false)
  ?(write_buffer = false)
  ?wbuf_depth
  ?(fast_mul = false)
  ?(mul_stages = 0)
  ?(contents = Risc5.Rom.bootloader)
  (i : _ I.t)
  : _ O.t
  =
  let dq = Signal.wire 16 in
  let soc =
    Soc.create
      ~contents
      ~read_cycles
      ~write_cycles
      ~icache
      ?lines_log2
      ~write_update
      ~video
      ~fb_bram
      ~write_buffer
      ?wbuf_depth
      ~fast_mul
      ~mul_stages
      { Soc.I.clock = i.clock
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
  Signal.assign dq m.mem_dq_i;
  { O.sclk = soc.sclk; hsync = soc.hsync; vsync = soc.vsync; rgb = soc.rgb }
;;

let read_word ~cram_lo ~cram_hi w =
  let bl k = Cyclesim.Memory.to_int cram_lo ~address:k in
  let bh k = Cyclesim.Memory.to_int cram_hi ~address:k in
  bl (2 * w)
  lor (bh (2 * w) lsl 8)
  lor (bl ((2 * w) + 1) lsl 16)
  lor (bh ((2 * w) + 1) lsl 24)
;;
