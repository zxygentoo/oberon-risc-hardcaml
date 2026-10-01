(* The design's boot ROM ([Risc5.Rom.bootloader]) must equal the emulator's own copy
   ([Emu.Boot_rom]): otherwise the design and its oracle would boot different images, and
   the boot gates would compare nothing. *)

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
