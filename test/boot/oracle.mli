(** The reference machine of the boot gates: the OCaml emulator, wired the way its own
    frontend wires it. *)

(** a fresh oracle with PCLink serial, a no-op clipboard and the disk at [disk] — the
    configuration that produced the goldens *)
val create : disk:string -> Emu.Risc.t
