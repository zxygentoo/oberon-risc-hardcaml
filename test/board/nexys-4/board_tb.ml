(* See board_tb.mli. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module I = Soc.For_tests.Tb.I
module O = Soc.For_tests.Tb.O

let drive_idle = Soc.For_tests.drive_idle

(* addr_bits 19 = the full 1 MiB model — the gates boot the real .dsk into low RAM *)
let create = Soc.For_tests.Tb.create ~contents:Risc5.Rom.bootloader ~addr_bits:19

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
  let shipped_dsp, shipped_stages =
    match s.multipliers with
    | Iterative -> false, 0
    | Dsp { stages } -> true, stages
  in
  let multipliers : Risc5.Cpu.multipliers =
    if env_flag "FAST_MUL" ~default:shipped_dsp
    then Dsp { stages = env_int "MUL_STAGES" ~default:shipped_stages }
    else if Option.is_some (Sys.getenv_opt "MUL_STAGES")
    then failwith "MUL_STAGES needs the DSP multipliers (FAST_MUL=1)"
    else Iterative
  in
  let wbuf = env_int "WBUF" ~default:(if s.write_buffer then s.wbuf_depth else 0) in
  { s with
    icache = env_flag "ICACHE" ~default:s.icache
  ; lines_log2 = env_int "LINES_LOG2" ~default:s.lines_log2
  ; write_update = env_flag "WRITE_UPDATE" ~default:s.write_update
  ; fb_bram = env_flag "FB_BRAM" ~default:s.fb_bram
  ; halftone = env_flag "HALFTONE" ~default:s.halftone
  ; write_buffer = wbuf >= 1
  ; wbuf_depth = max 1 wbuf
  ; multipliers
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
