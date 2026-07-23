(** Shared Hardcaml-free half of the four boot gates — the checkpoints
    [test_boot_checkpoint] (BRAM) / [test_boot_checkpoint_board] (PSRAM) and the visual
    goldens [test_visual_golden] / [test_visual_golden_board] (AGENT.md §6 layer 5).

    Everything here is independent of the SoC's Hardcaml interface: the disk image, the
    oracle boots, the §8-aware differential compare, the framebuffer
    geometry/render/hash/verdict, and the closure-parameterized loop drivers. The
    Cyclesim-side half — loud lookups, the SPI/SD tick, the run-to-handoff driver — is
    {!Boot_tb}; each gate supplies only its own sim construction, reset preamble, and RAM
    readback. *)

(** A machine's architectural state at the OS handoff, for differential comparison. *)
type snapshot =
  { pc : int
  ; regs : int array (** R0..R15 *)
  ; flags : int
  ; h : int
  ; ram : int -> int (** word reader, indices 0..0x3FFFF *)
  }

(** the real Oberon disk image, resolved from the project root so it works from any cwd;
    the [DISK_IMG] environment variable overrides *)
val disk_image : string

(** copy [src] to a fresh temp file (the boot mutates the disk); [rm_temp] removes it *)
val copy_to_temp : string -> string

val rm_temp : string -> unit

(** a SoC word pc below this has left the ROM-decode region for low RAM — the OS handoff *)
val rom_region_base : int

(** a fresh oracle wired exactly as the frontend does (PCLink serial + a no-op clipboard +
    the disk at [disk]) — the configuration that produced the goldens *)
val make_oracle : disk:string -> Emu.Risc.t

(** [run ~run_soc_to_handoff ~pass_msg] boots the SoC to its handoff (via the supplied
    [run_soc_to_handoff], which returns [None] if it never leaves the ROM), boots the
    OCaml oracle on the same disk, and §8-compares the two; prints [pass_msg] on success,
    and [exit 1]s on any divergence or a missing handoff. *)
val run : run_soc_to_handoff:(unit -> snapshot option) -> pass_msg:string -> unit

(** {2 The visual goldens' shared half} *)

val fb_w : int
val fb_h : int
val fb_words : int

(** word index of [Risc.default_display_start] (byte 0xE7F00) in a flat RAM *)
val fb_base_word : int

(** boot the oracle, advance [frames] at its synthetic 60 Hz clock, snapshot (framebuffer
    words, FNV-1a hash) *)
val boot_oracle_fb : frames:int -> int array * int64

val popcount : int array -> int

(** ASCII downsample: one char per [sx]x[sy] block, ['#'] if any pixel set; rows rendered
    top-down (Oberon's origin is bottom-left) *)
val render : int array -> sx:int -> sy:int -> string

(** FNV-1a over framebuffer words, matching [Emu.Headless.framebuffer_hash] *)
val fb_fnv : int array -> int64

(** [run_to_settle ~cap ~chunk ~settle ~tick ~read_fb ~pc ~spi_bytes] runs [chunk]-cycle
    bursts of [tick], snapshotting [read_fb] after each, until the framebuffer is drawn
    and then unchanged for [settle] consecutive chunks, or [cap] cycles. [pc]/[spi_bytes]
    feed the progress line only. Returns (last framebuffer, settled?). *)
val run_to_settle
  :  cap:int
  -> chunk:int
  -> settle:int
  -> tick:(unit -> unit)
  -> read_fb:(unit -> int array)
  -> pc:(unit -> int)
  -> spi_bytes:(unit -> int)
  -> int array * bool

(** diff + render both framebuffers and print the verdict ([exit 1] on FAIL). The label
    parameters reconstruct each golden's exact historical lines: [tag] suffixes "VISUAL
    GOLDEN", [subject] names the machine in the PASS line, [render_label] heads the SoC
    render, [pass_tail] trails the PASS line. *)
val golden_report
  :  tag:string
  -> subject:string
  -> render_label:string
  -> pass_tail:string
  -> oracle_fb:int array
  -> oracle_hash:int64
  -> soc_fb:int array
  -> soc_hash:int64
  -> settled:bool
  -> unit
