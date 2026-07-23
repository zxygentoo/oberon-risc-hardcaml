(* Shared board-SoC test harness — a thin veneer over {!Nexys4_board.Soc.For_tests} (the
   SoC + {!Nexys4_board.Cellram_model} closure and the idle-level driver live there, next
   to the design, shared with its co-located tests). This module pins the test-side
   configuration — the design boot ROM and the full-size PSRAM model (the gates load the
   real disk image) — and keeps [read_word] for reconstructing 32-bit words from the
   model's byte lanes. The public contract is in board_tb.mli. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module I = Soc.For_tests.Tb.I
module O = Soc.For_tests.Tb.O

let drive_idle = Soc.For_tests.drive_idle

(* addr_bits 19 = the full 1 MiB model — the gates boot the real .dsk into low RAM; every
   other knob of {!Soc.For_tests.Tb.create} stays open and forwards by label. *)
let create = Soc.For_tests.Tb.create ~contents:Risc5.Rom.bootloader ~addr_bits:19

let read_word ~cram_lo ~cram_hi w =
  let bl k = Cyclesim.Memory.to_int cram_lo ~address:k in
  let bh k = Cyclesim.Memory.to_int cram_hi ~address:k in
  bl (2 * w)
  lor (bh (2 * w) lsl 8)
  lor (bl ((2 * w) + 1) lsl 16)
  lor (bh ((2 * w) + 1) lsl 24)
;;
