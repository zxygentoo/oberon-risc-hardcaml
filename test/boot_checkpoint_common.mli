(** Shared half of the boot-handoff checkpoints — the Phase-5 BRAM [test_boot_checkpoint]
    and the Phase-7 PSRAM [test_boot_checkpoint_board] (AGENT.md §6 layer 5).

    Everything here is independent of the SoC's Hardcaml interface: the disk image, the
    oracle boot, the §8-aware differential compare, and the top-level {!run} driver. Each
    checkpoint supplies only its own [run_soc_to_handoff] — the interface-specific
    Cyclesim setup and RAM read (the BRAM's four byte lanes vs the PSRAM model's two
    halfword lanes). *)

(** A machine's architectural state at the OS handoff, for differential comparison. *)
type snapshot =
  { pc : int
  ; regs : int array (** R0..R15 *)
  ; flags : int
  ; h : int
  ; ram : int -> int (** word reader, indices 0..0x3FFFF *)
  }

(** the real Oberon disk image, resolved from the project root so it works from any cwd *)
val disk_image : string

(** copy [src] to a fresh temp file (the boot mutates the disk); [rm_temp] removes it *)
val copy_to_temp : string -> string

val rm_temp : string -> unit

(** a SoC word pc below this has left the ROM-decode region for low RAM — the OS handoff *)
val rom_region_base : int

(** [run ~run_soc_to_handoff ~pass_msg] boots the SoC to its handoff (via the supplied
    [run_soc_to_handoff], which returns [None] if it never leaves the ROM), boots the
    OCaml oracle on the same disk, and §8-compares the two; prints [pass_msg] on success,
    and [exit 1]s on any divergence or a missing handoff. *)
val run : run_soc_to_handoff:(unit -> snapshot option) -> pass_msg:string -> unit
