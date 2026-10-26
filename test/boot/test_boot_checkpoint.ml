(* The boot-handoff checkpoint on the simulation SoC.

   The SoC boots the real disk image — the SD card played by {!Boot.Sd_bridge} — to the OS
   handoff, where PC leaves the boot ROM for low RAM. The loaded image and the
   architectural state are then compared with the oracle's after booting the same disk.
   They must agree exactly, apart from return addresses saved while running from the ROM,
   which differ by the constant offset between the two ROM bases. *)

open Hardcaml
module Soc = Risc5.Soc
module Sim = Cyclesim.With_interface (Soc.I) (Soc.O)

let soc_cycle_cap = 30_000_000

(* SPI_DIV_LOG2 sets the slow SPI divider depth (6 = SPI.v's clk/64; 2 boots about four
   times faster, most boot cycles being spent waiting on slow SPI transfers) *)
let spi_slow_div_log2 = Option.map int_of_string (Sys.getenv_opt "SPI_DIV_LOG2")

let run_soc_to_handoff () =
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Soc.create ~contents:Risc5.Rom.bootloader ?spi_slow_div_log2)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  Boot.Tb.run_to_handoff
    ~sim
    ~miso:inp.miso
    ~sclk:outp.sclk
    ~reset:(fun () ->
      inp.rst_n := lo;
      inp.miso := hi;
      Cyclesim.cycle sim;
      inp.rst_n := hi)
    ~cap:soc_cycle_cap
    ~ram:(fun () ->
      let lanes =
        Array.init 4 (fun k -> Boot.Tb.lookup_mem sim (Printf.sprintf "ram%d" k))
      in
      fun w ->
        let b k = Cyclesim.Memory.to_int lanes.(k) ~address:w in
        (b 3 lsl 24) lor (b 2 lsl 16) lor (b 1 lsl 8) lor b 0)
    ()
;;

let () =
  Boot.Checkpoint.run
    ~run_soc_to_handoff
    ~pass_msg:
      "CHECKPOINT PASS — SoC boots the real disk to the OS handoff (pc=0); loaded image \
       + architectural state match the oracle, modulo the ROM code-address skew."
;;
