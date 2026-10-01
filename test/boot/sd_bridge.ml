(* Public API and design notes live in [sd_bridge.mli]. Factored out of the three SoC
   integration tests (boot checkpoint / visual golden / core RTL co-sim capture), which
   all bit-bang the same off-chip SD card over Emu.Disk. *)

type t =
  { spi : Emu.Io.spi
  ; mutable rx_seq :
      int array (* miso bits for the current transfer, MSbit-first per byte *)
  ; mutable rx_idx : int
  ; mutable prev_sclk : int
  ; mutable prev_rdy : int
  ; mutable nbytes : int
  }

let create spi =
  { spi; rx_seq = [||]; rx_idx = 0; prev_sclk = 0; prev_rdy = 1; nbytes = 0 }
;;

(* One transfer = one whole-value exchange with [Emu.Disk] (write-then-read, the
   emulator's order), gated on the SD being selected (the emulator's [spi_selected]). The
   response value is unpacked into the [miso] bit sequence the master will shift in. *)
let begin_ b ~data_tx ~fast ~selected =
  let rx =
    if selected
    then (
      b.spi.spi_write_data data_tx;
      b.spi.spi_read_data ())
    else 0xFFFF_FFFF (* deselected: the line idles high, whatever the width *)
  in
  b.nbytes <- b.nbytes + 1;
  let nbits = if fast then 32 else 8 in
  (* bit j = bit (7 - j mod 8) of byte (j / 8): MSbit-first within each byte, bytes
     low-to-high *)
  b.rx_seq
  <- Array.init nbits (fun j -> (rx asr ((8 * (j / 8)) + (7 - (j mod 8)))) land 1);
  b.rx_idx <- 0
;;

let miso b = if b.rx_idx < Array.length b.rx_seq then b.rx_seq.(b.rx_idx) else 1

let step b ~sclk ~rdy ~data_tx ~fast ~selected =
  if b.prev_rdy = 1 && rdy = 0 then begin_ b ~data_tx ~fast ~selected;
  if b.prev_sclk = 1 && sclk = 0 then b.rx_idx <- b.rx_idx + 1;
  b.prev_sclk <- sclk;
  b.prev_rdy <- rdy
;;

let nbytes b = b.nbytes
