(** 512×32 boot ROM — a port of [PROM.v].

    [PROM.v] registers its read on the (inverted) clock; we model the pragmatic,
    correct-by-fetch ROM as an {b asynchronous} (combinational) read. That negedge
    register only hands on-chip block RAM half a cycle so [codebus] is ready before the
    CPU's rising edge latches it into [ir] — and [ir] (a posedge register) is [codebus]'s
    sole consumer, so a combinational read presents the identical word at every clock edge
    (AGENT.md §2). The faithful registered/BRAM form is deferred to the Phase-8 cycle
    co-sim.

    The image is a {b parameter} ([~contents]), not read from [prom.mem] here, so the
    design library stays free of the data file and the oracle — the SoC/test supplies it. *)

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
