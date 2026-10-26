(lang dune 3.0)

(name oberon-risc-hardcaml)

(generate_opam_files true)

(source
 (github zxygentoo/oberon-risc-hardcaml))

(license MIT)

(maintainers "zxy <zxygentoo@gmail.com>")

(authors "zxy <zxygentoo@gmail.com>")

(package
 (name oberon-risc-hardcaml)
 (allow_empty)
 (synopsis "Cycle-accurate Hardcaml port of Wirth's Oberon RISC5 CPU/SoC")
 (description
  "A synthesizable Hardcaml port of the Project Oberon RISC5 machine, built one\nmodule at a time from the original Verilog and verified in lockstep against the\nOCaml Oberon RISC emulator (oberon-risc-emu-ocaml). Targets the Digilent\nNexys 4 (Xilinx Artix-7).")
 (depends
  (ocaml
   (>= 5.2.0))
  (hardcaml
   (>= v0.18~preview))
  (hardcaml_waveterm
   (>= v0.18~preview))
  (ppx_hardcaml
   (>= v0.18~preview))
  (hardcaml_verify
   (>= v0.18~preview))
  (hardcaml_of_verilog
   (>= v0.18~preview))
  ppx_expect
  qcheck-core))
