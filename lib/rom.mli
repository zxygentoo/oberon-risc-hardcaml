(** The RISC5 boot ROM — the 512×32 ROM {e circuit} (a port of [PROM.v]) together with the
    boot {e image} it ships ([bootloader]), making [risc5] a self-contained port of the
    machine.

    [PROM.v] registers its read on the (inverted) clock; we model the pragmatic,
    correct-by-fetch ROM as an {b asynchronous} (combinational) read. That negedge
    register only hands on-chip block RAM half a cycle so [codebus] is ready before the
    CPU's rising edge latches it into [ir] — and [ir] (a posedge register) is [codebus]'s
    sole consumer, so a combinational read presents the identical word at every clock edge
    (AGENT.md §2). This is a modelling choice resting on that argument: the circuit has no
    co-sim or equivalence row against [PROM.v].

    The circuit's image is a {b parameter} ([~contents]), not baked in — the SoC/emit
    chooses: tests feed hand-assembled programs, the real machine feeds [bootloader].
    [Emu.Boot_rom] holds the oracle's own transcription (from the C [risc-boot.inc]) for
    the emulator's internal boot; a guard test (test/test_rom.ml) pins it equal to
    [bootloader], so hardware and oracle can never boot different ROMs. *)

open Hardcaml

module I : sig
  type 'a t = { adr : 'a (** 9-bit word address (one of the 512 ROM words) *) }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t = { data : 'a (** the 32-bit ROM word at [adr] *) } [@@deriving hardcaml]
end

(** [create ~contents i] builds the ROM: [data] = [contents].([i.adr]), an asynchronous
    read. [contents] holds the word image (each value in u32 range); it is zero-padded up
    to the 512-word depth, and a longer array raises [Failure]. *)
val create : contents:int array -> Signal.t I.t -> Signal.t O.t

(** The 512-word boot loader: the 383-word image the Oberon emulators boot (the C
    emulator's [risc-boot.inc], verbatim), zero-filled to the 512-word depth [create]
    maps. Each value is in unsigned-32-bit range.

    This is {e not} the [prom.mem] of the 2018 OberonStation archive the reference Verilog
    comes from: that file is a later build of the same boot loader. The two agree in their
    first 338 words (the SD/serial load procedures); the main body differs in how it
    initialises SP and SB ([MOV SB,#0; MOV' SP,#8] here,
    [MOV' R0,#8; MOV SP,R0; MOV SB,#20H] there), which makes upstream one word longer and
    shifts every call displacement after it — 45 differing words in all. *)
val bootloader : int array
