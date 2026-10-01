(** The Cyclesim-side half shared by the four boot gates (both checkpoints, both visual
    goldens): loud by-name lookups, the SPI/SD-card tick, and the run-to-handoff driver.
    SoC-independent — both SoCs expose the same register/memory names; each gate supplies
    its sim construction, reset preamble, and RAM readback as closures. The Hardcaml-free
    halves are {!Disk}, {!Oracle}, {!Checkpoint} and {!Golden}. *)

open Hardcaml

(** a SoC word pc below this has left the ROM-decode region for low RAM — the OS handoff *)
val rom_region_base : int

(** by-name lookups that fail loudly — a silent [None] would read as zeros (AGENT.md §6) *)
val lookup_reg : ('i, 'o) Cyclesim.t -> string -> Cyclesim.Reg.t

val lookup_mem : ('i, 'o) Cyclesim.t -> string -> Cyclesim.Memory.t

(** node-or-reg lookup — plain node lookup misses registers (AGENT.md §6) *)
val lookup_node : ('i, 'o) Cyclesim.t -> string -> Cyclesim.Node.t

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

  (** the tick's halves, for split-phase harnesses that own their clock edge (core_dump's
      pre-edge capture): [set_miso] before the edge, [step] after *)
  val set_miso : t -> unit

  val step : t -> unit
end

(** [scan_frame sim ~tick ~rgb] runs one full raster frame of [tick]s and rebuilds the
    framebuffer from what actually leaves the [rgb] pins (raster position read from the
    [hcnt]/[vcnt] registers). Returns the image, in {!Golden}'s framebuffer layout, and
    the number of lit pixels seen {e outside} the visible window (blanking must be dark).
    The goldens compare it to the framebuffer memory they hashed, which puts the whole
    scan-out path — fetch, shadow read port, display-mode mux, shifter — under the gate. *)
val scan_frame
  :  ('i, 'o) Cyclesim.t
  -> tick:(unit -> unit)
  -> rgb:Bits.t ref
  -> int array * int

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
  -> Checkpoint.snapshot option
