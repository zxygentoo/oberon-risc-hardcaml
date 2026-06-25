(** [Alu] — the RISC5 register-op results that [RISC5.v] computes inline in its [aluRes]
    mux: MOV, the logic ops (AND/ANN/IOR/XOR), and ADD/SUB. Grouped into one unit for
    isolated reference tests (AGENT.md §2/§6).

    The remaining register ops are separate peer units — the shifts (ops 1..3) in
    {!Left_shifter}/{!Right_shifter}, and MUL/DIV/FP (ops 10..15) as multi-cycle units.
    Their results are selected alongside this unit's by the result mux at the core (Phase
    4), so those op slots read as 0 here.

    Flags: this unit emits the arithmetic C/OV (set only by ADD/SUB; other ops pass the
    current C/OV through). N/Z are not here — they derive from the final write value
    (regmux), assembled at the core. *)

open Hardcaml

module I : sig
  type 'a t =
    { p : 'a
    (** [IR[31]] — instruction class. Only register instructions ([p=0]) set C/OV; with
        [p=1] (branch/memory) ADD/SUB are inert even when [op] is 8/9, matching
        [RISC5.v]'s [ADD = ~p & (op==8)]. *)
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

(** [create] builds the result for MOV, the logic ops, and ADD/SUB (ops 0, 4..9) plus the
    C/OV flags; other op slots read as 0 (their units feed the result mux at the core). *)
val create : Signal.t I.t -> Signal.t O.t
