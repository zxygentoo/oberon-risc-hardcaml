(** The boot ROM: the 512-word ROM circuit (a port of [PROM.v]) and the boot image it
    holds.

    [PROM.v] registers its read on the falling clock edge, to give block RAM half a cycle
    before the core's rising edge latches [codebus] into [IR]. Here the read is
    combinational. [IR] is the only consumer of [codebus], so it sees the same word at
    every rising edge either way. That argument is all there is behind the choice: the
    circuit has no co-simulation or equivalence check against [PROM.v].

    The image is a parameter. Tests pass hand-assembled programs; the machine passes
    {!bootloader}. The emulator has its own copy of the boot image, and a test
    (test/test_rom.ml) holds the two equal, so the design and its oracle cannot boot
    different ROMs. *)

open Hardcaml

module I : sig
  type 'a t = { adr : 'a (** 9-bit word address (one of the 512 ROM words) *) }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t = { data : 'a (** the 32-bit ROM word at [adr] *) } [@@deriving hardcaml]
end

(** [create ~contents i] is the ROM holding [contents], zero-padded to 512 words; a longer
    array raises [Failure]. *)
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
