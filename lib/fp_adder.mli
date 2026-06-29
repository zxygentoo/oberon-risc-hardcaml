(** [Fp_adder] — pipelined IEEE-754 single-precision add/subtract, plus the [FLT] and
    [FLOOR] conversions; the RISC5 [FAD]/[FSB]/[FLT]/[FLOOR] unit.

    A faithful port of Oberon's [FPAdder.v]: a 3-stage pipeline that aligns, adds, and
    re-normalizes two floats over four states, holding the core with [stall] until its
    state counter reaches the terminal value. Unlike the iterative {!Multiplier}/
    {!Divider}, the latency is a fixed 3 register stages, not a data-independent step
    count.

    {1 Number format}

    IEEE-754 single precision: [{sign:1, exp:8 (bias 127), frac:23}], value
    [(-1)^sign * 2^(exp-127) * 1.frac] with the leading [1.] implicit. Zero is all-bits-0
    (ignoring sign). Internally the mantissa carries the restored hidden bit and a low
    guard bit for round-to-nearest.

    {1 Timing}
    (mirrored exactly from the RTL — AGENT.md §2)

    [run] is asserted by the core while the op is decoded, and doubles as enable {e and}
    synchronous clear: while [run] is low the 2-bit [State] counter is pinned at 0, so the
    next op starts from a clean fill — there is no reset. Once [run] asserts, [State]
    walks 0->3: the three pipeline registers fill on the edges ending States 0/1/2, and at
    [State=3] [stall] drops with [z] valid. Thus [stall = run & ~(State==3)], and the core
    keeps PC/IR frozen for the whole run.

    Because the operand signs, the result exponent, and the null flags are combinational
    off the {e current} [x]/[y], the core must hold [x]/[y] stable for the whole run (it
    does — they come from the register file while the core is stalled).

    {1 Operation select ([u], [v])}

    - [u=0, v=0] — [FAD], floating add. ([FSB] reuses this path: the core pre-flips
      operand 2's sign bit, so the module only ever sees a plain add.)
    - [u=1, v=0] — [FLT], integer -> float: [x] is reinterpreted as an integer.
    - [u=0, v=1] — [FLOOR], float -> integer: the result is read from the aligned sum,
      skipping re-normalization.

    [z] -> result [R.a]. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    (** clock; the [State] counter and pipeline advance on each rising edge *)
    ; run : 'a (** op decoded — enable + synchronous clear for the [State] counter *)
    ; u : 'a (** [FLT] select (integer -> float) *)
    ; v : 'a (** [FLOOR] select (float -> integer) *)
    ; x : 'a (** 32-bit operand 1 (operand [B]) — a float, or an integer for [FLT] *)
    ; y : 'a (** 32-bit operand 2 (operand [C1]) — a float; unused by [FLT]/[FLOOR] *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { stall : 'a (** high while [run] and [State<>3]; freezes the core's PC/IR *)
    ; z : 'a (** 32-bit result -> [R.a] *)
    }
  [@@deriving hardcaml]
end

(** [create] is the FP add/convert unit as a Hardcaml [I]-to-[O] interface, for
    instantiation and simulation. [?ce] is the board clock-enable (default [vdd]); see
    {!Divider.create}. *)
val create : ?ce:Signal.t -> Signal.t I.t -> Signal.t O.t
