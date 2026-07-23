(** The Cyclesim-side half shared by the four boot gates (both checkpoints, both visual
    goldens): loud by-name lookups, the SPI/SD-card tick, and the run-to-handoff driver.
    SoC-independent — both SoCs expose the same register/memory names; each gate supplies
    its sim construction, reset preamble, and RAM readback as closures. The Hardcaml-free
    half is {!Boot_checkpoint_common}. *)

open Hardcaml

(** by-name lookups that fail loudly — a silent [None] would read as zeros (AGENT.md §6) *)
val lookup_reg : ('i, 'o) Cyclesim.t -> string -> Cyclesim.Reg.t

val lookup_mem : ('i, 'o) Cyclesim.t -> string -> Cyclesim.Memory.t

(** the packed N/Z/C/OV flags word (Z | N<<1 | C<<2 | V<<3), as the oracle reads it *)
val flags_word : ('i, 'o) Cyclesim.t -> int

(** The test-side SD card on the SoC's SPI pins: {!Sd_bridge} plus the sim handles it is
    driven from. *)
module Spi : sig
  type t

  (** [attach sim ~miso ~sclk bridge] binds the SPI handles by name ([rdy] / [spi_shreg] /
      [spi_ctrl]); [miso]/[sclk] are the SoC's input/output ports. *)
  val attach
    :  ('i, 'o) Cyclesim.t
    -> miso:Bits.t ref
    -> sclk:Bits.t ref
    -> Sd_bridge.t
    -> t

  (** one sim cycle with the SD card on the wire: present miso, cycle, advance the bridge *)
  val tick : ('i, 'o) Cyclesim.t -> t -> unit
end

(** [run_to_handoff ~sim ~miso ~sclk ~reset ~cap ~ram ()] boots [sim] from the real disk
    to the OS handoff and snapshots the architectural state ([None] if pc never leaves the
    ROM region within [cap] cycles — reported either way). [reset] is the gate's own reset
    preamble; [ram ()] builds the snapshot's word reader at the handoff. *)
val run_to_handoff
  :  sim:('i, 'o) Cyclesim.t
  -> miso:Bits.t ref
  -> sclk:Bits.t ref
  -> reset:(unit -> unit)
  -> cap:int
  -> ram:(unit -> int -> int)
  -> unit
  -> Boot_checkpoint_common.snapshot option
