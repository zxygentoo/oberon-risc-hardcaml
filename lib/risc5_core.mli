(** [Risc5_core] — the RISC5 CPU core ([RISC5.v]): the single-issue, mostly-one-cycle
    processor at the heart of the machine (AGENT.md §2's "crown jewel").

    The whole CPU is a handful of registers — [PC], [IR], the flags [N]/[Z]/[C]/[OV], the
    aux register [H], the load/store [stallL1], and the interrupt state — updated in a
    single [always @(posedge clk)] block, wrapped in a cloud of combinational logic that
    computes their next values. Per AGENT.md §2 we mirror that sequential skeleton exactly
    (the registers and their stall/interrupt timing are the spec the oracle pins to and
    synthesis preserves) and are idiomatic Hardcaml in the combinational datapath.

    The datapath is the classic "compute everything, then mux": operands [B]/[C1] fan out
    to all the arithmetic units ({!Alu}, the shifters, {!Multiplier}/{!Divider}, the FP
    units) every cycle, and the result mux selects one by the [op] field. A multi-cycle
    unit holds the core by asserting [stall], which freezes [PC] and [IR] (re-presenting
    the same instruction) and gates the register write until the final cycle.

    The core is assembled across Phase 4 in vertical slices, each ending at a green
    instruction-lockstep milestone against [Oracle.Risc] (AGENT.md §6): the fetch/decode
    spine, then register ALU ops, the multi-cycle units, branches, load/store, and
    interrupts. The ports below are the final SoC-facing interface throughout. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a (** clock; the core's state registers update on each rising edge *)
    ; rst_n : 'a
    (** reset ([RISC5.v]'s [rst]), active LOW — pulls [PC] to [StartAdr] while held at 0.
        The [_n] spelling is also load-bearing: a port named exactly [rst]/[reset]/[clear]
        is reserved by the simulation's clock/reset domain, which silently mis-traces it
        in waveforms (the logic is unaffected; the rendered row lies). *)
    ; irq : 'a (** interrupt request (level; edge-detected internally) *)
    ; stall_x : 'a (** external stall ([stallX]) — the video controller's DMA hold *)
    ; inbus : 'a (** data read bus — [Mem]/MMIO read data for loads *)
    ; codebus : 'a (** instruction fetch bus (= [Mem[adr]]) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { adr : 'a
    (** 24-bit byte address: the instruction fetch address, or a load/store data address
        while [stallL0] *)
    ; rd : 'a (** read strobe (load cycle) *)
    ; wr : 'a (** write strobe (store cycle) *)
    ; ben : 'a (** byte enable — byte vs word access *)
    ; outbus : 'a (** data write bus — store data *)
    ; mem_pend : 'a
    (** board seam: high when the core needs the bus this cycle (a fetch, or a load/store
        data access); low ⟺ a pure compute stall (an iterative unit grinding). The board's
        PSRAM arbiter reads it to time its accesses and the [ce] freeze; the sim SoC
        ignores it. *)
    }
  [@@deriving hardcaml]
end

(** [create] builds the CPU core: the state registers updated in one synchronous block,
    and the combinational decode / datapath / control logic that feeds them. The real
    synthesizable core, with the submodules inlined.

    [?ce] is the board clock-enable (default [vdd]). Driven low it freezes every state
    register, the register-file write and all five iterative units together, so a
    multi-cycle PSRAM access looks single-cycle to the core (the board memory seam;
    AGENT.md §3). The default leaves the core byte-identical to the bare RTL port — the
    sim SoC never drives it.

    [?fast_mul] (default [false], Phase 9 — AGENT.md §5) swaps the iterative 33-cycle
    multiplier for the combinational DSP {!Multiplier.create_opt} (proven bit-identical
    via the differential qcheck) through the {!Units} seam; the default keeps the
    faithful, Phase-8-proven unit. Everything else is unchanged. *)
val create : ?ce:Signal.t -> ?fast_mul:bool -> Signal.t I.t -> Signal.t O.t

(** The eight submodule constructors the core wires up — the modules [RISC5.v]
    instantiates (the ALU's [aluRes] is inline there, so it is {e not} here and is proven
    as part of the glue). Made injectable so the Phase-8 in-situ core proof (test/formal)
    can swap the real units for black-box stubs and prove the glue — decode, the inline
    ALU, control, flags, the 13 state registers — with the units assumed-equivalent (each
    proven separately, §6). *)
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

  (** the real synthesizable units (each module's own [create]), at the default
      [ce = vdd]. *)
  val default : t
end

(** [create_with_units ?ce ~units] is [create] parameterized over the submodules — for the
    formal black-box assembly, which passes [Instantiation] stubs (and leaves [?ce] =
    [vdd]). [?ce] gates the core's own state registers and the register-file write; the
    iterative [units] passed in are expected to already carry [ce] (the synthesizable
    {!create} threads it into both). *)
val create_with_units : ?ce:Signal.t -> units:Units.t -> Signal.t I.t -> Signal.t O.t
