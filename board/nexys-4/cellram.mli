(** The PSRAM controller and the arbiter between its two clients, the CPU and the video
    DMA.

    The board's main memory is a Micron cellular PSRAM with a 16-bit asynchronous-SRAM
    interface and a 70 ns access time. This module gives the CPU and the video controller
    the 32-bit word interface they expect, hiding the width conversion and the wait.

    {1 How the wait reaches the CPU}

    The core assumes single-cycle memory: every cycle it presents [adr] and consumes the
    word combinationally. With 70 ns memory that cannot hold, so the whole core is frozen
    by its clock enable ({!Risc5.Cpu.create}'s [?ce]) while an access is in flight, and
    each {e enabled} cycle still sees the memory it was built for. [ce] is high on the
    cycle a CPU access completes, and continuously while the core wants no memory
    ([mem_pend] low: an iterative unit is computing).

    {1 Clients and arbitration}

    One PSRAM port, two clients:
    - the {b video DMA} ([vidreq]/[vidadr]) reads a framebuffer word; [vid_ack] pulses
      when [viddata] holds it;
    - the {b CPU} ([mem_pend]/[adr]/[wr]/[ben]/[wdata]) fetches, loads or stores the word
      at [adr]; [rdata] is valid on the cycle [ce] rises.

    Video wins the port, and it {e preempts a CPU read in flight}. The raster consumes a
    framebuffer word about 477 ns after requesting it, and the one way to miss that is to
    arrive just after a CPU access took the port. A preempted read costs nothing but its
    wasted cycles: the core is frozen and never saw it complete, so the read simply starts
    again. A CPU {e write} is never preempted, since half a word written would corrupt
    memory.

    A transaction is two 16-bit phases, the low halfword then the high, each holding the
    pins for [read_cycles] or [write_cycles] clocks. The whole 16 MiB chip is addressed:
    [MemAdr[22:0] = {adr[23:2], half}]. Oberon uses the low 1 MiB.

    {1 The on-chip fast path}

    [cpu_internal] marks a CPU access served on the FPGA: a boot-ROM fetch or any MMIO
    access. It completes in one [ce] cycle and touches no PSRAM pin. This is more than an
    optimisation: it keeps every MMIO access one core cycle long, so a peripheral's write
    strobe fires exactly once per store although the core is otherwise stretched across
    many clocks. The peripherals themselves are not gated: a slow CPU polls full-speed
    peripherals, as on any real machine. *)

open Hardcaml

module I : sig
  type 'a t =
    { clock : 'a
    ; mem_pend : 'a (** core wants the bus this cycle (= [Cpu]'s [mem_pend]) *)
    ; cpu_internal : 'a
    (** the CPU access is served on-chip (ROM fetch / MMIO) — 1 cycle *)
    ; adr : 'a (** core byte address [adr[23:0]] (fetch or load/store data) *)
    ; wr : 'a (** core write strobe (a store) *)
    ; ben : 'a (** core byte enable (byte vs word access) *)
    ; wdata : 'a (** core store data ([outbus], already byte-replicated) *)
    ; vidreq : 'a (** video DMA request (1-cycle pulse, latched internally) *)
    ; vidadr : 'a (** framebuffer word address [vidadr[17:0]] *)
    ; mem_dq_i : 'a (** 16-bit data read back from the chip (via the top's IOBUFs) *)
    }
  [@@deriving hardcaml]
end

module O : sig
  type 'a t =
    { ce : 'a (** clock-enable to [Cpu] (1 = the CPU advances this cycle) *)
    ; rdata : 'a
    (** assembled 32-bit CPU read word (→ codebus/inbus); valid when [ce] for a PSRAM read *)
    ; viddata : 'a (** assembled 32-bit framebuffer word (→ [Video]'s [viddata]) *)
    ; vid_ack : 'a (** pulse: a video read just completed and [viddata] is valid *)
    ; vidpar : 'a
    (** parity (column LSB) of the completing video word, valid with [vid_ack] — picks
        [Video]'s ping-pong prefetch buffer (→ [Video]'s [?viddata_par]) *)
    ; mem_adr : 'a (** PSRAM address [MemAdr[22:0]] (halfword address) *)
    ; mem_dq_o : 'a (** PSRAM write data [16] (driven when [~mem_dq_t]) *)
    ; mem_dq_t : 'a (** PSRAM data tristate: 1 = hi-Z (read), 0 = drive (write) *)
    ; ce_n : 'a (** PSRAM chip enable, active low *)
    ; oe_n : 'a (** PSRAM output enable, active low (asserted on reads) *)
    ; we_n : 'a (** PSRAM write enable, active low (pulsed on writes) *)
    ; ub_n : 'a (** PSRAM upper-byte enable, active low (data[15:8]) *)
    ; lb_n : 'a (** PSRAM lower-byte enable, active low (data[7:0]) *)
    }
  [@@deriving hardcaml]
end

(** [create i] builds the controller.

    [read_cycles] (1..16) and [write_cycles] (2..16) are the clocks each 16-bit phase
    holds the pins; both default to 2, which suits only a chip model that answers at once.
    WE# is low for all but the last clock of a write phase. {!Build_config} gives the
    values the board ships and why.

    [write_buffer] (default [false]) lets a store retire in a {e single} [ce] cycle: a
    FIFO of [wbuf_depth] entries (1..4, default 1) captures [{adr, ben, wdata}] whenever
    it has room, even while the port serves video, and the writes {e drain} to the chip in
    order in the background. A store finding the FIFO full waits. What keeps this safe:
    - {b drain before read}: a PSRAM read waits until the FIFO is empty, so it always sees
      drained memory, with no forwarding and no address comparison;
    - a drain is a write, so video never preempts it; a video request arriving during one
      waits, as it would for an unbuffered store;
    - a ROM or MMIO access still completes in one cycle {e during} a drain, so an MMIO
      store can take effect before an earlier buffered store has reached the chip. That is
      harmless here because no peripheral reads RAM — provided video does not: the
      framebuffer must be served from the {!Framebuf} shadow, or a word not yet drained
      could reach the screen a frame late;
    - the cache and the framebuffer shadow are updated when a store {e retires}, not when
      it drains, and nothing can read the PSRAM until it has caught up. *)
val create
  :  ?read_cycles:int
  -> ?write_cycles:int
  -> ?write_buffer:bool
  -> ?wbuf_depth:int
  -> Signal.t I.t
  -> Signal.t O.t
