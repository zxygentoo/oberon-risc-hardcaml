(* Phase-9: dynamic MUL/DIV profile of a boot — reset, through the ROM→OS handoff, into
   the running Oberon system — to size the DSP-multiplier win against Amdahl (AGENT.md
   §5).

   We step the OCaml oracle (the instruction-level model; same instruction stream as the
   hardware) and decode each executed instruction in flight: register-form ops (p=0) with
   op-field 10 = MUL (the u-bit picks signed MUL vs unsigned MUL'), 11 = DIV. Fetch
   mirrors the oracle: [ram.(pc)] for OS code in low RAM, [bootloader.(pc-rom_base)] for
   the ROM bootloader. The boot splits into the ROM bootloader (SD-copy — ~no compute) and
   the OS (the real MUL/DIV). Oberon's "idle" desktop is a task loop, not a tight spin, so
   we don't try to detect idle; we profile a fixed, generous window past handoff — the
   MUL/DIV *density* is the Amdahl-relevant number and is stable across the window length.

   Run: dune build @profile_boot (or dune exec test/profile_boot.exe) *)

module R = Oracle.Risc
module BCC = Boot_checkpoint_common

let oracle_ram_base = 0x4_0000 (* word pc < this ⇒ low RAM (OS); else ROM *)
let rom_word_base = 0xFFFF_F800 / 4 (* boot ROM word base (= 0x3FFFE00) *)
let cap = 3_000_000 (* reset → handoff (~403K) + ~2.6M of the running OS *)

let () =
  (* boot the oracle exactly as the checkpoint does: PCLink + no-op clipboard + the disk *)
  let tmp = BCC.copy_to_temp BCC.disk_image in
  let oracle = R.make () in
  R.set_serial oracle (Oracle.Pclink.to_serial (Oracle.Pclink.create ()));
  R.set_clipboard
    oracle
    (Oracle.Clipboard.to_clipboard
       (Oracle.Clipboard.create
          { Oracle.Clipboard.get_text = (fun () -> None); set_text = (fun _ -> ()) }));
  R.set_spi oracle 1 (Oracle.Disk.to_spi (Oracle.Disk.create (Some tmp)));
  let ram = R.For_tests.ram oracle in
  let bootrom = Oracle.Boot_rom.bootloader in
  let rom_instr = ref 0
  and ram_instr = ref 0
  and mul = ref 0
  and mul_u = ref 0
  and div = ref 0
  and last_muldiv_step = ref 0
  and handoff_seen = ref false
  and handoff_step = ref 0
  and steps = ref 0 in
  while !steps < cap do
    let pc = R.For_tests.pc oracle in
    let in_ram = pc < oracle_ram_base in
    if in_ram && not !handoff_seen
    then (
      handoff_seen := true;
      handoff_step := !steps);
    let idx = pc - rom_word_base in
    let ir =
      if in_ram
      then ram.(pc)
      else if idx >= 0 && idx < Array.length bootrom
      then bootrom.(idx)
      else -1
    in
    if ir >= 0
    then (
      if in_ram then incr ram_instr else incr rom_instr;
      if ir lsr 31 = 0
      then (
        let op = (ir lsr 16) land 0xF
        and u = (ir lsr 29) land 1 in
        if op = 10
        then (
          if u = 1 then incr mul_u else incr mul;
          last_muldiv_step := !steps);
        if op = 11
        then (
          incr div;
          last_muldiv_step := !steps)));
    R.For_tests.single_step oracle;
    incr steps
  done;
  BCC.rm_temp tmp;
  let total = !rom_instr + !ram_instr in
  let muldiv = !mul + !mul_u + !div in
  let stall = muldiv * 33 in
  (* crude compute-cycle model: 1 cycle/instr + 33 extra per MUL/DIV. Ignores load/store
     and the I/O-bound SD wait (which inflate real cycles but are unaffected by the mult),
     so this is an upper bound on the multiplier's share. *)
  let compute_cycles = total + stall in
  let pct n d = if d = 0 then 0.0 else 100.0 *. float n /. float d in
  Printf.printf "Phase-9 boot MUL/DIV profile (reset → OS, %d instructions)\n" !steps;
  Printf.printf
    "  handoff: ROM→OS at instr %d%s\n"
    !handoff_step
    (if !handoff_seen then "" else " (NOT REACHED — raise cap)");
  Printf.printf
    "  phases : ROM bootloader %d instr | OS (RAM) %d instr\n"
    !rom_instr
    !ram_instr;
  Printf.printf
    "  MUL signed=%d  MUL' unsigned=%d  DIV=%d   (total MUL/DIV = %d)\n"
    !mul
    !mul_u
    !div
    muldiv;
  Printf.printf
    "  density: %.3f%% of all instr; %.3f%% of OS instr; last MUL/DIV at instr %d\n"
    (pct muldiv total)
    (pct muldiv !ram_instr)
    !last_muldiv_step;
  Printf.printf
    "  est. MUL/DIV stall: %d of ~%d compute cycles = %.2f%% (Amdahl ceiling)\n"
    stall
    compute_cycles
    (pct stall compute_cycles);
  Printf.printf "  projected compute speedup if the stall drops 33 → K:\n";
  List.iter
    (fun k ->
      let saved = muldiv * (33 - k) in
      let sped = float compute_cycles /. float (compute_cycles - saved) in
      Printf.printf "    K=%-2d → %.3fx  (saves %d cycles)\n" k sped saved)
    [ 0; 1; 2; 3 ]
;;
