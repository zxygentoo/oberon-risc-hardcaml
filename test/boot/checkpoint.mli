(** The boot-handoff checkpoint, Hardcaml-free: a machine's architectural state at the OS
    handoff, the oracle's boot to the same point, and the comparison that tolerates
    exactly the code-address skew of AGENT.md §8. The Cyclesim side — driving a SoC to its
    handoff and taking the snapshot — is {!Tb.run_to_handoff}. *)

(** A machine's architectural state at the OS handoff. *)
type snapshot =
  { pc : int
  ; regs : int array (** R0..R15 *)
  ; flags : int
  ; h : int
  ; ram : int -> int (** word reader, indices 0..0x3FFFF *)
  }

(** [run ~run_soc_to_handoff ~pass_msg] boots the SoC to its handoff (via the supplied
    [run_soc_to_handoff], which returns [None] if it never leaves the ROM), boots the
    oracle on the same disk, and compares the two; prints [pass_msg] on success, and
    [exit 1]s on any divergence or a missing handoff. *)
val run : run_soc_to_handoff:(unit -> snapshot option) -> pass_msg:string -> unit
