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

let create_config =
  Soc.For_tests.Tb.create_config ~contents:Risc5.Rom.bootloader ~addr_bits:19
;;

module Build_config = Nexys4_board.Build_config

(* Environment overrides are strict: a typo must fail, not silently run the default. *)
let env_flag name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some "0" -> false
  | Some "1" -> true
  | Some s -> failwith (Printf.sprintf "%s must be 0 or 1, got %S" name s)
;;

let env_int name ~default =
  match Sys.getenv_opt name with
  | None -> default
  | Some s ->
    (match int_of_string_opt s with
     | Some n -> n
     | None -> failwith (Printf.sprintf "%s must be an integer, got %S" name s))
;;

let config_of_env () =
  let s = Build_config.shipped in
  let fast_mul = env_flag "FAST_MUL" ~default:s.fast_mul in
  let wbuf = env_int "WBUF" ~default:(if s.write_buffer then s.wbuf_depth else 0) in
  { s with
    icache = env_flag "ICACHE" ~default:s.icache
  ; lines_log2 = env_int "LINES_LOG2" ~default:s.lines_log2
  ; write_update = env_flag "WRITE_UPDATE" ~default:s.write_update
  ; fb_bram = env_flag "FB_BRAM" ~default:s.fb_bram
  ; halftone = env_flag "HALFTONE" ~default:s.halftone
  ; write_buffer = wbuf >= 1
  ; wbuf_depth = max 1 wbuf
  ; fast_mul
  ; mul_stages = (if fast_mul then env_int "MUL_STAGES" ~default:s.mul_stages else 0)
  ; spi_slow_div_log2 = env_int "SPI_DIV_LOG2" ~default:s.spi_slow_div_log2
  ; read_cycles = env_int "READ_CYCLES" ~default:s.read_cycles
  ; write_cycles = env_int "WRITE_CYCLES" ~default:s.write_cycles
  }
;;

let read_word ~cram_lo ~cram_hi w =
  let bl k = Cyclesim.Memory.to_int cram_lo ~address:k in
  let bh k = Cyclesim.Memory.to_int cram_hi ~address:k in
  bl (2 * w)
  lor (bh (2 * w) lsl 8)
  lor (bl ((2 * w) + 1) lsl 16)
  lor (bh ((2 * w) + 1) lsl 24)
;;
