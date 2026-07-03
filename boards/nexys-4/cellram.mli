(** [Cellram] — the Phase-7 PSRAM memory controller + CPU/video arbiter (synthesizable).

    The board's main memory is a Micron cellular PSRAM presenting a 16-bit-wide
    {b asynchronous SRAM} interface with ~70 ns access (Nexys 4; AGENT.md §4). This module
    is the adapter between that chip and the rest of the SoC: it gives the CPU and the
    video DMA the 32-bit word interface they expect, hiding the 16↔32 width conversion and
    the wait-states.

    {1 How the wait-states reach the CPU}

    [Cpu] assumes single-cycle memory: every cycle it presents [adr] and consumes
    [codebus]/[inbus] combinationally. We cannot do that with 70 ns memory, so we freeze
    the whole CPU with its clock-enable ([Cpu]'s [?ce]) while an access is in flight: the
    machine pauses and resumes, so each {e enabled} cycle still sees the single-cycle
    memory it was built for (AGENT.md §3). [ce] is asserted (CPU advances) only on the
    cycle a CPU access completes — or continuously during a compute (MUL/DIV/FP) stall,
    when the core needs no memory (signalled by [mem_pend] = 0).

    {1 Clients & arbitration}

    One PSRAM port, two clients, video-priority:
    - {b video DMA} ([vidreq]/[vidadr]): a framebuffer word read; real-time, so it wins
      the bus. [viddata] is the word read back ([vid_ack] pulses when it is valid).
    - {b CPU} ([mem_pend]/[adr]/[wr]/[ben]/[wdata]): a fetch or load (read) or a store
      (write) of the 32-bit word at [adr]. [rdata] is the read word (valid the cycle [ce]
      rises for a CPU access).

    Video priority is also {e preemptive over CPU reads}: a framebuffer fetch has a hard
    real-time deadline (the raster consumes the word ~477 ns after the request), and the
    one place it can miss is arriving just after a CPU access seized the port. So a video
    request landing mid-CPU-{e read} aborts that read and goes immediately; the CPU is
    frozen on [ce] and never saw it retire, so it transparently re-arbitrates and restarts
    after (reads are idempotent — only a few cycles are wasted, re-earned long before the
    next group's request). CPU {e writes} are never preempted: a half-written word would
    corrupt RAM. This is what keeps the framebuffer fetch inside its deadline under load.

    A transaction is two 16-bit halfword phases (low half = even halfword address, high
    half = odd); each phase drives the async pins for a parameterized number of cycles
    ([read_cycles]/[write_cycles], sized so a phase covers the chip's 70 ns tAA at the
    system clock — 5 at 60 MHz on the board). 1 MB window:
    [MemAdr[18:0] = {adr[19:2], half}], [MemAdr[22:19] = 0].

    {1 The on-chip fast path}

    [cpu_internal] marks a CPU access whose data is {e on-chip}, not in PSRAM — a boot-ROM
    fetch (codebus from [Rom]) or any MMIO load/store (top 64 B). Such an access completes
    in a {b single} [ce] cycle and touches no PSRAM pins. This is not just an
    optimization: it keeps every MMIO access one CPU-cycle long, so the SoC's write
    strobes (spiStart/startTx/…) and the peripheral register writes still fire exactly
    once per logical store even though the core is otherwise stretched across many clocks.
    (Free-running peripherals — the ms timer, the SPI/UART/PS2 FSMs — are clocked by the
    system clock and are {e not} ce-gated: a slow CPU polling full-speed peripherals, as
    on real hardware.) *)

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

(** [create ?read_cycles ?write_cycles ?write_buffer i] builds the controller. The cycle
    counts are the cycles each 16-bit phase holds the async pins. The default 2 is the
    {e sim/test} value (the behavioural model responds at once — only the FSM control flow
    is under test); the board synthesizes read 6 / write 5 (100 / 83 ns at 60 MHz — the
    read phase is deliberately one over the 70 ns chip's minimum to give the FPGA I/O
    round trip a 30 ns budget instead of a knife-edge 13.3; see emit_verilog.ml and the
    PSRAM I/O budget in nexys4.xdc).

    [write_buffer] (Phase-10d, default [false] = the proven synchronous write path) adds a
    {b 1-entry write buffer}: a PSRAM-bound store retires in a {e single} [ce] cycle — the
    slot captures [{adr, ben, wdata}] whenever it is free, even mid-video-op — and the
    write transaction {e drains} to the chip in the background while the CPU runs on. The
    hazards are closed conservatively:
    - {b drain-before-read}: a PSRAM read (a cache miss) waits until the slot is empty, so
      every PSRAM read sees fully-drained memory — no forwarding or address compare;
    - a second store while the slot is full waits frozen (the burst cost the bench's stall
      profile measures — the depth-vs-payoff data);
    - the drain is a write, so the video preemption rule already exempts it; a video
      request landing mid-drain waits it out, exactly as it waits a synchronous store
      today (same ~477 ns deadline margin);
    - MMIO / ROM accesses still complete in one cycle {e during} a drain — an MMIO store
      can therefore become externally visible before an earlier buffered RAM store lands
      in PSRAM. Benign on this SoC: no peripheral reads RAM (video reads the framebuffer,
      but the board pairs this knob with [Soc]'s [fb_bram], which takes video off PSRAM;
      without [fb_bram] a not-yet-drained framebuffer word could reach the raster one
      frame stale). Coherence is untouched: the cache snoop/update and the [Framebuf]
      shadow write happen at store {e retire} (the accept cycle), and PSRAM catches up
      before anyone can read it (drain-before-read; video via [fb_bram] never reads
      PSRAM).

    [wbuf_depth] (default 1 = the proven Phase-10d single slot, cycle-identical) sizes the
    buffer as a FIFO of 1..4 pending stores: slot 0 (the oldest) is the drain source, a
    completing drain shifts the queue down, and a store is accepted 0-stall whenever any
    slot is free — so bursts up to [wbuf_depth] stores retire back-to-back. Total store
    order is preserved by construction, and drain-before-read waits for the {e whole} FIFO
    to empty, so the coherence argument is depth-independent. *)
val create
  :  ?read_cycles:int
  -> ?write_cycles:int
  -> ?write_buffer:bool
  -> ?wbuf_depth:int
  -> Signal.t I.t
  -> Signal.t O.t
