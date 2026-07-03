(* Public API and behaviour spec live in [cellram_model.mli]. A two-byte-lane memory (twin
   of lib/[ram.ml], but 16-bit) modelling the external cellular PSRAM for Cyclesim
   testbenches. *)

open! Base
open Hardcaml
open Signal

let depth = 1 lsl 19 (* 2^19 halfwords = 1 MB window *)
let zero_init = Array.create ~len:depth (Bits.of_unsigned_int ~width:8 0)

module I = struct
  type 'a t =
    { clock : 'a
    ; mem_adr : 'a [@bits 23]
    ; mem_dq_o : 'a [@bits 16]
    ; ce_n : 'a [@bits 1]
    ; we_n : 'a [@bits 1]
    ; ub_n : 'a [@bits 1]
    ; lb_n : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { mem_dq_i : 'a [@bits 16] } [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let hw_adr = select i.mem_adr ~high:(19 - 1) ~low:0 in
  let write = ~:(i.ce_n) &: ~:(i.we_n) in
  let lane ~name ~lo ~hi ~lane_en =
    let write_port =
      { Write_port.write_clock = i.clock
      ; write_address = hw_adr
      ; write_enable = write &: lane_en
      ; write_data = select i.mem_dq_o ~high:hi ~low:lo
      }
    in
    (multiport_memory
       depth
       ~name
       ~initialize_to:zero_init
       ~write_ports:[| write_port |]
       ~read_addresses:[| hw_adr |]).(0)
  in
  let lo_byte = lane ~name:"cram_lo" ~lo:0 ~hi:7 ~lane_en:~:(i.lb_n) in
  let hi_byte = lane ~name:"cram_hi" ~lo:8 ~hi:15 ~lane_en:~:(i.ub_n) in
  { O.mem_dq_i = hi_byte @: lo_byte }
;;
