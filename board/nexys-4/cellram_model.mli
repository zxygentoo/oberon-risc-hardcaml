(** A behavioural model of the PSRAM chip, for simulation only: the real chip is outside
    the FPGA.

    Wired to {!Cellram}'s pins it closes the loop in a testbench. Two 8-bit lanes
    ([cram_lo], [cram_hi]) share the halfword address, so that a byte store touches only
    its lane. It backs [2^addr_bits] halfwords, initially zero: 2^19 by default, which is
    Oberon's 1 MiB; the chip has 2^23.

    It answers only what a real chip would. A lane of [mem_dq_i] carries the stored byte
    only while the chip is selected for a read ([ce_n] and [oe_n] low, [we_n] high), that
    lane is enabled, the controller has released the data pins ([mem_dq_t] high) and the
    address has been held for the access time; otherwise it carries a poison byte. A write
    commits only with [ce_n] and [we_n] low for the pulse width and the address held for
    the write access time, and stores poison if the controller is not driving the pins.

    The three timing figures are in clocks and default to 1: a chip that answers at once,
    for tests of the controller's control flow. A caller that knows the clock period
    passes the datasheet's figures rounded up (the -70 part: 70 ns from address, CE# or
    byte enable, for reads and for writes, and a 45 ns write pulse). *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; mem_adr : 'a
    (** halfword address (only the low [addr_bits] bits index the window) *)
    ; mem_dq_o : 'a (** 16-bit write data from the controller *)
    ; mem_dq_t : 'a (** the controller's tristate control: 1 = pins released (reading) *)
    ; ce_n : 'a
    ; oe_n : 'a
    ; we_n : 'a
    ; ub_n : 'a (** upper byte lane enable, active low *)
    ; lb_n : 'a (** lower byte lane enable, active low *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t = { mem_dq_i : 'a (** 16-bit read data to the controller (combinational) *) }
  [@@deriving hardcaml]
end

(** [read_access_cycles]: cycles the address, [ce_n] and the lane enables must have been
    held, counting the sampling cycle, before read data is valid. [write_access_cycles]:
    the same hold before a write commits. [write_pulse_cycles]: cycles [we_n] must have
    been low. All default to [1]; each must be in 1..15. *)
val create
  :  ?addr_bits:int
  -> ?read_access_cycles:int
  -> ?write_access_cycles:int
  -> ?write_pulse_cycles:int
  -> Signal.t I.t
  -> Signal.t O.t
