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

let create ?(read_cycles = 2) ?(write_cycles = 2) (i : _ I.t) : _ O.t =
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
  let req_word = Always.Variable.reg spec ~width:18 in
  let req_ben = Always.Variable.reg spec ~width:1 in
  let req_lane = Always.Variable.reg spec ~width:2 in
  let req_wdata = Always.Variable.reg spec ~width:32 in
  let viddata_reg = Always.Variable.reg spec ~width:32 in
  let vid_pending = Always.Variable.reg spec ~width:1 in
  let busy_v = busy.value -- "cr_busy" in
  let op_vid_v = op_vid.value in
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
  (* ── Combinational status ── *)
  let is_write = op_wr_v &: ~:op_vid_v in
  let cnt_zero = cnt_v ==:. 0 in
  let half1 = half_v ==:. 1 in
  let vid_complete = busy_v &: op_vid_v &: cnt_zero &: half1 in
  let cpu_complete_psram = busy_v &: ~:op_vid_v &: cnt_zero &: half1 in
  (* an on-chip access (ROM/MMIO) needs no PSRAM and finishes the cycle it is requested *)
  let cpu_complete_internal = i.mem_pend &: i.cpu_internal in
  (* the CPU advances when it wants no memory (compute stall), or its access just
     completed *)
  let ce = ~:(i.mem_pend) |: cpu_complete_psram |: cpu_complete_internal in
  (* arbiter: video wins the port; a CPU access starts only if it actually needs PSRAM *)
  let start_vid = ~:busy_v &: vid_pending_v in
  let start_cpu = ~:busy_v &: ~:vid_pending_v &: i.mem_pend &: ~:(i.cpu_internal) in
  (* Preemptible CPU reads. A framebuffer fetch has a hard ~477 ns raster deadline
     ([Vid]'s [req0]→[xfer]); the worst case is it arriving just after a CPU access
     grabbed the port and having to wait the whole access out. So if a video request lands
     while a CPU READ is mid-flight (and not already completing this cycle), abort the
     read and let video go at once — the core is frozen on [ce] and never saw it retire,
     so it just re-arbitrates and restarts after. Reads are idempotent, so aborting costs
     only the few wasted cycles (re-earned before the next group's request, ~12 clk away).
     WRITES are never preempted — a half-written word would corrupt RAM. This removes the
     arbiter-wait term from the video deadline; the residual flicker / contention crashes
     live there (PHASE7 §9.2). *)
  let cpu_read_inflight = busy_v &: ~:op_vid_v &: ~:op_wr_v in
  let preempt =
    (cpu_read_inflight &: vid_pending_v &: ~:(cnt_zero &: half1)) -- "preempt"
  in
  let half_cnt_init is_wr =
    mux2 is_wr (cval (write_cycles - 1)) (cval (read_cycles - 1))
  in
  let new_word = i.mem_dq_i @: lo_v in
  Always.(
    compile
      [ if_
          busy_v
          [ if_
              preempt
              (* a video request arrived mid-CPU-read → abort; Idle picks video next cycle *)
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
          [ (* Idle: video first, else a PSRAM-bound CPU access *)
            if_
              start_vid
              [ busy <--. 1
              ; op_vid <--. 1
              ; op_wr <--. 0
              ; req_word <-- i.vidadr
              ; half <--. 0
              ; cnt <-- cval (read_cycles - 1)
              ]
              [ when_
                  start_cpu
                  [ busy <--. 1
                  ; op_vid <--. 0
                  ; op_wr <-- i.wr
                  ; req_word <-- select i.adr ~high:19 ~low:2
                  ; req_ben <-- i.ben
                  ; req_lane <-- select i.adr ~high:1 ~low:0
                  ; req_wdata <-- i.wdata
                  ; half <--. 0
                  ; cnt <-- half_cnt_init i.wr
                  ]
              ]
          ]
      ; (* latch a video request until it is serviced *)
        vid_pending <-- (i.vidreq |: (vid_pending_v &: ~:vid_complete))
      ]);
  (* ── PSRAM pins ── address [{req_word, half}]; data the current half of the store word;
     control active during [busy]: CE always, OE on reads, WE pulsed on writes (high at
     [cnt_zero] so it rises before the address moves), byte enables per word/byte store. *)
  let mem_adr = uresize (req_word_v @: half_v) ~width:23 in
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

  let create ?read_cycles ?write_cycles (i : _ I.t) : _ O.t =
    let dq_i = wire 16 in
    let c =
      cr_create
        ?read_cycles
        ?write_cycles
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
    ~wave_width:2
    ~display_width:90
    waves;
  [%expect
    {|
    ┌Signals───────────┐┌Waves───────────────────────────────────────────────────────────────┐
    │wr                ││──────────────────────────────────────────┐                         │
    │                  ││                                          └─────────────────────────│
    │ce                ││                        ┌─────┐                       ┌─────┐       │
    │                  ││────────────────────────┘     └───────────────────────┘     └───────│
    │cr_busy           ││      ┌───────────────────────┐     ┌───────────────────────┐     ┌─│
    │                  ││──────┘                       └─────┘                       └─────┘ │
    │                  ││────────────┬─────┬─────┬───────────┬───────────┬─────────────────┬─│
    │rdata             ││ 00000000   │CCDD.│0000.│AABBCCDD   │CCDDCCDD   │AABBCCDD         │C│
    │                  ││────────────┴─────┴─────┴───────────┴───────────┴─────────────────┴─│
    └──────────────────┘└────────────────────────────────────────────────────────────────────┘
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
