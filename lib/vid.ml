(* Public API and behaviour spec live in [vid.mli].

   Port of [VID60.v]. Two clock domains — and per AGENT.md §3 the clock *generation* (the
   Xilinx [DCM]/[BUFG]) is the Phase-7 board shim, so they are dropped and [pclk] is an
   input here:

   - [pclk] (65 MHz) — the raster. Free-running counters [hcnt] (0..1343) and [vcnt]
     (0..805) walk the 1024x768 + blanking frame; [hsync]/[vsync] are pulse latches; the
     32-bit [pixbuf] shifts out one pixel per tick and reloads a fresh word every 32 px.
   - [clk] (25 MHz) — the framebuffer DMA. A one-cycle request [req] (= core [stallX])
     reads a word per 32 px into a ping-pong buffer ([buf0]/[buf1]), which [pixbuf] loads
     at [xfer]. The request is issued ONE GROUP EARLY (a prefetch —
     [next_col]/[next_vcnt]) so the read has ~2 group-times to land; this is a deliberate
     departure from [VID60.v]'s single-[vidbuf], 31-px-deadline fetch, added to kill
     PSRAM-contention flicker on the board (see [vid.mli]). The pixel/sync datapath
     downstream of the buffer is unchanged.

   Comparator-free range tests, straight from the RTL: [vcnt >= 768] is
   [vcnt[9] & vcnt[8]] ([vblank]) and [hcnt >= 1024] is [hcnt[10]] ([hblank]) — the
   constants are chosen so a magnitude compare collapses to a single bit.

   The pulse latch [x <= start | x & ~stop] is an SR latch folded into one flop: set at
   [start], hold, clear at [stop]. The sync offsets ([1032+31], [1176+31] etc.) delay the
   pulses to track the pixel-pipeline latency ([xfer] lands at [hcnt[4:0] = 31]).

   CDC — the one structural departure from the RTL (see [vid.mli]). [req0] is a 1-[pclk]
   pulse at the start of each 32-px group; the DMA consumes it in the [clk] domain. The
   RTL catches it with a clk-domain async-set flop ([req1],
   [always @(posedge req0, posedge clk)]), which Cyclesim can't represent. We use the
   standard metastability-safe crossing instead — a TOGGLE pulse synchroniser
   ([req_toggle] in [pclk] → a [sync0]/[sync1]/[sync2] [clk] synchroniser → edge-detect
   [req]); see the body. Same one-req-per-[req0] behaviour, and — unlike the earlier
   [caught]+feedback handshake, which sampled a [pclk] flop in [clk] with no synchroniser
   — safe across the real asynchronous pclk/clk on silicon. *)

open! Base
open Hardcaml
open Signal

(* RGBW from [RISC5Top]'s [VID #(.RGBW(6))]; the 1 bpp pixel is replicated this wide. *)
let rgbw = 6

module I = struct
  type 'a t =
    { clk : 'a
    ; pclk : 'a
    ; inv : 'a [@bits 1]
    ; viddata : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { req : 'a [@bits 1]
    ; vidadr : 'a [@bits 18]
    ; hsync : 'a [@bits 1]
    ; vsync : 'a [@bits 1]
    ; rgb : 'a [@bits rgbw]
    }
  [@@deriving hardcaml]
end

(* framebuffer base Org = DFF00H >> 2 (word address); rows 0..255 sit off-screen *)
let org = 0x37FC0

(* Toggle pulse synchroniser — cross a 1-cycle [pulse] in the [src_spec] clock domain into
   the [dst_spec] domain as a 1-cycle pulse, metastability-safe. [pulse] TOGGLES a flop in
   the source domain (so the request becomes a LEVEL change, never a narrow pulse a
   sampling flop could miss); the level crosses a 3-FF [dst_spec] synchroniser ([sync0]
   absorbs any metastability, [sync1]/[sync2] are settled); an edge-detect on the two
   SETTLED flops regenerates exactly one [dst_spec] pulse. Safe by construction provided
   [pulse] recurs slower than the synchroniser depth (in [vid], every 32 px ≈ 12 [clk] ≫
   3). The metastability-safe substitute for VID60.v's async-set capture [req1]
   (unrepresentable in Cyclesim — see [vid.mli]); proven no-loss/no-spurious for all
   clk/pclk phases in test/formal (the [vid_invariant] @formal check). The [sync0]/[sync1]
   flops want an ASYNC_REG / CDC constraint in the board [.xdc]. *)
let pulse_sync ~src_spec ~dst_spec ~pulse =
  let req_toggle = reg_fb src_spec ~width:1 ~f:(fun t -> t ^: pulse) -- "req_toggle" in
  let sync0 = reg dst_spec req_toggle -- "sync0" in
  let sync1 = reg dst_spec sync0 -- "sync1" in
  let sync2 = reg dst_spec sync1 -- "sync2" in
  (sync1 ^: sync2) -- "req"
;;

(* Look-ahead framebuffer addressing — the prefetch's one ADDRESS departure from [VID60.v]
   (whose [vidadr] is the CURRENT group, [{~vcnt, hcnt[9:5]}]). From the raster position
   it computes the NEXT consumed 32-px group — next column, wrapping at column 31 to
   column 0 of the next VISIBLE row, and the last visible row (767) to row 0 (skipping
   vblank) — and packs its word address [vidadr] = [Org + {~next_vcnt, next_col}]. [wpar]
   is the ping-pong write parity (= the bank that group's fetch lands in, [lsb next_col]).
   Purely combinational in [hcnt]/[vcnt]; shared by [create] and the [vid_addr] formal
   check, which proves it ≡ an independent geometry spec over ALL (hcnt, vcnt) — the
   addressing half of prefetch delivery (test/formal/README "VID prefetch"). *)
module Lookahead = struct
  type 'a t =
    { next_col : 'a
    ; next_vcnt : 'a
    ; vidadr : 'a
    ; wpar : 'a
    }
end

let lookahead ~hcnt ~vcnt =
  let col = select hcnt ~high:9 ~low:5 -- "col" in
  let col_last = col ==:. 31 in
  let next_col = mux2 col_last (zero 5) (col +:. 1) -- "next_col" in
  let next_vcnt =
    mux2 col_last (mux2 (vcnt ==:. 767) (zero 10) (vcnt +:. 1)) vcnt -- "next_vcnt"
  in
  let vidadr =
    of_unsigned_int ~width:18 org +: concat_msb [ zero 3; ~:next_vcnt; next_col ]
  in
  { Lookahead.next_col; next_vcnt; vidadr; wpar = lsb next_col }
;;

let create ?viddata_valid ?viddata_par (i : _ I.t) : _ O.t =
  let pspec = Reg_spec.create () ~clock:i.pclk in
  let cspec = Reg_spec.create () ~clock:i.clk in
  (* ── pclk domain: raster counters ─────────────────────────────────────────── *)
  let hcnt =
    reg_fb pspec ~width:11 ~f:(fun h -> mux2 (h ==:. 1343) (zero 11) (h +:. 1)) -- "hcnt"
  in
  let hend = hcnt ==:. 1343 in
  let vcnt =
    reg_fb pspec ~width:10 ~f:(fun v ->
      mux2 hend (mux2 (v ==:. 805) (zero 10) (v +:. 1)) v)
    -- "vcnt"
  in
  (* comparator-free blanking *)
  let vblank = (bit vcnt ~pos:8 &: bit vcnt ~pos:9) -- "vblank" in
  let hblank = bit hcnt ~pos:10 in
  (* look-ahead framebuffer addressing (the prefetch's address departure from [VID60.v] —
     see [lookahead] above and [vid.mli]): the request targets the NEXT consumed group, so
     [la.vidadr] is the look-ahead word address and [la.wpar] the ping-pong write bank. *)
  let la = lookahead ~hcnt ~vcnt in
  (* request the next word at the start of each visible 32-px group; transfer it 31 px on *)
  let req0 = (sel_bottom hcnt ~width:5 ==:. 0 &: ~:hblank &: ~:vblank) -- "req0" in
  let xfer = sel_bottom hcnt ~width:5 ==:. 31 in
  (* pclk→clk request synchroniser ([pulse_sync] above): cross the 1-pclk [req0] fetch
     pulse into the clk DMA domain as a 1-clk [req]. The metastability-safe substitute for
     VID60.v's async-set [req1] (a literal pclk-flop-sampled-in-clk crossing, as the
     Phase-6 [caught]+feedback handshake did, is deterministic in sim but metastable on
     silicon — horizontal pixel tearing). Proven no-loss/no-spurious for all phases in
     test/formal. *)
  let req = pulse_sync ~src_spec:pspec ~dst_spec:cspec ~pulse:req0 in
  (* Prefetch double-buffer (ping-pong). The fetched word lands in [buf0] or [buf1] chosen
     by the requested column's parity; [pixbuf] reads the matching buffer at [xfer]
     (below). Because the request is issued one group EARLY ([next_col] above), each fetch
     now has ~2 group-times (~970 ns) to complete instead of one (~480 ns) — the board's
     flicker fix. A buffer is read every other group, so it survives a slow (contended)
     fetch.

     [viddata_valid] latches the word: single-cycle memory (the sim [Soc] cycle-steal) has
     it valid the cycle [req] fires (the default); the board's [Cellram] returns it some
     cycles later on its [vid_ack]. [viddata_par] selects the write buffer: [Cellram]
     supplies the parity of the fetch it is COMPLETING (robust to a late, contended
     completion landing in a later group); the default — the live request parity [la.wpar]
     (= [lsb next_col]) — is exact for the single-cycle path, where the fetch retires in
     its own group. *)
  let valid = Option.value viddata_valid ~default:req in
  let wpar = Option.value viddata_par ~default:la.wpar in
  let buf0 = reg ~enable:(valid &: ~:wpar) cspec i.viddata -- "buf0" in
  let buf1 = reg ~enable:(valid &: wpar) cspec i.viddata -- "buf1" in
  (* ── pclk domain: pixel shift register + sync/blank latches ────────────────── *)
  (* the word feeding [pixbuf] this group: the ping-pong bank selected by parity [hcnt[5]]
     (the native raster group-parity at [xfer], matching the parity the fetch wrote).
     Named [vidbuf] — it plays the exact role of VID60.v's [vidbuf] (the word [pixbuf]
     loads), so the Phase-8 equiv pairs it as the shared cut point (see
     test/formal/proofs/vid.ys.template). *)
  let vidbuf = mux2 (bit hcnt ~pos:5) buf1 buf0 -- "vidbuf" in
  let pixbuf =
    reg_fb pspec ~width:32 ~f:(fun p ->
      mux2 xfer vidbuf (concat_msb [ gnd; select p ~high:31 ~low:1 ]))
    -- "pixbuf"
  in
  let hs =
    reg_fb pspec ~width:1 ~f:(fun hs -> hcnt ==:. 1063 |: (hs &: (hcnt <>:. 1207)))
    -- "hs"
  in
  let vs =
    reg_fb pspec ~width:1 ~f:(fun vs -> vcnt ==:. 771 |: (vs &: (vcnt <>:. 777))) -- "vs"
  in
  let blank =
    reg_fb pspec ~width:1 ~f:(fun b -> mux2 xfer (vblank |: hblank) b) -- "blank"
  in
  (* ── outputs ───────────────────────────────────────────────────────────────── *)
  (* displayed pixel: framebuffer bit [pixbuf[0]] XOR [inv] ([^:] binds tighter than
     [&:]), forced dark outside the visible region *)
  let pixel = lsb pixbuf ^: i.inv &: ~:blank in
  (* [la.vidadr]: look-ahead framebuffer word address (one group early — see [lookahead]) *)
  { O.req
  ; vidadr = la.vidadr
  ; hsync = ~:hs
  ; vsync = ~:vs
  ; rgb = repeat pixel ~count:rgbw
  }
;;

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────────── VID
   is two-clock, so the sim runs under [By_input_clocks] at the real 65:25 ratio ([pclk]
   period 5, [clk] period 13); each [Cyclesim.cycle] is one fine base tick. We freeze TEXT
   tables, not waveterm — waveforms render unreliably under multi-clock (see the
   cyclesim-multiclock-and-cdc memory). The exhaustive bit-for-bit fidelity check vs
   [VID60.v] is the Verilator co-sim. *)

let sim_config =
  { Cyclesim.Config.trace_all with
    clock_mode =
      Cyclesim.Config.Clock_mode.By_input_clocks
        (Cyclesim_clock_domain.create_list [ "clk", 13; "pclk", 5 ])
  }
;;

let make () =
  let module Sim = Cyclesim.With_interface (I) (O) in
  Sim.create ~config:sim_config create
;;

(* a labelled, traced internal node, and its current value *)
let node sim name =
  match Cyclesim.lookup_node_or_reg_by_name sim name with
  | Some n -> n
  | None -> failwith ("vid test: no traced node " ^ name)
;;

let peek sim name = Cyclesim.Node.to_int (node sim name)
let bits1 b = Bits.of_unsigned_int ~width:1 (if b then 1 else 0)
let word w = Bits.of_unsigned_int ~width:32 w

let%expect_test "vid — smoke: counters run, req fires, pixels shift out" =
  let sim = make () in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.inv := bits1 false;
  inp.viddata := word 0xFFFF0000;
  let reqs = ref 0
  and prev = ref 0
  and saw0 = ref false
  and saw1 = ref false in
  for _ = 1 to 600 do
    Cyclesim.cycle sim;
    let r = Bits.to_int_trunc !(outp.req) in
    if r = 1 && !prev = 0 then Int.incr reqs;
    prev := r;
    if Bits.to_int_trunc !(outp.rgb) = 0 then saw0 := true else saw1 := true
  done;
  Stdlib.Printf.printf
    "hcnt=%d vcnt=%d  req pulses=%d  rgb saw 0=%b saw 1=%b\n"
    (peek sim "hcnt")
    (peek sim "vcnt")
    !reqs
    !saw0
    !saw1;
  [%expect {| hcnt=120 vcnt=0  req pulses=4  rgb saw 0=true saw 1=true |}]
;;

let%expect_test "vid — CDC: req0 pulse crosses pclk→clk via the toggle synchroniser" =
  let sim = make () in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.inv := bits1 false;
  inp.viddata := word 0xDEADBEEF;
  (* At power-on [hcnt = 0], so [req0] fires at once (prefetching column 1, parity 1, so
     the word lands in [buf1]). Watch [req_toggle] flip in the [pclk] domain, the level
     cross the [sync0]→[sync1] clk synchroniser, the edge-detect [req = sync1 ^ sync2]
     fire for one clk cycle, then [buf1] grab [viddata]. NB [req0] is combinational
     ([hcnt[4:0] = 0]); the trace samples it one base-tick behind [hcnt]'s registered
     update (a Cyclesim trace-phase artifact, not hardware). *)
  Stdlib.Printf.printf "tick | hcnt req0 toggle sync0 sync1 req | buf1\n";
  for t = 0 to 44 do
    Cyclesim.cycle sim;
    Stdlib.Printf.printf
      "%4d |  %2d    %d     %d      %d     %d    %d | %08X\n"
      t
      (peek sim "hcnt")
      (peek sim "req0")
      (peek sim "req_toggle")
      (peek sim "sync0")
      (peek sim "sync1")
      (Bits.to_int_trunc !(outp.req))
      (peek sim "buf1")
  done;
  [%expect
    {|
    tick | hcnt req0 toggle sync0 sync1 req | buf1
       0 |   0    1     0      0     0    0 | 00000000
       1 |   0    1     0      0     0    0 | 00000000
       2 |   0    1     0      0     0    0 | 00000000
       3 |   0    1     0      0     0    0 | 00000000
       4 |   1    1     1      0     0    0 | 00000000
       5 |   1    0     1      0     0    0 | 00000000
       6 |   1    0     1      0     0    0 | 00000000
       7 |   1    0     1      0     0    0 | 00000000
       8 |   1    0     1      0     0    0 | 00000000
       9 |   2    0     1      0     0    0 | 00000000
      10 |   2    0     1      0     0    0 | 00000000
      11 |   2    0     1      0     0    0 | 00000000
      12 |   2    0     1      1     0    0 | 00000000
      13 |   2    0     1      1     0    0 | 00000000
      14 |   3    0     1      1     0    0 | 00000000
      15 |   3    0     1      1     0    0 | 00000000
      16 |   3    0     1      1     0    0 | 00000000
      17 |   3    0     1      1     0    0 | 00000000
      18 |   3    0     1      1     0    0 | 00000000
      19 |   4    0     1      1     0    0 | 00000000
      20 |   4    0     1      1     0    0 | 00000000
      21 |   4    0     1      1     0    0 | 00000000
      22 |   4    0     1      1     0    0 | 00000000
      23 |   4    0     1      1     0    0 | 00000000
      24 |   5    0     1      1     0    0 | 00000000
      25 |   5    0     1      1     1    1 | 00000000
      26 |   5    0     1      1     1    1 | 00000000
      27 |   5    0     1      1     1    1 | 00000000
      28 |   5    0     1      1     1    1 | 00000000
      29 |   6    0     1      1     1    1 | 00000000
      30 |   6    0     1      1     1    1 | 00000000
      31 |   6    0     1      1     1    1 | 00000000
      32 |   6    0     1      1     1    1 | 00000000
      33 |   6    0     1      1     1    1 | 00000000
      34 |   7    0     1      1     1    1 | 00000000
      35 |   7    0     1      1     1    1 | 00000000
      36 |   7    0     1      1     1    1 | 00000000
      37 |   7    0     1      1     1    1 | 00000000
      38 |   7    0     1      1     1    0 | DEADBEEF
      39 |   8    0     1      1     1    0 | DEADBEEF
      40 |   8    0     1      1     1    0 | DEADBEEF
      41 |   8    0     1      1     1    0 | DEADBEEF
      42 |   8    0     1      1     1    0 | DEADBEEF
      43 |   8    0     1      1     1    0 | DEADBEEF
      44 |   9    0     1      1     1    0 | DEADBEEF
    |}]
;;

let%expect_test "vid — every req0 pulse yields exactly one req (no CDC drops)" =
  let sim = make () in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.inv := bits1 false;
  inp.viddata := word 0;
  let req0_node = node sim "req0" in
  let req0s = ref 0
  and reqs = ref 0
  and p0 = ref 0
  and pr = ref 0 in
  for _ = 1 to 6000 do
    Cyclesim.cycle sim;
    let r0 = Cyclesim.Node.to_int req0_node
    and r = Bits.to_int_trunc !(outp.req) in
    if r0 = 1 && !p0 = 0 then Int.incr req0s;
    if r = 1 && !pr = 0 then Int.incr reqs;
    p0 := r0;
    pr := r
  done;
  Stdlib.Printf.printf "over 6000 ticks: req0 pulses = %d, req pulses = %d\n" !req0s !reqs;
  [%expect {| over 6000 ticks: req0 pulses = 32, req pulses = 32 |}]
;;

(* fill the pipeline, align to a freshly-loaded visible group ([hcnt[4:0] = 0]), then read
   32 pixels one [pclk] apart — reconstructing the displayed word LSB-first. Align on a
   STEADY-STATE line ([vcnt >= 2]): the two-group prefetch leaves the very first group of
   the first frame unprimed (frame-top gap; self-heals after one frame), so sampling line
   0 would read the cold buffer. *)
let sample_word sim ~pattern ~inv =
  let inp : _ I.t = Cyclesim.inputs sim in
  let outp : _ O.t = Cyclesim.outputs sim in
  inp.inv := bits1 inv;
  inp.viddata := word pattern;
  let hcnt = node sim "hcnt" in
  let vcnt = node sim "vcnt" in
  let aligned () =
    let h = Cyclesim.Node.to_int hcnt in
    h >= 32 && h land 31 = 0 && h < 1024 && Cyclesim.Node.to_int vcnt >= 2
  in
  let guard = ref 0 in
  while (not (aligned ())) && !guard < 20000 do
    Cyclesim.cycle sim;
    Int.incr guard
  done;
  let bits = ref 0 in
  for i = 0 to 31 do
    let px = Bits.to_int_trunc !(outp.rgb) land 1 in
    bits := !bits lor (px lsl i);
    for _ = 1 to 5 do
      Cyclesim.cycle sim
    done
  done;
  !bits
;;

let%expect_test "vid — pixel shift-out: word streams LSB-first; inv inverts it" =
  let pattern = 0xC0000003 in
  let normal = sample_word (make ()) ~pattern ~inv:false in
  let inverted = sample_word (make ()) ~pattern ~inv:true in
  Stdlib.Printf.printf
    "pattern  = %08X\nnormal   = %08X\ninverted = %08X (~pattern = %08X)\n"
    pattern
    normal
    inverted
    (lnot pattern land 0xFFFFFFFF);
  [%expect
    {|
    pattern  = C0000003
    normal   = C0000003
    inverted = 3FFFFFFC (~pattern = 3FFFFFFC)
    |}]
;;

(* The constant-pattern shift-out above proves the buffer→pixbuf→rgb datapath, but its
   address-independent data can't see the prefetch's LOOK-AHEAD addressing. These two
   tests drive an address-keyed "memory" — echo the requested [vidadr] back as the data —
   so each displayed 32-px group reconstructs to the framebuffer word address it was
   fetched from, and assert each column still shows its OWN word ([Org + {~vcnt, col}],
   the original VID60.v mapping) despite being fetched a group early into a ping-pong
   buffer.

   This is the sim half of the prefetch-DELIVERY check (test/formal/README "VID
   prefetch"): the [vid] equiv proof cuts [vidbuf] + excludes [vidadr], so it proves the
   display is right GIVEN the right word; these tests show the look-ahead actually
   DELIVERS that word. They sweep all 32 columns over consecutive rows — covering the
   within-line look-ahead (cols 1..31) AND the cross-line wrap (each row's col 0 is
   fetched from the PREVIOUS row's col 31) — at a single clk/pclk phase (phase is
   irrelevant to the pclk-domain addressing; the all-phase robustness of the fetch
   HANDSHAKE is the separate [vid_invariant] proof).

   Shared rig: echo memory + a steady-line aligner + an LSB-first group reader. *)
let make_echo_rig () =
  let sim = make () in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.inv := bits1 false;
  let hcnt = node sim "hcnt"
  and vcnt = node sim "vcnt" in
  (* address-echoing memory: [viddata] follows [vidadr], so each fetched word equals the
     address it came from and a displayed group reconstructs to its framebuffer address *)
  let step () =
    inp.viddata := word (Bits.to_unsigned_int !(outp.vidadr));
    Cyclesim.cycle sim
  in
  (* reconstruct one displayed 32-px group LSB-first, one pixel per pclk (5 base ticks).
     [hcnt = 32] displays column 0 (pixbuf is loaded at the col-0 xfer, hcnt = 31), so the
     32 visible columns stream out contiguously over hcnt 32..1055. *)
  let read_group () =
    let bits = ref 0 in
    for i = 0 to 31 do
      bits := !bits lor ((Bits.to_int_trunc !(outp.rgb) land 1) lsl i);
      for _ = 1 to 5 do
        step ()
      done
    done;
    !bits
  in
  (* step to column 0 of the next line at or past [min_row]; return that row *)
  let align_to_col0 ~min_row =
    let guard = ref 0 in
    while
      (not (Cyclesim.Node.to_int hcnt = 32 && Cyclesim.Node.to_int vcnt >= min_row))
      && !guard < 40000
    do
      step ();
      Int.incr guard
    done;
    Cyclesim.Node.to_int vcnt
  in
  (* read all 32 columns of one freshly-aligned line (vcnt is constant across hcnt
     32..1055) *)
  let read_line ~min_row =
    let r = align_to_col0 ~min_row in
    let acc = ref [] in
    for _ = 1 to 32 do
      acc := read_group () :: !acc
    done;
    r, List.rev !acc
  in
  read_line
;;

(* the framebuffer word VID60.v fetches for screen position (row, col): Org + {~row, col} *)
let vid60_word ~row ~col = org + ((lnot row land 0x3FF) lsl 5) + col

let%expect_test "vid — prefetch look-ahead: every column delivers its own word, across \
                 rows"
  =
  let read_line = make_echo_rig () in
  (* two CONSECUTIVE steady lines (past the frame-top gap); [read_line]'s aligner lands on
     the immediately following col 0, so r1 = r0 + 1 — the read itself crosses a row. *)
  let r0, w0 = read_line ~min_row:2 in
  let r1, w1 = read_line ~min_row:2 in
  let matches (r, ws) =
    List.equal Int.equal ws (List.init 32 ~f:(fun col -> vid60_word ~row:r ~col))
  in
  Stdlib.Printf.printf
    "line %d cols 0..31 deliver Org+{~vcnt,col}: %b  (col0=0x%05X col31=0x%05X)\n\
     line %d cols 0..31 deliver Org+{~vcnt,col}: %b  (col0=0x%05X col31=0x%05X)\n\
     rows consecutive (read crossed a row boundary): %b\n"
    r0
    (matches (r0, w0))
    (List.hd_exn w0)
    (List.last_exn w0)
    r1
    (matches (r1, w1))
    (List.hd_exn w1)
    (List.last_exn w1)
    (r1 = r0 + 1);
  [%expect
    {|
    line 2 cols 0..31 deliver Org+{~vcnt,col}: true  (col0=0x3FF60 col31=0x3FF7F)
    line 3 cols 0..31 deliver Org+{~vcnt,col}: true  (col0=0x3FF40 col31=0x3FF5F)
    rows consecutive (read crossed a row boundary): true
    |}]
;;

(* The two-group prefetch leaves the FIRST frame's first group unprimed: line 0 col 0 is
   fetched at the look-ahead wrap of the PREVIOUS frame's last line (req0 at line 767, col

   31) — which never ran at power-on, so it reads the cold (zero) buffer. This is the
   frame-top gap [sample_word]/the test above skip with [min_row >= 2]. It is exactly ONE
   group: line 0 cols 1..31 are fetched within line 0, and from line 1 on every col 0 is
   filled by the previous line's wrap (the steady-line test above). So it self-heals after
   the first group and is invisible (Oberon clears the screen long before it matters). *)
let%expect_test "vid — prefetch: frame-top gap is exactly one group (line 0 col 0), then \
                 heals"
  =
  let sim = make () in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.inv := bits1 false;
  let hcnt = node sim "hcnt" in
  let step () =
    inp.viddata := word (Bits.to_unsigned_int !(outp.vidadr));
    Cyclesim.cycle sim
  in
  (* from power-on (vcnt = 0), the very first displayed group is line 0 col 0 at hcnt = 32 *)
  let guard = ref 0 in
  while Cyclesim.Node.to_int hcnt <> 32 && !guard < 4000 do
    step ();
    Int.incr guard
  done;
  let read_group () =
    let bits = ref 0 in
    for i = 0 to 31 do
      bits := !bits lor ((Bits.to_int_trunc !(outp.rgb) land 1) lsl i);
      for _ = 1 to 5 do
        step ()
      done
    done;
    !bits
  in
  let words =
    let acc = ref [] in
    for _ = 1 to 32 do
      acc := read_group () :: !acc
    done;
    List.rev !acc
  in
  let col0 = List.hd_exn words in
  let cols_1_31_ok =
    List.for_alli words ~f:(fun col w -> col = 0 || w = vid60_word ~row:0 ~col)
  in
  Stdlib.Printf.printf
    "line 0 col 0: read 0x%05X, would be 0x%05X — cold (unprimed buffer): %b\n\
     line 0 cols 1..31 all delivered correctly: %b\n\
     ⇒ gap is exactly one group; heals from line 1 (steady-line test above)\n"
    col0
    (vid60_word ~row:0 ~col:0)
    (col0 <> vid60_word ~row:0 ~col:0)
    cols_1_31_ok;
  [%expect
    {|
    line 0 col 0: read 0x00000, would be 0x3FFA0 — cold (unprimed buffer): true
    line 0 cols 1..31 all delivered correctly: true
    ⇒ gap is exactly one group; heals from line 1 (steady-line test above)
    |}]
;;
