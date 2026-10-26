(** The register-operation results that [RISC5.v] computes inline in its [aluRes] mux:
    MOV, the logic operations (AND, ANN, IOR, XOR) and ADD/SUB. They are gathered into a
    unit so that they can be tested alone.

    The shifts (operations 1..3) and MUL, DIV and the FP operations (10..15) are separate
    units whose results the core selects beside this one; their slots read 0 here.

    This unit produces C and OV, which only ADD and SUB change. N and Z follow the value
    the core finally writes, so the core derives them. *)

open Hardcaml

module I : sig
  type 'a t =
    { p : 'a
    (** [IR[31]], the instruction class. Only a register instruction ([p] = 0) sets C and
        OV: a branch or memory instruction whose [op] field happens to be 8 or 9 leaves
        them alone, as [RISC5.v]'s [ADD = ~p & (op==8)] does. *)
    ; op : 'a (** [IR[19:16]] — register-operation selector (4 bits) *)
    ; u : 'a (** modifier [IR[29]]: ADD'/SUB' carry-in, MOV variants *)
    ; q : 'a (** [IR[30]]: selects the MOV immediate forms *)
    ; v : 'a (** [IR[28]]: MOV flags-read vs [H] *)
    ; imm : 'a (** [IR[15:0]] — the MOV [imm<<16] source (16 bits) *)
    ; b : 'a (** operand [B] (= R.b) *)
    ; c1 : 'a (** second operand [C1] (already q-muxed: imm-extended or R.c) *)
    ; h : 'a (** aux register [H] (MUL-high / DIV-remainder; a MUL/DIV-unit source) *)
    ; n_in : 'a (** current flag N — for the MOV flags-read word *)
    ; z_in : 'a (** current flag Z *)
    ; c_in : 'a (** current flag C — also the ADD'/SUB' carry-in *)
    ; ov_in : 'a (** current flag OV *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { res : 'a (** [aluRes] for the ops this unit owns (0, 4..9) *)
    ; c : 'a (** carry/borrow — set by ADD/SUB, else passes [c_in] through *)
    ; ov : 'a (** signed overflow — set by ADD/SUB, else passes [ov_in] through *)
    }
  [@@deriving hardcaml]
end

val create : Signal.t I.t -> Signal.t O.t
