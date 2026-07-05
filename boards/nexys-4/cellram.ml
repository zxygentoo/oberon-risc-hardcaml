(* Public API and behaviour spec live in [cellram.mli].

   Implementation note. A small FSM around one PSRAM port. Each transaction reads or
   writes a 32-bit word as two 16-bit halfword phases (half 0 = low, half 1 = high), each
   phase holding the async pins for [read_cycles]/[write_cycles] cycles. The CPU is frozen
   between its access start and completion via [ce] (the core's clock-enable); video reads
   (priority) interleave on the same port. ROM-fetch / MMIO accesses ([cpu_internal])
   bypass the PSRAM and complete in one [ce] cycle. See the .mli for the full picture. *)

open! Base
open Hardcaml
open Signal

let cnt_width = 4 (* up to 15 cycles per phase — ample *)

module I = struct
  type 'a t =
    { clock : 'a
    ; mem_pend : 'a [@bits 1]
    ; cpu_internal : 'a [@bits 1]
    ; adr : 'a [@bits 24]
    ; wr : 'a [@bits 1]
    ; ben : 'a [@bits 1]
    ; wdata : 'a [@bits 32]
    ; vidreq : 'a [@bits 1]
    ; vidadr : 'a [@bits 18]
    ; mem_dq_i : 'a [@bits 16]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { ce : 'a [@bits 1]
    ; rdata : 'a [@bits 32]
    ; viddata : 'a [@bits 32]
    ; vid_ack : 'a [@bits 1]
    ; vidpar : 'a [@bits 1]
    ; mem_adr : 'a [@bits 23]
    ; mem_dq_o : 'a [@bits 16]
    ; mem_dq_t : 'a [@bits 1]
    ; ce_n : 'a [@bits 1]
    ; oe_n : 'a [@bits 1]
    ; we_n : 'a [@bits 1]
    ; ub_n : 'a [@bits 1]
    ; lb_n : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

let create
  ?(read_cycles = 2)
  ?(write_cycles = 2)
  ?(write_buffer = false)
  ?(wbuf_depth = 1)
  (i : _ I.t)
  : _ O.t
  =
  if wbuf_depth < 1 || wbuf_depth > 4
  then failwith (Printf.sprintf "Cellram: wbuf_depth must be in 1..4, got %d" wbuf_depth);
  let spec = Reg_spec.create () ~clock:i.clock in
  let cval n = of_unsigned_int ~width:cnt_width n in
  (* ── State ── a transaction in progress ([busy]), whether it is a video read ([op_vid])
     or a CPU write ([op_wr]), the halfword phase ([half]), the per-phase down-counter
     ([cnt]), the captured low halfword ([lo]), the latched request ([req_*]), the held
     framebuffer word ([viddata_reg]), and the latched video request ([vid_pending]). No
     reset: powers up to 0 (= Idle), like the core. *)
  let busy = Always.Variable.reg spec ~width:1 in
  let op_vid = Always.Variable.reg spec ~width:1 in
  let op_wr = Always.Variable.reg spec ~width:1 in
  let half = Always.Variable.reg spec ~width:1 in
  let cnt = Always.Variable.reg spec ~width:cnt_width in
  let lo = Always.Variable.reg spec ~width:16 in
  let req_word = Always.Variable.reg spec ~width:22 in
  let req_ben = Always.Variable.reg spec ~width:1 in
  let req_lane = Always.Variable.reg spec ~width:2 in
  let req_wdata = Always.Variable.reg spec ~width:32 in
  let viddata_reg = Always.Variable.reg spec ~width:32 in
  let vid_pending = Always.Variable.reg spec ~width:1 in
  (* ── Write buffer (Phase-10d, [?write_buffer] × [?wbuf_depth]) ── a [wbuf_depth]-entry
     FIFO of pending stores [{word, ben, lane, wdata}]. Slot 0 is the drain source (the
     OLDEST store — total store order preserved); a completing drain shifts the queue down
     one; [wb_cnt] counts occupied slots {e including} the one mid-drain, so [wb_cnt = 0]
     means "nothing pending anywhere" (the drain-before-read condition). [op_wb] tags the
     in-flight op as a background drain. Constructed unconditionally, but every read of
     their values is behind [if write_buffer] — with the seam off nothing reaches an
     output, so the registers fall out of the output cone and the default netlist is
     untouched. Depth 1 reduces cycle-for-cycle to the proven single slot
     ([~full = empty], no shift, accept and completion can never coincide). *)
  let wb_cnt_w = Int.ceil_log2 (wbuf_depth + 1) in
  let wb_word = Array.init wbuf_depth ~f:(fun _ -> Always.Variable.reg spec ~width:22) in
  let wb_ben = Array.init wbuf_depth ~f:(fun _ -> Always.Variable.reg spec ~width:1) in
  let wb_lane = Array.init wbuf_depth ~f:(fun _ -> Always.Variable.reg spec ~width:2) in
  let wb_wdata = Array.init wbuf_depth ~f:(fun _ -> Always.Variable.reg spec ~width:32) in
  let wb_cnt = Always.Variable.reg spec ~width:wb_cnt_w in
  let op_wb = Always.Variable.reg spec ~width:1 in
  let busy_v = busy.value -- "cr_busy" in
  let op_vid_v = op_vid.value -- "cr_op_vid" in
  let op_wr_v = op_wr.value in
  let half_v = half.value in
  let cnt_v = cnt.value in
  let lo_v = lo.value in
  let req_word_v = req_word.value in
  let req_ben_v = req_ben.value in
  let req_lane_v = req_lane.value in
  let req_wdata_v = req_wdata.value in
  let viddata_reg_v = viddata_reg.value in
  let vid_pending_v = vid_pending.value in
  let wb_cnt_v = if write_buffer then wb_cnt.value -- "wb_cnt" else zero wb_cnt_w in
  let wb_nonempty = if write_buffer then wb_cnt_v <>:. 0 else gnd in
  let wb_full = wb_cnt_v ==:. wbuf_depth in
  let op_wb_v = if write_buffer then op_wb.value else gnd in
  (* ── Combinational status ── *)
  let is_write = op_wr_v &: ~:op_vid_v in
  let cnt_zero = cnt_v ==:. 0 in
  let half1 = half_v ==:. 1 in
  let vid_complete = busy_v &: op_vid_v &: cnt_zero &: half1 in
  (* a drain completing frees the slot but must NOT raise [ce] — it is not the CPU's
     pending access (the store it carries retired at [wb_accept], cycles ago) *)
  let cpu_complete_psram = busy_v &: ~:op_vid_v &: ~:op_wb_v &: cnt_zero &: half1 in
  let drain_complete = busy_v &: op_wb_v &: cnt_zero &: half1 in
  (* an on-chip access (ROM/MMIO) needs no PSRAM and finishes the cycle it is requested *)
  let cpu_complete_internal = i.mem_pend &: i.cpu_internal in
  (* a PSRAM store retires the cycle the buffer captures it (0-stall, like a cache hit) —
     whenever a slot is free, even mid-video-op or mid-drain (capture needs no port). With
     the FIFO full a further store waits frozen: the burst cost the stall profile prices
     per depth. *)
  let wb_accept =
    if write_buffer
    then (i.mem_pend &: i.wr &: ~:(i.cpu_internal) &: ~:wb_full) -- "wb_accept"
    else gnd
  in
  (* the CPU advances when it wants no memory (compute stall), or its access just
     completed *)
  let ce = ~:(i.mem_pend) |: cpu_complete_psram |: cpu_complete_internal |: wb_accept in
  (* arbiter: video wins the port; then a pending drain; then a CPU access that actually
     needs PSRAM. With the buffer on, a CPU *store* never starts an op here (it goes
     through [wb_accept]) and a CPU *read* waits for the slot to empty — drain-before-read
     keeps every PSRAM read seeing fully-drained memory, so no forwarding/address-compare
     logic is needed (reads that get here are cache misses, ~0.3% of accesses; the wait is
     noise — measured, not guessed: bench_boot). *)
  let start_vid = ~:busy_v &: vid_pending_v in
  let start_wb =
    if write_buffer then ~:busy_v &: ~:vid_pending_v &: wb_nonempty else gnd
  in
  let start_cpu =
    ~:busy_v
    &: ~:vid_pending_v
    &: i.mem_pend
    &: ~:(i.cpu_internal)
    &: if write_buffer then ~:(i.wr) &: ~:wb_nonempty else vdd
  in
  (* Preemptible CPU reads. A framebuffer fetch has a hard ~477 ns raster deadline
     ([Video]'s [req0]→[xfer]); the worst case is it arriving just after a CPU access
     grabbed the port and having to wait the whole access out. So if a video request lands
     while a CPU READ is mid-flight (and not already completing this cycle), abort the
     read and let video go at once — the core is frozen on [ce] and never saw it retire,
     so it just re-arbitrates and restarts after. Reads are idempotent, so aborting costs
     only the few wasted cycles (re-earned before the next group's ~500 ns-away request).
     WRITES are never preempted — a half-written word would corrupt RAM. This removes the
     arbiter-wait term from the video deadline; the residual flicker / contention risk
     lives in the deadline margin itself (see the .mli + boards/nexys-4/README.md). *)
  let cpu_read_inflight = busy_v &: ~:op_vid_v &: ~:op_wr_v in
  let preempt =
    (cpu_read_inflight &: vid_pending_v &: ~:(cnt_zero &: half1)) -- "preempt"
  in
  let half_cnt_init is_wr =
    mux2 is_wr (cval (write_cycles - 1)) (cval (read_cycles - 1))
  in
  let new_word = i.mem_dq_i @: lo_v in
  let launch_vid =
    Always.
      [ busy <--. 1
      ; op_vid <--. 1
      ; op_wr <--. 0
      ; op_wb <--. 0
      ; req_word <-- uresize i.vidadr ~width:22 (* video is low-mem: top 4 bits zero *)
      ; half <--. 0
      ; cnt <-- cval (read_cycles - 1)
      ]
  in
  let launch_cpu =
    Always.
      [ busy <--. 1
      ; op_vid <--. 0
      ; op_wr <-- i.wr
      ; op_wb <--. 0
      ; req_word <-- select i.adr ~high:23 ~low:2 (* 22-bit word address, full 16 MiB *)
      ; req_ben <-- i.ben
      ; req_lane <-- select i.adr ~high:1 ~low:0
      ; req_wdata <-- i.wdata
      ; half <--. 0
      ; cnt <-- half_cnt_init i.wr
      ]
  in
  (* the drain: an ordinary write transaction sourced from FIFO slot 0 (the oldest store)
     instead of the live CPU pins (which have long since moved on). [op_wb] keeps it out
     of the CPU's [ce]; [op_wr]=1 keeps it out of video preemption (writes are never
     preempted). *)
  let launch_wb =
    Always.
      [ busy <--. 1
      ; op_vid <--. 0
      ; op_wr <--. 1
      ; op_wb <--. 1
      ; req_word <-- wb_word.(0).value
      ; req_ben <-- wb_ben.(0).value
      ; req_lane <-- wb_lane.(0).value
      ; req_wdata <-- wb_wdata.(0).value
      ; half <--. 0
      ; cnt <-- cval (write_cycles - 1)
      ]
  in
  let idle_arbiter =
    if write_buffer
    then
      Always.
        [ if_
            start_vid
            launch_vid
            [ if_ start_wb launch_wb [ when_ start_cpu launch_cpu ] ]
        ]
    else Always.[ if_ start_vid launch_vid [ when_ start_cpu launch_cpu ] ]
  in
  Always.(
    compile
      ([ if_
           busy_v
           [ if_
               preempt
               (* a video request arrived mid-CPU-read → abort; Idle picks video next
                  cycle *)
               [ busy <--. 0 ]
               [ if_
                   cnt_zero
                   [ if_
                       ~:half1
                       (* low half done → capture it, advance to the high half *)
                       [ lo <-- i.mem_dq_i; half <--. 1; cnt <-- half_cnt_init is_write ]
                       (* high half done → transaction complete *)
                       [ busy <--. 0; when_ op_vid_v [ viddata_reg <-- new_word ] ]
                   ]
                   [ decr cnt ]
               ]
           ]
           (* Idle: video first, else a pending drain, else a PSRAM-bound CPU access *)
           idle_arbiter
       ; (* latch a video request until it is serviced *)
         vid_pending <-- (i.vidreq |: (vid_pending_v &: ~:vid_complete))
       ]
       @
       if write_buffer
       then (
         (* FIFO maintenance. A completing drain shifts the queue down one; an accepted
            store lands at the tail — position [wb_cnt], or [wb_cnt - 1] when a drain
            completes the same cycle (the queue is about to shift under it). Both can fire
            together (slot freed and refilled in one edge); all right-hand sides read
            pre-edge values, so the shift copies the OLD tail even as the new store
            overwrites it. Per slot the accept has priority over the shift (the [if_] arms
            are exclusive), which is exactly the [pos = wb_cnt - 1] case. *)
         let pos = mux2 drain_complete (wb_cnt_v -:. 1) wb_cnt_v in
         let slot_stmts k =
           let capture =
             Always.
               [ wb_word.(k) <-- select i.adr ~high:23 ~low:2
               ; wb_ben.(k) <-- i.ben
               ; wb_lane.(k) <-- select i.adr ~high:1 ~low:0
               ; wb_wdata.(k) <-- i.wdata
               ]
           in
           let shift =
             if k < wbuf_depth - 1
             then
               Always.
                 [ when_
                     drain_complete
                     [ wb_word.(k) <-- wb_word.(k + 1).value
                     ; wb_ben.(k) <-- wb_ben.(k + 1).value
                     ; wb_lane.(k) <-- wb_lane.(k + 1).value
                     ; wb_wdata.(k) <-- wb_wdata.(k + 1).value
                     ]
                 ]
             else []
           in
           Always.[ if_ (wb_accept &: (pos ==:. k)) capture shift ]
         in
         List.concat (List.init wbuf_depth ~f:slot_stmts)
         @ [ wb_cnt
             <-- wb_cnt_v
                 +: uresize wb_accept ~width:wb_cnt_w
                 -: uresize drain_complete ~width:wb_cnt_w
           ])
       else []));
  (* ── PSRAM pins ── address [{req_word, half}]; data the current half of the store word;
     control active during [busy]: CE always, OE on reads, WE pulsed on writes (high at
     [cnt_zero] so it rises before the address moves), byte enables per word/byte store. *)
  let mem_adr = req_word_v @: half_v in
  (* {22-bit word address, halfword select} = the full 23-bit halfword address = 16 MiB *)
  let mem_dq_o =
    mux2 half_v (select req_wdata_v ~high:31 ~low:16) (select req_wdata_v ~high:15 ~low:0)
  in
  let mem_dq_t = ~:(busy_v &: is_write) in
  let ce_n = ~:busy_v in
  let oe_n = ~:(busy_v &: ~:is_write) in
  let we_n = ~:(busy_v &: is_write &: ~:cnt_zero) in
  let lane1 = msb req_lane_v in
  (* adr[1] : which half holds the byte *)
  let lane0 = lsb req_lane_v in
  (* adr[0] : lower/upper byte of that half *)
  let half_match = half_v ==: lane1 in
  (* a read or a word store enables both byte lanes; a byte store only the addressed one *)
  let lb_en = mux2 is_write (mux2 req_ben_v (half_match &: ~:lane0) vdd) vdd in
  let ub_en = mux2 is_write (mux2 req_ben_v (half_match &: lane0) vdd) vdd in
  { O.ce
  ; rdata =
      new_word (* {high = mem_dq_i, low = lo}; meaningful when [ce] for a PSRAM read *)
  ; viddata = mux2 vid_complete new_word viddata_reg_v
  ; vid_ack = vid_complete
  ; (* parity (column LSB) of the video word being returned — the latched fetch address,
       meaningful when [vid_ack]. [Video] uses it to pick the ping-pong buffer, so a slow
       (contended) completion lands in the right one regardless of the live raster phase. *)
    vidpar = lsb req_word_v
  ; mem_adr
  ; mem_dq_o
  ; mem_dq_t
  ; ce_n
  ; oe_n
  ; we_n
  ; ub_n = ~:ub_en
  ; lb_n = ~:lb_en
  }
;;

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── The
   controller is exercised against the behavioural chip ({!Cellram_model}) wired to its
   pins — a closed loop. [Tb] mimics the CPU handshake: present an access (hold
   [mem_pend] + [adr]/[wr]/…), and the access "retires" on the cycle [ce] rises. We use
   small wait counts here (the model answers at once; only the FSM control flow is under
   test). The waveform freezes the two-halfword read/write timing + the [ce] pulse; the
   qcheck proves 32-bit round-trips (word + byte stores) against a plain-array model;
   further tests cover the video read and the on-chip fast path. *)

(* aliases so the testbench can still name the controller's own interface after shadowing
   [I] *)
module Cr_I = I

let cr_create = create

module Tb = struct
  module I = struct
    type 'a t =
      { clock : 'a
      ; mem_pend : 'a [@bits 1]
      ; cpu_internal : 'a [@bits 1]
      ; adr : 'a [@bits 24]
      ; wr : 'a [@bits 1]
      ; ben : 'a [@bits 1]
      ; wdata : 'a [@bits 32]
      ; vidreq : 'a [@bits 1]
      ; vidadr : 'a [@bits 18]
      }
    [@@deriving hardcaml]
  end

  module O = struct
    type 'a t =
      { ce : 'a [@bits 1]
      ; rdata : 'a [@bits 32]
      ; viddata : 'a [@bits 32]
      ; vid_ack : 'a [@bits 1]
      ; (* chip-side pins surfaced for the byte-lane contract test (P3) *)
        we_n : 'a [@bits 1]
      ; ub_n : 'a [@bits 1]
      ; lb_n : 'a [@bits 1]
      ; mem_adr : 'a [@bits 23]
      ; mem_dq_o : 'a [@bits 16]
      }
    [@@deriving hardcaml]
  end

  let create ?read_cycles ?write_cycles ?write_buffer ?wbuf_depth ?addr_bits (i : _ I.t)
    : _ O.t
    =
    let dq_i = wire 16 in
    let c =
      cr_create
        ?read_cycles
        ?write_cycles
        ?write_buffer
        ?wbuf_depth
        { Cr_I.clock = i.clock
        ; mem_pend = i.mem_pend
        ; cpu_internal = i.cpu_internal
        ; adr = i.adr
        ; wr = i.wr
        ; ben = i.ben
        ; wdata = i.wdata
        ; vidreq = i.vidreq
        ; vidadr = i.vidadr
        ; mem_dq_i = dq_i
        }
    in
    let m =
      Cellram_model.create
        ?addr_bits
        { Cellram_model.I.clock = i.clock
        ; mem_adr = c.mem_adr
        ; mem_dq_o = c.mem_dq_o
        ; ce_n = c.ce_n
        ; we_n = c.we_n
        ; ub_n = c.ub_n
        ; lb_n = c.lb_n
        }
    in
    assign dq_i m.mem_dq_i;
    { O.ce = c.ce
    ; rdata = c.rdata
    ; viddata = c.viddata
    ; vid_ack = c.vid_ack
    ; we_n = c.we_n
    ; ub_n = c.ub_n
    ; lb_n = c.lb_n
    ; mem_adr = c.mem_adr
    ; mem_dq_o = c.mem_dq_o
    }
  ;;
end

let%expect_test "cellram — word store then load, two halfword phases + ce pulse \
                 [waveform]"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~read_cycles:2 ~write_cycles:2)
  in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  inp.cpu_internal := b1 0;
  inp.vidreq := b1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.ben := b1 0;
  (* present a word store of AABBCCDD to byte address 0x100 *)
  inp.mem_pend := b1 1;
  inp.adr := Bits.of_unsigned_int ~width:24 0x100;
  inp.wr := b1 1;
  inp.wdata := Bits.of_unsigned_int ~width:32 0xAABBCCDD;
  for _ = 1 to 7 do
    Cyclesim.cycle sim
  done;
  (* present a word load of the same address *)
  inp.wr := b1 0;
  inp.wdata := Bits.of_unsigned_int ~width:32 0;
  for _ = 1 to 7 do
    Cyclesim.cycle sim
  done;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "wr"
        ; port_name_is ~wave_format:Wave_format.Bit "ce"
        ; port_name_is ~wave_format:Wave_format.Bit "cr_busy"
        ; port_name_is ~wave_format:Wave_format.Hex "rdata"
        ]
    ~wave_width:4
    ~display_width:150
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │wr                ││──────────────────────────────────────────────────────────────────────┐                                                         │
    │                  ││                                                                      └─────────────────────────────────────────────────────────│
    │ce                ││                                        ┌─────────┐                                       ┌─────────┐                           │
    │                  ││────────────────────────────────────────┘         └───────────────────────────────────────┘         └───────────────────────────│
    │cr_busy           ││          ┌───────────────────────────────────────┐         ┌───────────────────────────────────────┐         ┌─────────────────│
    │                  ││──────────┘                                       └─────────┘                                       └─────────┘                 │
    │                  ││────────────────────┬─────────┬─────────┬───────────────────┬───────────────────┬─────────────────────────────┬─────────────────│
    │rdata             ││ 00000000           │CCDD0000 │0000CCDD │AABBCCDD           │CCDDCCDD           │AABBCCDD                     │CCDDCCDD         │
    │                  ││────────────────────┴─────────┴─────────┴───────────────────┴───────────────────┴─────────────────────────────┴─────────────────│
    └──────────────────┘└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
    |}]
;;

(* Drive one CPU access the way the core would: hold the request until [ce] rises (the
   access retires), then a clean idle cycle. Returns the read word seen at retirement. *)
let cpu_access sim (inp : _ Tb.I.t) (outp : _ Tb.O.t) ~internal ~adr ~wr ~ben ~wdata =
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.mem_pend := b1 true;
  inp.cpu_internal := b1 internal;
  inp.adr := Bits.of_unsigned_int ~width:24 adr;
  inp.wr := b1 wr;
  inp.ben := b1 ben;
  inp.wdata := Bits.of_unsigned_int ~width:32 wdata;
  let r = ref (-1) in
  let k = ref 0 in
  while !r < 0 && !k < 60 do
    Cyclesim.cycle sim;
    if Bits.to_int_trunc !(outp.ce) = 1 then r := Bits.to_unsigned_int !(outp.rdata);
    Int.incr k
  done;
  if !r < 0 then failwith "cellram: ce never asserted (CPU access hung)";
  inp.mem_pend := b1 false;
  Cyclesim.cycle sim;
  !r
;;

let%expect_test "cellram — 32-bit round-trip through PSRAM: word + byte stores [qcheck]" =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.vidreq := Bits.of_unsigned_int ~width:1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  let win = 16 in
  (* words; addresses confined to 0..win*4-1 bytes *)
  let store ~adr ~ben ~wdata =
    ignore (cpu_access sim inp outp ~internal:false ~adr ~wr:true ~ben ~wdata : int)
  in
  let load_word w =
    cpu_access sim inp outp ~internal:false ~adr:(w * 4) ~wr:false ~ben:false ~wdata:0
  in
  let check_seq ops =
    for w = 0 to win - 1 do
      store ~adr:(w * 4) ~ben:false ~wdata:0
    done;
    let model = Array.create ~len:win 0 in
    List.for_all ops ~f:(fun (ben, adr, wdata) ->
      store ~adr ~ben ~wdata;
      let w = adr lsr 2 in
      let l = adr land 3 in
      if ben
      then (
        let byte = (wdata lsr (8 * l)) land 0xFF in
        model.(w) <- model.(w) land lnot (0xFF lsl (8 * l)) lor (byte lsl (8 * l)))
      else model.(w) <- wdata;
      load_word w = model.(w))
  in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:250
       ~name:"cellram-roundtrip"
       QCheck.(
         list_size
           (Gen.int_range 1 16)
           (triple bool (int_range 0 ((win * 4) - 1)) (int_bound 0xFFFF_FFFF)))
       check_seq);
  [%expect {| |}]
;;

let%expect_test "cellram — on-chip fast path: a ROM/MMIO access retires in one ce cycle" =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles:4 ~write_cycles:4) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  inp.vidreq := b1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.ben := b1 0;
  inp.wr := b1 0;
  inp.wdata := Bits.of_unsigned_int ~width:32 0;
  (* an internal access asserts ce immediately — count cycles to the first ce=1 *)
  inp.mem_pend := b1 1;
  inp.cpu_internal := b1 1;
  inp.adr := Bits.of_unsigned_int ~width:24 0xFFE000 (* ROM region *);
  let k = ref 0 in
  let n = ref 0 in
  while !n = 0 && !k < 20 do
    Cyclesim.cycle sim;
    if Bits.to_int_trunc !(outp.ce) = 1 then n := !k + 1;
    Int.incr k
  done;
  Stdlib.Printf.printf
    "internal access: ce after %d cycle(s) (1 = single-cycle fast path)\n"
    !n;
  [%expect {| internal access: ce after 1 cycle(s) (1 = single-cycle fast path) |}]
;;

let%expect_test "cellram — video DMA read returns the framebuffer word, ce frozen \
                 meanwhile"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  inp.vidreq := b1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.cpu_internal := b1 0;
  (* seed framebuffer word at word address 0x40 (byte 0x100) with 0x12345678 *)
  ignore
    (cpu_access
       sim
       inp
       outp
       ~internal:false
       ~adr:0x100
       ~wr:true
       ~ben:false
       ~wdata:0x1234_5678
     : int);
  (* latch a pending video request for word 0x40 (the 1-cycle [vid_pending] register),
     then have the CPU also want the bus: video has priority, so [ce] must stay low until
     [vid_ack] *)
  inp.mem_pend := b1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0x40;
  inp.vidreq := b1 1;
  Cyclesim.cycle sim;
  inp.vidreq := b1 0;
  inp.mem_pend := b1 1 (* CPU now wants a RAM read elsewhere *);
  inp.wr := b1 0;
  inp.adr := Bits.of_unsigned_int ~width:24 0x200;
  (* run until vid_ack; check viddata and that ce stayed low while video held the bus *)
  let viddata = ref (-1) in
  let ce_high_during_video = ref false in
  let k = ref 0 in
  while !viddata < 0 && !k < 40 do
    Cyclesim.cycle sim;
    if Bits.to_int_trunc !(outp.vid_ack) = 1
    then viddata := Bits.to_unsigned_int !(outp.viddata)
    else if Bits.to_int_trunc !(outp.ce) = 1
    then ce_high_during_video := true;
    Int.incr k
  done;
  Stdlib.Printf.printf
    "viddata = 0x%X (framebuffer word)   CPU advanced before video done: %b\n"
    !viddata
    !ce_high_during_video;
  [%expect
    {| viddata = 0x12345678 (framebuffer word)   CPU advanced before video done: false |}]
;;

let%expect_test "cellram — a video request preempts an in-flight CPU read" =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  (* read_cycles 4 so the CPU read spans several cycles — room to interject mid-flight *)
  let sim = Sim.create (Tb.create ~read_cycles:4 ~write_cycles:4) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.vidreq := b1 false;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.cpu_internal := b1 false;
  (* seed the video word (byte 0x100 = word 0x40) and the CPU-read word (byte 0x200) *)
  ignore
    (cpu_access
       sim
       inp
       outp
       ~internal:false
       ~adr:0x100
       ~wr:true
       ~ben:false
       ~wdata:0x1111_2222
     : int);
  ignore
    (cpu_access
       sim
       inp
       outp
       ~internal:false
       ~adr:0x200
       ~wr:true
       ~ben:false
       ~wdata:0xAAAA_BBBB
     : int);
  (* start a CPU read of byte 0x200 and let it reach mid-flight — do NOT complete it *)
  inp.mem_pend := b1 true;
  inp.wr := b1 false;
  inp.ben := b1 false;
  inp.adr := Bits.of_unsigned_int ~width:24 0x200;
  Cyclesim.cycle sim (* read starts: busy, low halfword phase *);
  Cyclesim.cycle sim (* still mid low-half (read_cycles = 4) *);
  (* a video request now arrives mid-read → it must preempt the read *)
  inp.vidadr := Bits.of_unsigned_int ~width:18 0x40;
  inp.vidreq := b1 true;
  Cyclesim.cycle sim;
  inp.vidreq := b1 false;
  (* run to vid_ack; the CPU must NOT advance ([ce] low) while video holds the bus *)
  let vid_word = ref (-1)
  and ce_before_vid = ref false
  and k = ref 0 in
  while !vid_word < 0 && !k < 60 do
    Cyclesim.cycle sim;
    if Bits.to_int_trunc !(outp.vid_ack) = 1
    then vid_word := Bits.to_unsigned_int !(outp.viddata)
    else if Bits.to_int_trunc !(outp.ce) = 1
    then ce_before_vid := true;
    Int.incr k
  done;
  (* the preempted CPU read now restarts on its own and completes with the right data *)
  let cpu_word = ref (-1)
  and k2 = ref 0 in
  while !cpu_word < 0 && !k2 < 60 do
    Cyclesim.cycle sim;
    if Bits.to_int_trunc !(outp.ce) = 1
    then cpu_word := Bits.to_unsigned_int !(outp.rdata);
    Int.incr k2
  done;
  inp.mem_pend := b1 false;
  Cyclesim.cycle sim;
  Stdlib.Printf.printf
    "video word = 0x%X   CPU advanced before video done: %b   CPU read after = 0x%X\n"
    !vid_word
    !ce_before_vid
    !cpu_word;
  [%expect
    {| video word = 0x11112222   CPU advanced before video done: false   CPU read after = 0xAAAABBBB |}]
;;

(* ── P2: the wait-state latency itself ────────────────────────────────────────── The
   functional round-trips above prove the data is right but never assert *how long* an
   access takes — yet faithful wait-state insertion is the whole point of the controller
   (the .mli contract; the board's video-flicker margin rides on it). [measure_latency]
   counts the clocks from a request to the [ce] that retires it. *)

let measure_latency ?(read_cycles = 2) ?(write_cycles = 2) ~wr () =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles ~write_cycles) in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.vidreq := b1 false;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.cpu_internal := b1 false;
  inp.ben := b1 false;
  inp.wdata := Bits.of_unsigned_int ~width:32 0xDEAD_BEEF;
  inp.adr := Bits.of_unsigned_int ~width:24 0x200;
  inp.wr := b1 wr;
  inp.mem_pend := b1 true;
  let k = ref 0
  and retired = ref (-1) in
  while !retired < 0 && !k < 200 do
    Cyclesim.cycle sim;
    Int.incr k;
    if Bits.to_int_trunc !(outp.ce) = 1 then retired := !k
  done;
  if !retired < 0 then failwith "cellram: ce never asserted (access hung)";
  !retired
;;

let%expect_test "cellram — wait-state latency scales with read/write cycles, \
                 independently (incl. asymmetric)"
  =
  let row (rc, wc) =
    Stdlib.Printf.printf
      "read_cycles=%d write_cycles=%d -> read retires in %d clk, write in %d clk\n"
      rc
      wc
      (measure_latency ~read_cycles:rc ~write_cycles:wc ~wr:false ())
      (measure_latency ~read_cycles:rc ~write_cycles:wc ~wr:true ())
  in
  List.iter ~f:row [ 2, 2; 4, 4; 4, 3; 5, 2 ];
  (* a read's latency is set by read_cycles only, a write's by write_cycles only — the two
     halfword phases of a read both count [read_cycles], of a write both [write_cycles]. *)
  let lat ~rc ~wc ~wr = measure_latency ~read_cycles:rc ~write_cycles:wc ~wr () in
  Stdlib.Printf.printf
    "read latency ignores write_cycles: %b\nwrite latency ignores read_cycles: %b\n"
    (lat ~rc:4 ~wc:3 ~wr:false = lat ~rc:4 ~wc:9 ~wr:false)
    (lat ~rc:9 ~wc:3 ~wr:true = lat ~rc:4 ~wc:3 ~wr:true);
  [%expect
    {|
    read_cycles=2 write_cycles=2 -> read retires in 4 clk, write in 4 clk
    read_cycles=4 write_cycles=4 -> read retires in 8 clk, write in 8 clk
    read_cycles=4 write_cycles=3 -> read retires in 8 clk, write in 6 clk
    read_cycles=5 write_cycles=2 -> read retires in 10 clk, write in 4 clk
    read latency ignores write_cycles: true
    write latency ignores read_cycles: true
    |}]
;;

let%expect_test "cellram — 32-bit round-trip with asymmetric read/write cycles [qcheck]" =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let win = 16 in
  (* one sim per config (hoisted out of the property — rebuilding the model per case is
     the dominant cost), then the same word+byte-store round-trip the symmetric test runs. *)
  let run_config (rc, wc) =
    let sim = Sim.create (Tb.create ~read_cycles:rc ~write_cycles:wc) in
    let inp = Cyclesim.inputs sim
    and outp = Cyclesim.outputs sim in
    inp.vidreq := Bits.of_unsigned_int ~width:1 0;
    inp.vidadr := Bits.of_unsigned_int ~width:18 0;
    let store ~adr ~ben ~wdata =
      ignore (cpu_access sim inp outp ~internal:false ~adr ~wr:true ~ben ~wdata : int)
    in
    let load_word w =
      cpu_access sim inp outp ~internal:false ~adr:(w * 4) ~wr:false ~ben:false ~wdata:0
    in
    let check_seq ops =
      for w = 0 to win - 1 do
        store ~adr:(w * 4) ~ben:false ~wdata:0
      done;
      let model = Array.create ~len:win 0 in
      List.for_all ops ~f:(fun (ben, adr, wdata) ->
        store ~adr ~ben ~wdata;
        let w = adr lsr 2 in
        let l = adr land 3 in
        if ben
        then (
          let byte = (wdata lsr (8 * l)) land 0xFF in
          model.(w) <- model.(w) land lnot (0xFF lsl (8 * l)) lor (byte lsl (8 * l)))
        else model.(w) <- wdata;
        load_word w = model.(w))
    in
    QCheck.Test.check_exn
      (QCheck.Test.make
         ~count:80
         ~name:(Stdlib.Printf.sprintf "cellram-roundtrip-%d-%d" rc wc)
         QCheck.(
           list_size
             (Gen.int_range 1 16)
             (triple bool (int_range 0 ((win * 4) - 1)) (int_bound 0xFFFF_FFFF)))
         check_seq)
  in
  List.iter ~f:run_config [ 4, 3; 5, 2 ];
  [%expect {| |}]
;;

(* ── P3: documented invariants & the chip-pin contract ──────────────────────────── *)

let%expect_test "cellram — a video request does NOT preempt an in-flight CPU write" =
  (* The mirror of the preempt-read test: writes are never preempted (a half-written word
     would corrupt RAM, .mli / [cpu_read_inflight] excludes [op_wr]). A video request
     arriving mid-write must wait until the write retires, then go. *)
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles:4 ~write_cycles:4) in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.vidreq := b1 false;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.cpu_internal := b1 false;
  (* seed the video word (byte 0x100 = word 0x40) *)
  ignore
    (cpu_access
       sim
       inp
       outp
       ~internal:false
       ~adr:0x100
       ~wr:true
       ~ben:false
       ~wdata:0x1357_9BDF
     : int);
  (* start a CPU write of byte 0x200 and let it reach mid-flight — do NOT complete it *)
  inp.mem_pend := b1 true;
  inp.wr := b1 true;
  inp.ben := b1 false;
  inp.adr := Bits.of_unsigned_int ~width:24 0x200;
  inp.wdata := Bits.of_unsigned_int ~width:32 0xCAFE_F00D;
  Cyclesim.cycle sim (* write starts: busy, low halfword phase *);
  Cyclesim.cycle sim (* still mid-write (write_cycles = 4) *);
  (* a video request now arrives mid-write → it must NOT preempt *)
  inp.vidadr := Bits.of_unsigned_int ~width:18 0x40;
  inp.vidreq := b1 true;
  Cyclesim.cycle sim;
  inp.vidreq := b1 false;
  (* record the order: the write's retiring [ce] vs [vid_ack] *)
  let write_ce = ref (-1)
  and vidack = ref (-1)
  and k = ref 0 in
  while (!write_ce < 0 || !vidack < 0) && !k < 80 do
    Cyclesim.cycle sim;
    Int.incr k;
    if !write_ce < 0 && Bits.to_int_trunc !(outp.ce) = 1 then write_ce := !k;
    if !vidack < 0 && Bits.to_int_trunc !(outp.vid_ack) = 1 then vidack := !k
  done;
  inp.mem_pend := b1 false;
  Cyclesim.cycle sim;
  (* read back byte 0x200: the write must have landed intact *)
  let back =
    cpu_access sim inp outp ~internal:false ~adr:0x200 ~wr:false ~ben:false ~wdata:0
  in
  Stdlib.Printf.printf
    "write retired at clk %d, vid_ack at clk %d (write first: %b)   read-back = 0x%X   \
     video word = 0x%X\n"
    !write_ce
    !vidack
    (!write_ce < !vidack)
    back
    (Bits.to_unsigned_int !(outp.viddata));
  [%expect
    {| write retired at clk 5, vid_ack at clk 14 (write first: true)   read-back = 0xCAFEF00D   video word = 0x13579BDF |}]
;;

let%expect_test "cellram — preempt-guard boundary: a video request near a read's end \
                 does not abort it once it is retiring"
  =
  (* preempt is gated by [~:(cnt_zero &: half1)]: a video request that only becomes
     pending once the read has reached its final cycle cannot abort it — the read retires
     on time; an earlier one preempts (the read aborts and restarts much later). We sweep
     the clk at which a one-cycle [vidreq] pulse arrives and tabulate when the read still
     makes its original deadline. The read returns the right data either way — an aborted
     read just restarts, reads being idempotent — so this is purely about the timing
     guard. *)
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let rc = 4
  and wc = 4 in
  let c = measure_latency ~read_cycles:rc ~write_cycles:wc ~wr:false () in
  let run ~vidreq_clk =
    let sim = Sim.create (Tb.create ~read_cycles:rc ~write_cycles:wc) in
    let inp = Cyclesim.inputs sim
    and outp = Cyclesim.outputs sim in
    let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
    inp.vidreq := b1 false;
    inp.vidadr := Bits.of_unsigned_int ~width:18 0;
    inp.cpu_internal := b1 false;
    inp.ben := b1 false;
    (* seed the CPU-read word (byte 0x200) *)
    ignore
      (cpu_access
         sim
         inp
         outp
         ~internal:false
         ~adr:0x200
         ~wr:true
         ~ben:false
         ~wdata:0x5A5A_6B6B
       : int);
    (* start the read; hold [vidreq] high for exactly the clk numbered [vidreq_clk] *)
    inp.mem_pend := b1 true;
    inp.wr := b1 false;
    inp.adr := Bits.of_unsigned_int ~width:24 0x200;
    let read_ce = ref (-1)
    and rdata = ref (-1)
    and k = ref 0 in
    while !read_ce < 0 && !k < 80 do
      inp.vidreq := b1 (!k = vidreq_clk - 1);
      Cyclesim.cycle sim;
      Int.incr k;
      if Bits.to_int_trunc !(outp.ce) = 1
      then (
        read_ce := !k;
        rdata := Bits.to_unsigned_int !(outp.rdata))
    done;
    !read_ce, !rdata
  in
  Stdlib.Printf.printf "an unobstructed read retires at clk %d\n" c;
  List.iter
    [ c + 1; c; c - 1; c - 2; c - 3 ]
    ~f:(fun vc ->
      let read_ce, d = run ~vidreq_clk:vc in
      Stdlib.Printf.printf
        "vidreq on clk %d: read retires at clk %d (on time: %b, data ok: %b)\n"
        vc
        read_ce
        (read_ce = c)
        (d = 0x5A5A_6B6B));
  [%expect
    {|
    an unobstructed read retires at clk 8
    vidreq on clk 9: read retires at clk 8 (on time: true, data ok: true)
    vidreq on clk 8: read retires at clk 8 (on time: true, data ok: true)
    vidreq on clk 7: read retires at clk 25 (on time: false, data ok: true)
    vidreq on clk 6: read retires at clk 24 (on time: false, data ok: true)
    vidreq on clk 5: read retires at clk 23 (on time: false, data ok: true)
    |}]
;;

let%expect_test "cellram — byte-store lane enables at the chip pins (ub_n/lb_n, per lane)"
  =
  (* The byte-lane contract straight at the chip pins (not just transitively through the
     model round-trip): a byte store to byte address b drives its write strobe in halfword
     phase b[1] (mem_adr[0]), enabling the LB lane when b[0]=0 and the UB lane when
     b[0]=1. The other phase enables neither (no spurious write). *)
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2) in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.vidreq := b1 false;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.cpu_internal := b1 false;
  inp.wdata := Bits.of_unsigned_int ~width:32 0x6B6B_6B6B;
  (* probe one byte store: report which (phase, lane) carries the write strobe *)
  let probe ~adr =
    inp.mem_pend := b1 true;
    inp.wr := b1 true;
    inp.ben := b1 true;
    inp.adr := Bits.of_unsigned_int ~width:24 adr;
    let result = ref "(no write strobe seen)"
    and k = ref 0
    and retired = ref false in
    while (not !retired) && !k < 40 do
      Cyclesim.cycle sim;
      Int.incr k;
      let we_n = Bits.to_int_trunc !(outp.we_n) in
      let ub_n = Bits.to_int_trunc !(outp.ub_n) in
      let lb_n = Bits.to_int_trunc !(outp.lb_n) in
      let half = Bits.to_unsigned_int !(outp.mem_adr) land 1 in
      if we_n = 0 && (ub_n = 0 || lb_n = 0)
      then
        result
        := Stdlib.Printf.sprintf
             "phase %d, %s"
             half
             (if lb_n = 0 then "LB lane (byte[7:0])" else "UB lane (byte[15:8])");
      if Bits.to_int_trunc !(outp.ce) = 1 then retired := true
    done;
    inp.mem_pend := b1 false;
    Cyclesim.cycle sim;
    !result
  in
  List.iter [ 0; 1; 2; 3 ] ~f:(fun a ->
    Stdlib.Printf.printf "byte addr %d -> %s\n" a (probe ~adr:a));
  [%expect
    {|
    byte addr 0 -> phase 0, LB lane (byte[7:0])
    byte addr 1 -> phase 0, UB lane (byte[15:8])
    byte addr 2 -> phase 1, LB lane (byte[7:0])
    byte addr 3 -> phase 1, UB lane (byte[15:8])
    |}]
;;

(* ── Write-buffer tests (Phase-10d, [?write_buffer]) ────────────────────────── Same
   closed loop against {!Cellram_model}. The contract under test: a PSRAM store retires in
   ONE ce cycle (the accept), the write drains in the background, and every later read
   still returns the drained data — the qcheck reuses [cpu_access] verbatim, and because
   it issues loads right after stores it hammers the drain-before-read wait continuously.
   The waveform freezes the shape: accept-ce with the port idle, the drain transaction
   behind it, and a read waiting out the slot. *)

let%expect_test "cellram/wbuf — a store retires in one ce cycle; the write drains behind \
                 it; a read waits for the slot [waveform]"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim =
    Sim.create
      ~config:Cyclesim.Config.trace_all
      (Tb.create ~read_cycles:2 ~write_cycles:2 ~write_buffer:true)
  in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  inp.cpu_internal := b1 0;
  inp.vidreq := b1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.ben := b1 0;
  (* store AABBCCDD to 0x100: ce must rise THIS cycle (wb_accept), busy stays 0 until the
     drain launches next cycle *)
  inp.mem_pend := b1 1;
  inp.adr := Bits.of_unsigned_int ~width:24 0x100;
  inp.wr := b1 1;
  inp.wdata := Bits.of_unsigned_int ~width:32 0xAABBCCDD;
  Cyclesim.cycle sim;
  (* the store retired: immediately present the load of the same address — it must wait
     out the drain (drain-before-read), then read back AABBCCDD *)
  inp.wr := b1 0;
  inp.wdata := Bits.of_unsigned_int ~width:32 0;
  for _ = 1 to 14 do
    Cyclesim.cycle sim
  done;
  inp.mem_pend := b1 0;
  Cyclesim.cycle sim;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "wr"
        ; port_name_is ~wave_format:Wave_format.Bit "ce"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "wb_cnt"
        ; port_name_is ~wave_format:Wave_format.Bit "cr_busy"
        ; port_name_is ~wave_format:Wave_format.Hex "rdata"
        ]
    ~wave_width:4
    ~display_width:150
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
    │wr                ││──────────┐                                                                                                                     │
    │                  ││          └─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────│
    │ce                ││──────────┐                                                                                         ┌─────────┐                 │
    │                  ││          └─────────────────────────────────────────────────────────────────────────────────────────┘         └─────────────────│
    │                  ││──────────┬─────────────────────────────────────────────────┬───────────────────────────────────────────────────────────────────│
    │wb_cnt            ││ 0        │1                                                │0                                                                  │
    │                  ││──────────┴─────────────────────────────────────────────────┴───────────────────────────────────────────────────────────────────│
    │cr_busy           ││                    ┌───────────────────────────────────────┐         ┌───────────────────────────────────────┐         ┌───────│
    │                  ││────────────────────┘                                       └─────────┘                                       └─────────┘       │
    │                  ││──────────────────────────────┬─────────┬─────────┬───────────────────┬───────────────────┬─────────────────────────────┬───────│
    │rdata             ││ 00000000                     │CCDD0000 │0000CCDD │AABBCCDD           │CCDDCCDD           │AABBCCDD                     │CCDDCCD│
    │                  ││──────────────────────────────┴─────────┴─────────┴───────────────────┴───────────────────┴─────────────────────────────┴───────│
    └──────────────────┘└────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
    |}]
;;

let%expect_test "cellram/wbuf — 32-bit round-trip through the write buffer: word + byte \
                 stores [qcheck]"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2 ~write_buffer:true) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs ~clock_edge:Before sim in
  inp.vidreq := Bits.of_unsigned_int ~width:1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  let win = 16 in
  let store ~adr ~ben ~wdata =
    ignore (cpu_access sim inp outp ~internal:false ~adr ~wr:true ~ben ~wdata : int)
  in
  let load_word w =
    cpu_access sim inp outp ~internal:false ~adr:(w * 4) ~wr:false ~ben:false ~wdata:0
  in
  let check_seq ops =
    for w = 0 to win - 1 do
      store ~adr:(w * 4) ~ben:false ~wdata:0
    done;
    let model = Array.create ~len:win 0 in
    List.for_all ops ~f:(fun (ben, adr, wdata) ->
      store ~adr ~ben ~wdata;
      let w = adr lsr 2 in
      let l = adr land 3 in
      if ben
      then (
        let byte = (wdata lsr (8 * l)) land 0xFF in
        model.(w) <- model.(w) land lnot (0xFF lsl (8 * l)) lor (byte lsl (8 * l)))
      else model.(w) <- wdata;
      load_word w = model.(w))
  in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:250
       ~name:"cellram-wbuf-roundtrip"
       QCheck.(
         list_size
           (Gen.int_range 1 16)
           (triple bool (int_range 0 ((win * 4) - 1)) (int_bound 0xFFFF_FFFF)))
       check_seq);
  [%expect {| |}]
;;

let%expect_test "cellram/wbuf — retire cost: isolated store 1 cycle, back-to-back second \
                 store waits the drain out"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2 ~write_buffer:true) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs ~clock_edge:Before sim in
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.cpu_internal := b1 false;
  inp.vidreq := b1 false;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  (* cycles from presenting a store to its retiring ce (inclusive) *)
  let store_cost ~adr ~wdata =
    inp.mem_pend := b1 true;
    inp.wr := b1 true;
    inp.ben := b1 false;
    inp.adr := Bits.of_unsigned_int ~width:24 adr;
    inp.wdata := Bits.of_unsigned_int ~width:32 wdata;
    let k = ref 0
    and retired = ref false in
    while (not !retired) && !k < 60 do
      Cyclesim.cycle sim;
      Int.incr k;
      if Bits.to_int_trunc !(outp.ce) = 1 then retired := true
    done;
    !k
  in
  let a = store_cost ~adr:0x40 ~wdata:0x11111111 in
  (* back-to-back: present the second store the very next cycle, slot still draining *)
  let b = store_cost ~adr:0x44 ~wdata:0x22222222 in
  inp.mem_pend := b1 false;
  (* let the second drain finish, then verify both landed *)
  for _ = 1 to 12 do
    Cyclesim.cycle sim
  done;
  let r1 =
    cpu_access sim inp outp ~internal:false ~adr:0x40 ~wr:false ~ben:false ~wdata:0
  in
  let r2 =
    cpu_access sim inp outp ~internal:false ~adr:0x44 ~wr:false ~ben:false ~wdata:0
  in
  Stdlib.Printf.printf
    "isolated store: %d cycle(s)   back-to-back second store: %d cycles   readback \
     0x%08X 0x%08X\n"
    a
    b
    r1
    r2;
  [%expect
    {| isolated store: 1 cycle(s)   back-to-back second store: 6 cycles   readback 0x11111111 0x22222222 |}]
;;

let%expect_test "cellram/wbuf — a store is accepted 0-stall even while the port serves a \
                 video read; both complete correctly"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim = Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2 ~write_buffer:true) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs ~clock_edge:Before sim in
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.cpu_internal := b1 false;
  inp.vidreq := b1 false;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0x20;
  (* seed the video word, then let the buffer drain *)
  ignore
    (cpu_access
       sim
       inp
       outp
       ~internal:false
       ~adr:0x80
       ~wr:true
       ~ben:false
       ~wdata:0xFEEDF00D
     : int);
  for _ = 1 to 12 do
    Cyclesim.cycle sim
  done;
  (* kick a video read of 0x20 (word addr = byte 0x80) and present a CPU store the next
     cycle, while the port is mid-video-op: the store must still retire in 1 ce cycle *)
  inp.vidreq := b1 true;
  Cyclesim.cycle sim;
  inp.vidreq := b1 false;
  inp.mem_pend := b1 true;
  inp.wr := b1 true;
  inp.ben := b1 false;
  inp.adr := Bits.of_unsigned_int ~width:24 0xC0;
  inp.wdata := Bits.of_unsigned_int ~width:32 0x0DDBA11;
  let k = ref 0
  and retired = ref false
  and vid = ref (-1) in
  while ((not !retired) || !vid < 0) && !k < 80 do
    Cyclesim.cycle sim;
    Int.incr k;
    if (not !retired) && Bits.to_int_trunc !(outp.ce) = 1
    then (
      Stdlib.Printf.printf "store retired after %d cycle(s)\n" !k;
      retired := true;
      inp.mem_pend := b1 false;
      inp.wr := b1 false);
    if Bits.to_int_trunc !(outp.vid_ack) = 1
    then vid := Bits.to_unsigned_int !(outp.viddata)
  done;
  for _ = 1 to 12 do
    Cyclesim.cycle sim
  done;
  let r =
    cpu_access sim inp outp ~internal:false ~adr:0xC0 ~wr:false ~ben:false ~wdata:0
  in
  Stdlib.Printf.printf "video word 0x%08X   stored word 0x%08X\n" !vid r;
  [%expect
    {|
    store retired after 1 cycle(s)
    video word 0xFEEDF00D   stored word 0x00DDBA11
    |}]
;;

(* ── Depth-2 FIFO tests ([?wbuf_depth]) ────────────────────────────────────── The
   depth-1 contract is pinned above (and depth 1 is cycle-identical to the proven
   Phase-10d slot — the frozen expects there did not move when the slot became a FIFO).
   Here: a burst of two stores retires back-to-back 0-stall, the third waits; same-address
   stores land in FIFO order (the younger wins); and the depth-2 qcheck round-trip. *)

let%expect_test "cellram/wbuf depth-2 — two stores retire back-to-back, the third waits; \
                 same-address order preserved"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim =
    Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2 ~write_buffer:true ~wbuf_depth:2)
  in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs ~clock_edge:Before sim in
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.cpu_internal := b1 false;
  inp.vidreq := b1 false;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  let store_cost ~adr ~wdata =
    inp.mem_pend := b1 true;
    inp.wr := b1 true;
    inp.ben := b1 false;
    inp.adr := Bits.of_unsigned_int ~width:24 adr;
    inp.wdata := Bits.of_unsigned_int ~width:32 wdata;
    let k = ref 0
    and retired = ref false in
    while (not !retired) && !k < 60 do
      Cyclesim.cycle sim;
      Int.incr k;
      if Bits.to_int_trunc !(outp.ce) = 1 then retired := true
    done;
    !k
  in
  let a = store_cost ~adr:0x40 ~wdata:0x11111111 in
  let b = store_cost ~adr:0x44 ~wdata:0x22222222 in
  let c = store_cost ~adr:0x48 ~wdata:0x33333333 in
  (* same-address pair through the FIFO: the younger store must win *)
  let d = store_cost ~adr:0x4C ~wdata:0xAAAAAAAA in
  let e = store_cost ~adr:0x4C ~wdata:0xBBBBBBBB in
  inp.mem_pend := b1 false;
  for _ = 1 to 24 do
    Cyclesim.cycle sim
  done;
  let rd adr =
    cpu_access sim inp outp ~internal:false ~adr ~wr:false ~ben:false ~wdata:0
  in
  Stdlib.Printf.printf
    "store costs: 1st %d  2nd %d  3rd %d  (then same-addr pair %d, %d)\n"
    a
    b
    c
    d
    e;
  Stdlib.Printf.printf
    "readback: 0x%08X 0x%08X 0x%08X   same-addr final 0x%08X\n"
    (rd 0x40)
    (rd 0x44)
    (rd 0x48)
    (rd 0x4C);
  [%expect
    {|
    store costs: 1st 1  2nd 1  3rd 5  (then same-addr pair 5, 5)
    readback: 0x11111111 0x22222222 0x33333333   same-addr final 0xBBBBBBBB
    |}]
;;

let%expect_test "cellram/wbuf depth-2 — 32-bit round-trip: word + byte stores [qcheck]" =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  let sim =
    Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2 ~write_buffer:true ~wbuf_depth:2)
  in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs ~clock_edge:Before sim in
  inp.vidreq := Bits.of_unsigned_int ~width:1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  let win = 16 in
  let store ~adr ~ben ~wdata =
    ignore (cpu_access sim inp outp ~internal:false ~adr ~wr:true ~ben ~wdata : int)
  in
  let load_word w =
    cpu_access sim inp outp ~internal:false ~adr:(w * 4) ~wr:false ~ben:false ~wdata:0
  in
  let check_seq ops =
    for w = 0 to win - 1 do
      store ~adr:(w * 4) ~ben:false ~wdata:0
    done;
    let model = Array.create ~len:win 0 in
    List.for_all ops ~f:(fun (ben, adr, wdata) ->
      store ~adr ~ben ~wdata;
      let w = adr lsr 2 in
      let l = adr land 3 in
      if ben
      then (
        let byte = (wdata lsr (8 * l)) land 0xFF in
        model.(w) <- model.(w) land lnot (0xFF lsl (8 * l)) lor (byte lsl (8 * l)))
      else model.(w) <- wdata;
      load_word w = model.(w))
  in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:250
       ~name:"cellram-wbuf2-roundtrip"
       QCheck.(
         list_size
           (Gen.int_range 1 16)
           (triple bool (int_range 0 ((win * 4) - 1)) (int_bound 0xFFFF_FFFF)))
       check_seq);
  [%expect {| |}]
;;

(* ── 2a: himem addressing ([1 MB, 16 MB) reachable) ─────────────────────────── DOOM.md §3:
   the core already emits 24-bit byte addresses; 2a widened the controller's word address
   from 18 bits (1 MB) to 22 bits (16 MiB) so the DOOM blob/zone/WAD in himem are real
   locations, distinct from their former low-1 MB aliases. Oberon is untouched (still a 1 MB
   machine); only anything driving a high [adr] sees the difference. *)

let%expect_test "cellram/2a — himem [1 MB, 16 MB) is addressable and distinct from low \
                 memory"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  (* back 4 MiB so a few himem words round-trip (the real chip is 16 MiB); the default 1
     MB model can't hold them. *)
  let sim = Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2 ~addr_bits:22) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.vidreq := Bits.of_unsigned_int ~width:1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  let store adr wdata =
    ignore (cpu_access sim inp outp ~internal:false ~adr ~wr:true ~ben:false ~wdata : int)
  in
  let load adr =
    cpu_access sim inp outp ~internal:false ~adr ~wr:false ~ben:false ~wdata:0
  in
  (* the crux of 2a: under the old 18-bit mask (adr[19:2] drops bit 20+) byte 0x100000 and
     byte 0 shared one word address, so a himem store clobbered low memory. Widened to
     adr[23:2] they are distinct. 0x300000 sets word-address bits 20 and 21 together. *)
  store 0x000000 0x11111111;
  store 0x100000 0x22222222;
  store 0x300000 0x33333333;
  Stdlib.Printf.printf "low   0x000000 = 0x%08X\n" (load 0x000000);
  Stdlib.Printf.printf "himem 0x100000 = 0x%08X\n" (load 0x100000);
  Stdlib.Printf.printf "himem 0x300000 = 0x%08X\n" (load 0x300000);
  [%expect
    {|
    low   0x000000 = 0x11111111
    himem 0x100000 = 0x22222222
    himem 0x300000 = 0x33333333
    |}]
;;

let%expect_test "cellram/2a — the full 22-bit word address reaches the PSRAM pins" =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  (* pins only — the default 1 MB model is fine (a high store aliases in it harmlessly);
     mem_adr carries the true 22-bit word address to the (16 MiB) chip regardless. *)
  let sim = Sim.create (Tb.create ~read_cycles:2 ~write_cycles:2) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 (if v then 1 else 0) in
  inp.vidreq := b1 false;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  inp.cpu_internal := b1 false;
  inp.ben := b1 false;
  inp.wdata := Bits.of_unsigned_int ~width:32 0;
  (* the phase-0 word address the controller drives for a store to [adr]: capture mem_adr
     while WE is asserted in the low halfword phase (mem_adr[0] = 0), then drop the half. *)
  let pin_word adr =
    inp.mem_pend := b1 true;
    inp.wr := b1 true;
    inp.adr := Bits.of_unsigned_int ~width:24 adr;
    let seen = ref (-1)
    and k = ref 0 in
    while !seen < 0 && !k < 40 do
      Cyclesim.cycle sim;
      Int.incr k;
      let we_n = Bits.to_int_trunc !(outp.we_n) in
      let ma = Bits.to_unsigned_int !(outp.mem_adr) in
      if we_n = 0 && ma land 1 = 0 then seen := ma lsr 1
    done;
    inp.mem_pend := b1 false;
    Cyclesim.cycle sim;
    !seen
  in
  (* addresses exercising each formerly-masked bit up to adr[23]; 0xFFBFFC is the top RAM
     word just below the ROM region (adr[23:14] = 0x3FF). *)
  List.iter [ 0x000004; 0x100000; 0x800000; 0xE00000; 0xFFBFFC ] ~f:(fun a ->
    let w = pin_word a in
    Stdlib.Printf.printf
      "byte 0x%06X -> mem_adr word 0x%06X (expect 0x%06X, ok: %b)\n"
      a
      w
      (a lsr 2)
      (w = a lsr 2));
  [%expect
    {|
    byte 0x000004 -> mem_adr word 0x000001 (expect 0x000001, ok: true)
    byte 0x100000 -> mem_adr word 0x040000 (expect 0x040000, ok: true)
    byte 0x800000 -> mem_adr word 0x200000 (expect 0x200000, ok: true)
    byte 0xE00000 -> mem_adr word 0x380000 (expect 0x380000, ok: true)
    byte 0xFFBFFC -> mem_adr word 0x3FEFFF (expect 0x3FEFFF, ok: true)
    |}]
;;

let%expect_test "cellram/wbuf 2a — himem round-trip through the shipped write buffer \
                 (depth 2)"
  =
  let module Sim = Cyclesim.With_interface (Tb.I) (Tb.O) in
  (* the board's shipped memory config — write_buffer, depth 2 — over a 4 MiB model, so a
     himem store captured into the FIFO and drained back exercises the [wb_word] 22-bit
     widening on the exact path the board runs. Wbuf ce is input-driven ⇒
     [~clock_edge:Before] (the Phase-10d harness lesson). *)
  let sim =
    Sim.create
      (Tb.create
         ~read_cycles:2
         ~write_cycles:2
         ~write_buffer:true
         ~wbuf_depth:2
         ~addr_bits:22)
  in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs ~clock_edge:Before sim in
  inp.vidreq := Bits.of_unsigned_int ~width:1 0;
  inp.vidadr := Bits.of_unsigned_int ~width:18 0;
  let store adr wdata =
    ignore (cpu_access sim inp outp ~internal:false ~adr ~wr:true ~ben:false ~wdata : int)
  in
  let load adr =
    cpu_access sim inp outp ~internal:false ~adr ~wr:false ~ben:false ~wdata:0
  in
  (* a low word and two himem words drain through the FIFO and read back distinct —
     0x100000 is word 0's alias under the old 18-bit mask, 0x2AAAA8 sets a scattered high
     bit pattern *)
  store 0x000000 0x0000000F;
  store 0x100000 0xCAFEBABE;
  store 0x2AAAA8 0x5A5A5A5A;
  Stdlib.Printf.printf "low   0x000000 = 0x%08X\n" (load 0x000000);
  Stdlib.Printf.printf "himem 0x100000 = 0x%08X\n" (load 0x100000);
  Stdlib.Printf.printf "himem 0x2AAAA8 = 0x%08X\n" (load 0x2AAAA8);
  [%expect
    {|
    low   0x000000 = 0x0000000F
    himem 0x100000 = 0xCAFEBABE
    himem 0x2AAAA8 = 0x5A5A5A5A
    |}]
;;
