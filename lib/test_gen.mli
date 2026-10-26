(** QCheck plumbing shared by the co-located property tests and the harnesses in [test/]:
    one entry point that fixes the seed, and operand generators that reach the corner
    values uniform draws never do. Test scaffolding — nothing here reaches a circuit. *)

(** [check_exn test] runs [test] like [QCheck.Test.check_exn], under a fixed seed so a
    failure reproduces and expect-test output is stable. Set [QCHECK_SEED=<int>] to
    explore a different stream (with [dune runtest --force]: dune does not track the
    variable). *)
val check_exn : QCheck.Test.t -> unit

(** A 32-bit operand as an unsigned [int]: about a third of the draws are corners — 0, 1,
    the sign boundary [0x7FFFFFFF]/[0x80000000], all-ones, single bits and low-bit masks —
    the rest uniform. *)
val word32 : int QCheck.arbitrary

(** A 32-bit float pattern [{sign, exponent(8), mantissa(23)}]: a share of the draws take
    their exponent and mantissa from the edges (0, 1, the bias, 254, 255; all-zeros,
    all-ones), the rest are uniform bit patterns. *)
val fp32 : int QCheck.arbitrary

(** A legal divisor, [1 .. 0x7FFFFFFF], log-uniform in magnitude (so quotients of every
    width occur) with the extremes mixed in. *)
val divisor : int QCheck.arbitrary

(** A signed integer of [bits] bits: the extremes, the values around zero and around each
    byte boundary, and uniform draws. *)
val signed : bits:int -> int QCheck.arbitrary
