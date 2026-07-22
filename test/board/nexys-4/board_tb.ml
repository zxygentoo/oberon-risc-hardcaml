(* Shared board-SoC test harness — a thin veneer over {!Nexys4_board.Soc.For_tests} (the
   SoC + {!Nexys4_board.Cellram_model} closure and the idle-level driver now live there,
   next to the design, shared with its co-located tests). This module keeps the test-side
   conveniences: the [contents] default (the design boot ROM), the full-size PSRAM model
   (the gates load the real disk image), and [read_word] for reconstructing 32-bit words
   from the model's byte lanes. The public contract is in board_tb.mli. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module I = Soc.For_tests.Tb.I
module O = Soc.For_tests.Tb.O

let drive_idle = Soc.For_tests.drive_idle

let create
  ?read_cycles
  ?write_cycles
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
  ?(contents = Risc5.Rom.bootloader)
  (i : _ I.t)
  : _ O.t
  =
  (* addr_bits 19 = the full 1 MiB model — the gates boot the real .dsk into low RAM *)
  Soc.For_tests.Tb.create
    ~contents
    ?read_cycles
    ?write_cycles
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
    ~addr_bits:19
    i
;;

let read_word ~cram_lo ~cram_hi w =
  let bl k = Cyclesim.Memory.to_int cram_lo ~address:k in
  let bh k = Cyclesim.Memory.to_int cram_hi ~address:k in
  bl (2 * w)
  lor (bh (2 * w) lsl 8)
  lor (bl ((2 * w) + 1) lsl 16)
  lor (bh ((2 * w) + 1) lsl 24)
;;
