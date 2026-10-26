(* Public contract in [oracle.mli]. *)

module R = Emu.Risc

let create ~disk =
  let oracle = R.make () in
  R.set_serial oracle (Emu.Pclink.to_serial (Emu.Pclink.create ()));
  R.set_clipboard
    oracle
    (Emu.Clipboard.to_clipboard
       (Emu.Clipboard.create
          { Emu.Clipboard.get_text = (fun () -> None); set_text = (fun _ -> ()) }));
  R.set_spi oracle 1 (Emu.Disk.to_spi (Emu.Disk.create (Some disk)));
  oracle
;;
