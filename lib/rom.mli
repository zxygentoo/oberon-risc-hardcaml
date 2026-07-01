(** The RISC5 boot ROM image — design data, so [risc5] is a self-contained port of the
    machine (§1: [PROM.v]/[prom.mem] is a design source). [Prom] is the ROM {e hardware}
    and takes its image as a [~contents] parameter; this is the image itself, for the
    SoC/emit to supply. [Oracle.Boot_rom] holds the oracle's own copy for the emulator's
    internal boot; a guard test (test/test_rom.ml) pins the two equal so hardware and
    oracle boot the same ROM. *)

(** The 512-word boot loader: the 383-word PROM image proper, zero-filled to the 512-word
    depth [Prom] maps. Each value is in unsigned-32-bit range. *)
val bootloader : int array
