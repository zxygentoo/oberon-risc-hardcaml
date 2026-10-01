(* Public API and behaviour spec live in [cellram_model.mli]. A two-byte-lane memory (twin
   of lib/[ram.ml], but 16-bit) modelling the external cellular PSRAM for Cyclesim
   testbenches. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; mem_adr : 'a [@bits 23]
    ; mem_dq_o : 'a [@bits 16]
    ; mem_dq_t : 'a [@bits 1]
    ; ce_n : 'a [@bits 1]
    ; oe_n : 'a [@bits 1]
    ; we_n : 'a [@bits 1]
    ; ub_n : 'a [@bits 1]
    ; lb_n : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { mem_dq_i : 'a [@bits 16] } [@@deriving hardcaml]
end

(* what the data pins carry when nothing is legitimately driving them — one value per
   lane, chosen to be unlikely as real data, so a consumer that samples an undriven bus
   shows up *)
let poison_lo = 0xAD
let poison_hi = 0xBA

(* [addr_bits] halfword-address bits are backed (default 19 = the faithful 1 MB window; the
   real chip is 23 = 16 MiB). Boot / golden sims keep the default — the OS only drives the
   low 1 MB, so a 1 MB model is exact and cheap; himem tests (DOOM.md §3) raise it to reach
   [1 MB, 16 MB). Addresses above the backed span alias down (the top [23 - addr_bits] bits
   are dropped) — harmless, since a smaller model is only used where no such address arises. *)
let create
  ?(addr_bits = 19)
  ?(read_access_cycles = 1)
  ?(write_access_cycles = 1)
  ?(write_pulse_cycles = 1)
  (i : _ I.t)
  : _ O.t
  =
  List.iter
    [ "read_access_cycles", read_access_cycles
    ; "write_access_cycles", write_access_cycles
    ; "write_pulse_cycles", write_pulse_cycles
    ]
    ~f:(fun (name, n) ->
      if n < 1 || n > 15
      then failwith (Printf.sprintf "Cellram_model: %s must be in 1..15, got %d" name n));
  let spec = Reg_spec.create () ~clock:i.clock in
  let depth = 1 lsl addr_bits in
  let zero_init = Array.create ~len:depth (Bits.of_unsigned_int ~width:8 0) in
  let hw_adr = select i.mem_adr ~high:(addr_bits - 1) ~low:0 in
  (* how long the access has been set up: [same] marks a cycle that repeats the previous
     one's address and byte-lane selection with the chip selected throughout, so an access
     whose address has been on the pins for [n] cycles, this one included, shows a run of
     [n - 1]. *)
  let setup = i.mem_adr @: i.ub_n @: i.lb_n in
  let prev_setup = reg spec setup in
  let prev_ce_n = reg spec ~initialize_to:Bits.vdd i.ce_n in
  let same = ~:(i.ce_n) &: ~:prev_ce_n &: (setup ==: prev_setup) in
  (* cycles [run] has held up to and including this one (saturating at 16) *)
  let run_length ~run =
    let before =
      reg_fb spec ~width:4 ~f:(fun c -> mux2 run (mux2 (c ==:. 15) c (c +:. 1)) (zero 4))
    in
    mux2 run (uresize before ~width:5 +:. 1) (zero 5)
  in
  let held_at_least n = run_length ~run:same >=:. n - 1 in
  (* the write strobe, and how many cycles it has been low *)
  let we = ~:(i.ce_n) &: ~:(i.we_n) in
  let we_low = run_length ~run:we in
  (* a write commits once the address/CE/lanes have been valid and WE# low for long enough
     (the chip latches at end-of-write; committing on every qualifying cycle is the same
     thing, the data being held). The controller must be driving the data pins: with the
     pins tristated the chip latches whatever floats there. *)
  let commit =
    we &: held_at_least write_access_cycles &: (we_low >=:. write_pulse_cycles)
  in
  let lane ~name ~lo ~hi ~lane_en ~poison =
    let poison = of_unsigned_int ~width:8 poison in
    let write_port =
      { Write_port.write_clock = i.clock
      ; write_address = hw_adr
      ; write_enable = commit &: lane_en
      ; write_data = mux2 i.mem_dq_t poison (select i.mem_dq_o ~high:hi ~low:lo)
      }
    in
    let stored =
      (multiport_memory
         depth
         ~name
         ~initialize_to:zero_init
         ~write_ports:[| write_port |]
         ~read_addresses:[| hw_adr |]).(0)
    in
    (* the chip drives a lane only when selected for a read with that lane enabled, and
       the word is there only after the access time; the controller must have released the
       pins *)
    let driven =
      ~:(i.ce_n)
      &: ~:(i.oe_n)
      &: i.we_n
      &: lane_en
      &: i.mem_dq_t
      &: held_at_least read_access_cycles
    in
    mux2 driven stored poison
  in
  let lo_byte = lane ~name:"cram_lo" ~lo:0 ~hi:7 ~lane_en:~:(i.lb_n) ~poison:poison_lo in
  let hi_byte = lane ~name:"cram_hi" ~lo:8 ~hi:15 ~lane_en:~:(i.ub_n) ~poison:poison_hi in
  { O.mem_dq_i = hi_byte @: lo_byte }
;;
