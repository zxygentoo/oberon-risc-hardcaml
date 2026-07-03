open! Base
open Hardcaml
module Core = Risc5.Cpu

(* Each stub instantiates the same module RISC5.v does, with the same instance and port
   names — and the output WIRES named to match RISC5.v's (lshout / product / A / …). That
   shared naming is what lets yosys equiv_make pair the instances and tie the black-box
   outputs, so the glue cones stop at the units (each proven separately) rather than
   solving through them. *)
let out inst port name = Signal.( -- ) (Instantiation.output inst port) name

let left_shifter (i : Signal.t Risc5.Left_shifter.I.t) : Signal.t Risc5.Left_shifter.O.t =
  let inst =
    Instantiation.create
      ()
      ~name:"LeftShifter"
      ~instance:"LSUnit"
      ~inputs:[ "x", i.x; "sc", i.sc ]
      ~outputs:[ "y", 32 ]
  in
  { y = out inst "y" "lshout" }
;;

let right_shifter (i : Signal.t Risc5.Right_shifter.I.t)
  : Signal.t Risc5.Right_shifter.O.t
  =
  let inst =
    Instantiation.create
      ()
      ~name:"RightShifter"
      ~instance:"RSUnit"
      ~inputs:[ "x", i.x; "sc", i.sc; "md", i.md ]
      ~outputs:[ "y", 32 ]
  in
  { y = out inst "y" "rshout" }
;;

let multiplier (i : Signal.t Risc5.Multiplier.I.t) : Signal.t Risc5.Multiplier.O.t =
  let inst =
    Instantiation.create
      ()
      ~name:"Multiplier"
      ~instance:"mulUnit"
      ~inputs:[ "clk", i.clock; "run", i.run; "u", i.u; "x", i.x; "y", i.y ]
      ~outputs:[ "stall", 1; "z", 64 ]
  in
  { stall = out inst "stall" "stallM"; z = out inst "z" "product" }
;;

let divider (i : Signal.t Risc5.Divider.I.t) : Signal.t Risc5.Divider.O.t =
  let inst =
    Instantiation.create
      ()
      ~name:"Divider"
      ~instance:"divUnit"
      ~inputs:[ "clk", i.clock; "run", i.run; "u", i.u; "x", i.x; "y", i.y ]
      ~outputs:[ "stall", 1; "quot", 32; "rem", 32 ]
  in
  { stall = out inst "stall" "stallD"
  ; quot = out inst "quot" "quotient"
  ; rem = out inst "rem" "remainder"
  }
;;

let fp_adder (i : Signal.t Risc5.Fp_adder.I.t) : Signal.t Risc5.Fp_adder.O.t =
  let inst =
    Instantiation.create
      ()
      ~name:"FPAdder"
      ~instance:"fpaddx"
      ~inputs:[ "clk", i.clock; "run", i.run; "u", i.u; "v", i.v; "x", i.x; "y", i.y ]
      ~outputs:[ "stall", 1; "z", 32 ]
  in
  { stall = out inst "stall" "stallFA"; z = out inst "z" "fsum" }
;;

let fp_multiplier (i : Signal.t Risc5.Fp_multiplier.I.t)
  : Signal.t Risc5.Fp_multiplier.O.t
  =
  let inst =
    Instantiation.create
      ()
      ~name:"FPMultiplier"
      ~instance:"fpmulx"
      ~inputs:[ "clk", i.clock; "run", i.run; "x", i.x; "y", i.y ]
      ~outputs:[ "stall", 1; "z", 32 ]
  in
  { stall = out inst "stall" "stallFM"; z = out inst "z" "fprod" }
;;

let fp_divider (i : Signal.t Risc5.Fp_divider.I.t) : Signal.t Risc5.Fp_divider.O.t =
  let inst =
    Instantiation.create
      ()
      ~name:"FPDivider"
      ~instance:"fpdivx"
      ~inputs:[ "clk", i.clock; "run", i.run; "x", i.x; "y", i.y ]
      ~outputs:[ "stall", 1; "z", 32 ]
  in
  { stall = out inst "stall" "stallFD"; z = out inst "z" "fquot" }
;;

let registers (i : Signal.t Risc5.Registers.I.t) : Signal.t Risc5.Registers.O.t =
  let inst =
    Instantiation.create
      ()
      ~name:"Registers"
      ~instance:"regs"
      ~inputs:
        [ "clk", i.clock
        ; "wr", i.wr
        ; "rno0", i.rno0
        ; "rno1", i.rno1
        ; "rno2", i.rno2
        ; "din", i.din
        ]
      ~outputs:[ "dout0", 32; "dout1", 32; "dout2", 32 ]
  in
  { dout0 = out inst "dout0" "A"
  ; dout1 = out inst "dout1" "B"
  ; dout2 = out inst "dout2" "C0"
  }
;;

let units : Core.Units.t =
  { left_shifter
  ; right_shifter
  ; multiplier
  ; divider
  ; fp_adder
  ; fp_multiplier
  ; fp_divider
  ; registers
  }
;;

(* The names our 13 registers carry vs RISC5.v's — the yosys flow renames ours to these so
   equiv_make pairs the flip-flops. [irq1] already matches, so it isn't listed. *)
let register_renames =
  [ "pc", "PC"
  ; "ir", "IR"
  ; "n", "N"
  ; "z", "Z"
  ; "c", "C"
  ; "ov", "OV"
  ; "h", "H"
  ; "stall_l1", "stallL1"
  ; "int_enb", "intEnb"
  ; "int_pnd", "intPnd"
  ; "int_md", "intMd"
  ; "spc", "SPC"
  ]
;;

(* The gate circuit: our core with the 8 submodules as black boxes, ports named to match
   RISC5.v (clk/rst/stallX/...), module named distinctly so yosys reads both. *)
let circuit () =
  let open Signal in
  let i =
    { Core.I.clock = input "clk" 1
    ; rst_n = input "rst" 1
    ; irq = input "irq" 1
    ; stall_x = input "stallX" 1
    ; inbus = input "inbus" 32
    ; codebus = input "codebus" 32
    }
  in
  let o = Core.create_with_units ~units i in
  Circuit.create_exn
    ~name:"risc5_core_ours"
    [ output "adr" o.adr
    ; output "rd" o.rd
    ; output "wr" o.wr
    ; output "ben" o.ben
    ; output "outbus" o.outbus
    ]
;;
