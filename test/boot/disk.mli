(** The disk the boot gates boot: the vendored Oberon image, and the scratch copy a run
    works on (a boot writes to its disk). *)

(** the real Oberon disk image, resolved from the project root so it works from any cwd;
    the [DISK_IMG] environment variable overrides *)
val image : string

(** [DISK_IMG] is set: the image is not the one the goldens' pinned hash belongs to *)
val custom : bool

(** copy [src] to a fresh temp file; [rm_temp] removes it *)
val copy_to_temp : string -> string

val rm_temp : string -> unit
