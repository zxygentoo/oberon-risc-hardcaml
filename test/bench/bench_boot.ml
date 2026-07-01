(* Phase-9 end-to-end bench (AGENT.md §5) — boot the *real memory path* (the PSRAM board
   SoC) to the OS handoff and count TOTAL cycles, to place the DSP-multiplier and clock
   wins in the context that actually matters: the whole machine, wait-states and all.

   The other two gauges look at compute in isolation — bench_core times one op
   (memoryless), profile_boot counts MUL/DIV density on the oracle (no memory model). This
   one runs {!Nexys4_board.Soc_board}: the core on a clock-enable, main memory behind
   {!Cellram} inserting [read_cycles]/[write_cycles] wait-states per access, driven from
   the real disk through the SD bridge. Two questions:

   1. Does the DSP multiplier move end-to-end cycles? Boot faithful vs [fast_mul] at the
      board's read_cycles=5. Expect ~nil — boot is 0.1% MUL (profile_boot), dominated by
      the SD-copy + PSRAM traffic.

   2. How memory-bound is it? Sweep read_cycles 2 -> 5. Every memory access costs its
      wait-states, so the extra cycles are *pure* PSRAM wait: (C5 - C2) = 3 * accesses,
      and ~rc * accesses is the wait-state overhead at that latency. That fraction is the
      ceiling a cache could reclaim — the number that says whether the next win is compute
      or memory.

   Standalone report (no pass/fail); run: dune build @bench_boot. *)

open Hardcaml
open Boot_checkpoint_common
module Soc_board = Nexys4_board.Soc_board
module Cellram_model = Nexys4_board.Cellram_model

(* The board SoC closed with the behavioural cellular-RAM on its pins — same wiring as the
   board boot checkpoint, but [create] is parameterised by the knobs we sweep: [fast_mul]
   / [mul_stages] (the DSP multiplier variant) and [read_cycles] / [write_cycles] (the
   PSRAM latency). Only [sclk] is read directly (for the SD bridge); the rest go by name. *)
module Tb = struct
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
    type 'a t = { sclk : 'a [@bits 1] } [@@deriving hardcaml]
  end

  let create ~contents ~fast_mul ~mul_stages ~read_cycles ~write_cycles (i : _ I.t)
    : _ O.t
    =
    let dq = Signal.wire 16 in
    let soc =
      Soc_board.create
        ~contents
        ~read_cycles
        ~write_cycles
        ~fast_mul
        ~mul_stages
        { Soc_board.I.clock = i.clock
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
    { O.sclk = soc.sclk }
  ;;
end

module Sim = Cyclesim.With_interface (Tb.I) (Tb.O)

let cycle_cap = 80_000_000

(* boot to the OS handoff; return the cycle count (or None if it never leaves the ROM) *)
let boot_cycles ~fast_mul ~mul_stages ~read_cycles ~write_cycles =
  let tmp = copy_to_temp disk_image in
  let bridge = Sd_bridge.create (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp))) in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create
         ~contents:Oracle.Boot_rom.bootloader
         ~fast_mul
         ~mul_stages
         ~read_cycles
         ~write_cycles)
  in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let some w = function
    | Some x -> x
    | None -> failwith ("lookup: " ^ w ^ " not found")
  in
  let reg n = some n (Cyclesim.lookup_reg_by_name sim n) in
  let pc = reg "pc"
  and rdy = reg "rdy"
  and shreg = reg "spi_shreg"
  and spi_ctrl = reg "spi_ctrl" in
  let lo = Bits.of_unsigned_int ~width:1 0
  and hi = Bits.of_unsigned_int ~width:1 1 in
  inp.rxd := hi;
  inp.ps2c := hi;
  inp.ps2d := hi;
  inp.msclk := hi;
  inp.msdat := hi;
  inp.rst_n := lo;
  inp.miso := hi;
  Cyclesim.cycle sim;
  inp.rst_n := hi;
  let cycle = ref 0
  and handoff = ref false in
  while (not !handoff) && !cycle < cycle_cap do
    inp.miso := if Sd_bridge.miso bridge = 1 then hi else lo;
    Cyclesim.cycle sim;
    let ctrl = Cyclesim.Reg.to_int spi_ctrl in
    Sd_bridge.step
      bridge
      ~sclk:(Bits.to_unsigned_int !(outp.sclk))
      ~rdy:(Cyclesim.Reg.to_int rdy)
      ~data_tx:(Cyclesim.Reg.to_int shreg)
      ~fast:((ctrl lsr 2) land 1 = 1)
      ~selected:(ctrl land 3 = 1);
    if Cyclesim.Reg.to_int pc < rom_region_base then handoff := true;
    incr cycle
  done;
  rm_temp tmp;
  if !handoff then Some !cycle else None
;;

let must = function
  | Some c -> c
  | None -> failwith "no handoff within the cycle cap"
;;

let () =
  Printf.printf
    "Phase-9 end-to-end bench — PSRAM board SoC, reset -> OS handoff, total cycles\n\n%!";
  Printf.printf "  booting (faithful mul, read_cycles=5) ...\n%!";
  let f5 =
    must (boot_cycles ~fast_mul:false ~mul_stages:0 ~read_cycles:5 ~write_cycles:5)
  in
  Printf.printf "  booting (DSP fast_mul mul_stages:2, read_cycles=5) ...\n%!";
  let x5 =
    must (boot_cycles ~fast_mul:true ~mul_stages:2 ~read_cycles:5 ~write_cycles:5)
  in
  Printf.printf "  booting (faithful mul, read_cycles=2) ...\n%!";
  let f2 =
    must (boot_cycles ~fast_mul:false ~mul_stages:0 ~read_cycles:2 ~write_cycles:2)
  in
  (* rc only touches PSRAM accesses, so the rc 2->5 delta is *pure* wait: +3 cycles per
     half-word, so (C5 - C2) / 3 = half-word accesses and ~rc * that = the wait at that
     latency. The SoC's instruction count isn't observed (it re-polls the slow SPI far
     more than the oracle), so we quote no CPI — the rc-delta is denominator-free, the
     honest memory number. *)
  let halfword_accesses = (f5 - f2) / 3 in
  let wait5 = 5 * halfword_accesses in
  let pct x tot = 100.0 *. float_of_int x /. float_of_int tot in
  Printf.printf "\n  DSP multiplier, end-to-end (read_cycles=5, the board latency):\n";
  Printf.printf "    faithful : %d cycles\n" f5;
  Printf.printf "    fast_mul : %d cycles\n" x5;
  Printf.printf
    "    gain     : %+.2f%%  (%d cycles)  — boot is 0.1%% MUL, so ~nil, as Amdahl predicts\n"
    (pct (f5 - x5) f5)
    (f5 - x5);
  Printf.printf "\n  PSRAM wait-states (faithful mul), from the read_cycles sweep:\n";
  Printf.printf "    read_cycles=2 : %d cycles\n" f2;
  Printf.printf "    read_cycles=5 : %d cycles\n" f5;
  Printf.printf
    "    +3 wait/access delta = %d cycles (%.1f%% of the rc=5 boot); ~%d half-word \
     accesses\n\
    \    => ~%d cycles = ~%.0f%% of the rc=5 boot spent in PSRAM latency\n"
    (f5 - f2)
    (pct (f5 - f2) f5)
    halfword_accesses
    wait5
    (pct wait5 f5);
  Printf.printf
    "\n\
    \  Read-off. The DSP mul (17x per-op) is Amdahl-capped to ~nil end-to-end. ~%.0f%% \
     of boot\n\
    \  cycles are PSRAM wait — and that UNDERSTATES the running OS: boot fetches code \
     from the\n\
    \  on-chip ROM fast-path, but post-handoff every instruction fetch is a PSRAM read, \
     so the\n\
    \  live system is more memory-bound still. The broad win already banked is the \
     50->60 MHz\n\
    \  clock (1.2x, on compute AND memory); the next real lever is memory latency — an \
     I-cache /\n\
    \  wider PSRAM — not more compute. See test/bench/README.md.\n\
     %!"
    (pct wait5 f5)
;;
