(** Off-chip SD card for the SoC integration tests — a bit-level SPI slave over
    [Oracle.Disk], watching the SoC's real [sclk]/[mosi]/[miso] pins. Shared by the
    boot-handoff checkpoint, the visual golden, and the core RTL co-sim capture (all of
    which boot the real disk through the {!Risc5.Spi} master).

    The §8 gotchas are baked in: one whole-value exchange with [Oracle.Disk] per transfer
    (write-then-read, the emulator's order) gated on the SD being selected
    ([spiCtrl[1:0]=1]); the response clocked back on [miso] MSbit-first per byte,
    LSByte-first across the word; advancing one bit per [sclk] falling edge — the bit
    boundary common to the slow 50%-duty clock and the fast one-cycle pulse. *)

type t

(** [create spi] is a fresh bridge over the disk's SPI endpoint, e.g.
    [create (Oracle.Disk.to_spi (Oracle.Disk.create (Some path)))]. *)
val create : Oracle.Io.spi -> t

(** the [miso] line level (0/1) the SoC should sample this cycle *)
val miso : t -> int

(** advance one SoC cycle: at a transfer start ([rdy] 1->0) capture [data_tx] (the freshly
    loaded shift register) and exchange the whole value with the disk; on each [sclk]
    falling edge shift the response out by one bit. [fast] = spiCtrl bit 2 (a 32-bit word
    vs a byte), [selected] = spiCtrl[1:0]=1. *)
val step : t -> sclk:int -> rdy:int -> data_tx:int -> fast:bool -> selected:bool -> unit

(** number of transfers exchanged so far (the "spi_bytes" boot-progress counter) *)
val nbytes : t -> int
