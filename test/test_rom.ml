(* Guard test (AGENT.md §8 pattern, e.g. the oracle's mov_flags_read_0x53): the design's
   boot ROM — [Risc5.Rom], shipped with the [risc5] library — must equal the oracle's own
   transcription ([Emu.Boot_rom], from the C [risc-boot.inc]). Both are immutable, so this
   pins them: hardware-under-test and oracle can never boot different ROM images, which is
   what makes the boot-checkpoint / visual-golden comparisons meaningful. *)

let () =
  let ours = Risc5.Rom.bootloader
  and oracle = Emu.Boot_rom.bootloader in
  if Array.length ours <> Array.length oracle
  then (
    Printf.printf
      "ROM GUARD FAIL: length %d <> %d\n"
      (Array.length ours)
      (Array.length oracle);
    exit 1);
  let mismatch = ref (-1) in
  Array.iteri (fun i w -> if !mismatch < 0 && w <> oracle.(i) then mismatch := i) ours;
  if !mismatch >= 0
  then (
    Printf.printf
      "ROM GUARD FAIL: word %d differs: Risc5.Rom=0x%08X Emu.Boot_rom=0x%08X\n"
      !mismatch
      ours.(!mismatch)
      oracle.(!mismatch);
    exit 1)
  else
    Printf.printf
      "ROM GUARD PASS: Risc5.Rom.bootloader = Emu.Boot_rom.bootloader (512 words)\n"
;;
