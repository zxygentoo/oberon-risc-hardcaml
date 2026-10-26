(** The SD card outside the chip, for the tests that boot the real disk: an SPI slave over
    [Emu.Disk]. It is driven from the SPI master's shift and control registers, read by
    name, and from the [sclk] pin; it does not sample [mosi].

    One transfer is one exchange of a whole value with the disk — write, then read, the
    emulator's order — and only while the card is selected ([spiCtrl[1:0] = 1]). The
    response goes back on [miso] most significant bit first within each byte, least
    significant byte first, one bit per falling edge of [sclk]: the edge the slow 50%
    clock and the fast one-cycle pulse have in common. *)

type t

(** [create spi] is a fresh bridge over the disk's SPI endpoint, e.g.
    [create (Emu.Disk.to_spi (Emu.Disk.create (Some path)))]. *)
val create : Emu.Io.spi -> t

(** the [miso] line level (0/1) the SoC should sample this cycle *)
val miso : t -> int

(** advance one SoC cycle: at a transfer start ([rdy] 1->0) capture [data_tx] (the freshly
    loaded shift register) and exchange the whole value with the disk; on each [sclk]
    falling edge shift the response out by one bit. [fast] = spiCtrl bit 2 (a 32-bit word
    vs a byte), [selected] = spiCtrl[1:0]=1. *)
val step : t -> sclk:int -> rdy:int -> data_tx:int -> fast:bool -> selected:bool -> unit

(** number of transfers exchanged so far (the "spi_bytes" boot-progress counter) *)
val nbytes : t -> int
