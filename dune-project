(lang dune 3.0)

(name oberon-risc-hardcaml)

(generate_opam_files true)

(maintainers "zxy <zxygentoo@gmail.com>")

(authors "zxy <zxygentoo@gmail.com>")

(package
 (name oberon-risc-hardcaml)
 (allow_empty)
 (synopsis "Cycle-accurate Hardcaml port of Wirth's Oberon RISC5 CPU/SoC")
 (description
  "A synthesizable Hardcaml port of the Project Oberon RISC5 machine, built one\nmodule at a time from the original Verilog and verified in lockstep against the\nOCaml risc_core emulator. Targets the Digilent Nexys 4 DDR (Xilinx Artix-7).")
 (depends
  (ocaml
   (>= 5.2.0))
  hardcaml
  hardcaml_waveterm
  ppx_hardcaml
  ppx_expect
  qcheck-core))
