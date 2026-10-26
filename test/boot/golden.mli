(** The visual golden, Hardcaml-free: the framebuffer's geometry, the oracle's desktop,
    render and hash, the settle loop and the verdicts. Each golden supplies its sim, its
    framebuffer readback and its tick as closures; the Cyclesim side (the SD-card tick,
    the scan-out capture) is {!Tb}. *)

val fb_w : int
val fb_h : int
val fb_words : int

(** word index of [Risc.default_display_start] (byte 0xE7F00) in a flat RAM *)
val fb_base_word : int

(** boot the oracle, advance [frames] at its synthetic 60 Hz clock, snapshot (framebuffer
    words, FNV-1a hash) *)
val boot_oracle_fb : frames:int -> int array * int64

(** the framebuffer hash of the idle desktop the vendored disk image boots to;
    {!boot_oracle_fb} fails unless the oracle reproduces it (skipped under [DISK_IMG]) and
    always fails on a blank oracle screen *)
val desktop_hash : int64

(** [scanout_report ~soc_fb ~scan ~stray] is the scan-out verdict: [scan] (the image
    {!Tb.scan_frame} rebuilt from the [rgb] pins) must equal [soc_fb] word for word and
    [stray] (lit pixels in blanking) must be 0. Prints PASS, or FAIL and exits 1. *)
val scanout_report : soc_fb:int array -> scan:int array -> stray:int -> unit

val popcount : int array -> int

(** ASCII downsample: one char per [sx]x[sy] block, ['#'] if any pixel set; rows rendered
    top-down (Oberon's origin is bottom-left) *)
val render : int array -> sx:int -> sy:int -> string

(** FNV-1a over framebuffer words, matching [Emu.Headless.framebuffer_hash] *)
val fb_fnv : int array -> int64

(** [run_to_settle ?target ~cap ~chunk ~settle ~tick ~read_fb ~pc ~spi_bytes ()] runs
    [chunk]-cycle bursts of [tick], snapshotting [read_fb] after each, until the
    framebuffer is drawn and then unchanged for [settle] consecutive chunks, or [cap]
    cycles. [?target] (the oracle's fb hash) short-circuits: a snapshot hashing to it ends
    the run at once — the verdict is decided, and the report re-diffs word-exact.
    [pc]/[spi_bytes] feed the progress line only. Returns (last framebuffer, settled?). *)
val run_to_settle
  :  ?target:int64
  -> cap:int
  -> chunk:int
  -> settle:int
  -> tick:(unit -> unit)
  -> read_fb:(unit -> int array)
  -> pc:(unit -> int)
  -> spi_bytes:(unit -> int)
  -> unit
  -> int array * bool

(** diff + render both framebuffers and print the verdict ([exit 1] on FAIL); [machine]
    names the SoC under test in the report *)
val report
  :  machine:string
  -> oracle_fb:int array
  -> oracle_hash:int64
  -> soc_fb:int array
  -> soc_hash:int64
  -> settled:bool
  -> unit
