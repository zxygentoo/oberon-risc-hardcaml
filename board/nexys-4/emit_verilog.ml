(* Prints the board SoC — {!Nexys4_board.Soc} in the shipped configuration, with the boot
   ROM in it — as Verilog. gen_verilog.sh redirects the output to
   board/_generated/nexys-4/soc_board.v, which nexys4_top.v wraps with the vendor
   primitives. *)

open Hardcaml
module Soc = Nexys4_board.Soc
module Circ = Circuit.With_interface (Soc.I) (Soc.O)

let () =
  let circuit =
    Circ.create_exn (* the module name nexys4_top.v instantiates *)
      ~name:"soc_board"
      (Soc.create ~contents:Risc5.Rom.bootloader Nexys4_board.Build_config.shipped)
  in
  Rtl.print Verilog circuit
;;
