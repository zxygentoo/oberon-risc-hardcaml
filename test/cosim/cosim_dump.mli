(* The few helpers every co-simulation dumper repeats. Each dumper keeps its own reset and
   transfer loop: its protocol is its own. *)

open Hardcaml

(** Poke an input ref to [v] using the ref's own declared width — so one call serves a
    1-bit strobe or a 32-bit data word alike. *)
val set : Bits.t ref -> int -> unit

(** Read an output ref as a plain (truncating) int. *)
val rd : Bits.t ref -> int

(** The hex digit ['0'..'F'] for the low 4 bits of [n] — the dumpers pack a cycle's driven
    inputs + checked outputs into one digit, and the matching .cpp unpacks the same bits. *)
val hex_digit : int -> char

(** A uniform 32-bit draw from [rng] (two 16-bit draws OR-ed). The dumpers' fuzz passes
    use it for breadth; any 32-bit pattern is a valid port-vs-RTL stimulus. *)
val rand32 : Random.State.t -> int
