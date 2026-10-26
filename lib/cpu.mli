(** The RISC5 CPU core, a port of [RISC5.v].

    The processor is a handful of registers — [PC], [IR], the flags [N]/[Z]/[C]/[OV], the
    auxiliary register [H], the load/store flop [stallL1] and the interrupt state —
    updated in one clocked block, and the combinational logic that computes their next
    values. The registers and their stall and interrupt timing mirror the RTL exactly:
    that is what the equivalence proof and the cycle-level co-simulation hold the core to.
    The combinational datapath is free to be idiomatic.

    The datapath computes everything and then selects: the operands fan out to the ALU,
    the shifters, the multiplier, the divider and the FP units every cycle, and the [op]
    field picks one result. A multi-cycle unit holds the core by asserting [stall], which
    freezes [PC] and [IR] and gates the register write until its last cycle. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; rst_n : 'a
    (** reset ([RISC5.v]'s [rst]), active low: holds [PC] at {!start_adr}. It is not
        called [rst] because the simulator reserves a port named exactly [rst], [reset] or
        [clear] and renders it wrongly in waveforms. *)
    ; irq : 'a (** interrupt request, a level; the core detects its rising edge *)
    ; stall_x : 'a (** external stall ([stallX]): the video controller's DMA hold *)
    ; inbus : 'a (** read data for loads, from memory or a peripheral *)
    ; codebus : 'a (** the instruction at [adr] *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { adr : 'a
    (** 24-bit byte address: the fetch address, or the data address in the first cycle of
        a load or store *)
    ; rd : 'a (** read strobe (a load) *)
    ; wr : 'a (** write strobe (a store) *)
    ; ben : 'a (** the access is a byte, not a word *)
    ; outbus : 'a (** store data *)
    ; mem_pend : 'a
    (** the core needs the bus this cycle, for a fetch or a data access; low only while an
        iterative unit computes. Not in the RTL: a memory controller that stretches
        accesses with [?ce] reads it to know when to. *)
    }
  [@@deriving hardcaml]
end

(** The units behind MUL and FML — the integer {!Multiplier} and the FP {!Fp_multiplier}.
    Every choice computes the same results (the DSP variants are checked against the
    iterative units by differential property tests); they differ in cycles and in what the
    synthesizer builds. *)
type multipliers =
  | Iterative
  (** the shift-add units of [Multiplier.v] and [FPMultiplier.v], 33 and 25 cycles, proven
      equivalent to the RTL *)
  | Dsp of { stages : int }
  (** DSP-block products. With [stages = 0] they are combinational; with [stages = n > 0]
      the product passes through [n] registers, which the synthesizer retimes into the
      DSP48 so that the multiply leaves the critical path, and takes [n] cycles through
      the core's stall. *)

(** [create i] is the synthesizable core.

    [?ce] (default [vdd]) is a clock enable for the whole core: held low it freezes every
    state register, the register-file write and the five iterative units together, so that
    a multi-cycle memory access looks like a single cycle to the core. With the default
    the core is exactly the port of the RTL.

    [?multipliers] defaults to {!Iterative}. *)
val create : ?ce:Signal.t -> ?multipliers:multipliers -> Signal.t I.t -> Signal.t O.t

(** the reset vector ([RISC5.v]'s [StartAdr]) as a word address. A SoC derives its ROM
    window from it ([adr[23:14] = start_adr lsr 12]). *)
val start_adr : int

(** The eight submodules the core instantiates — the ones [RISC5.v] instantiates; the ALU
    is inline there, and so is part of the core here. They are injectable so that the
    formal core proof can replace them with black boxes and prove everything else against
    [RISC5.v], each unit being proven on its own. *)
module Units : sig
  type t =
    { left_shifter : Signal.t Left_shifter.I.t -> Signal.t Left_shifter.O.t
    ; right_shifter : Signal.t Right_shifter.I.t -> Signal.t Right_shifter.O.t
    ; multiplier : Signal.t Multiplier.I.t -> Signal.t Multiplier.O.t
    ; divider : Signal.t Divider.I.t -> Signal.t Divider.O.t
    ; fp_adder : Signal.t Fp_adder.I.t -> Signal.t Fp_adder.O.t
    ; fp_multiplier : Signal.t Fp_multiplier.I.t -> Signal.t Fp_multiplier.O.t
    ; fp_divider : Signal.t Fp_divider.I.t -> Signal.t Fp_divider.O.t
    ; registers : Signal.t Registers.I.t -> Signal.t Registers.O.t
    }

  (** the real units, with no clock enable *)
  val default : t
end

(** [create_with_units ~units i] is {!create} over the given submodules. [?ce] gates the
    core's own registers and the register-file write; the iterative units passed in must
    already carry it. *)
val create_with_units : ?ce:Signal.t -> units:Units.t -> Signal.t I.t -> Signal.t O.t
