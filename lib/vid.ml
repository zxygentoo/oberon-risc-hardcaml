(* Public API and behaviour spec live in [vid.mli].

   Port of [VID60.v]. Two clock domains — and per AGENT.md §3 the clock *generation* (the
   Xilinx [DCM]/[BUFG]) is the Phase-7 board shim, so they are dropped and [pclk] is an
   input here:

   - [pclk] (65 MHz) — the raster. Free-running counters [hcnt] (0..1343) and [vcnt]
     (0..805) walk the 1024x768 + blanking frame; [hsync]/[vsync] are pulse latches; the
     32-bit [pixbuf] shifts out one pixel per tick and reloads a fresh word every 32 px.
   - [clk] (25 MHz) — the framebuffer DMA. A one-cycle request [req] (= core [stallX])
     reads a word per 32 px into [vidbuf], which [pixbuf] loads at [xfer].

   Comparator-free range tests, straight from the RTL: [vcnt >= 768] is
   [vcnt[9] & vcnt[8]] ([vblank]) and [hcnt >= 1024] is [hcnt[10]] ([hblank]) — the
   constants are chosen so a magnitude compare collapses to a single bit.

   The pulse latch [x <= start | x & ~stop] is an SR latch folded into one flop: set at
   [start], hold, clear at [stop]. The sync offsets ([1032+31], [1176+31] etc.) delay the
   pulses to track the pixel-pipeline latency ([xfer] lands at [hcnt[4:0] = 31]).

   CDC — the one structural departure from the RTL (see [vid.mli]). [req0] is a 1-[pclk]
   pulse at the start of each 32-px group. The RTL captures it in a clk-domain async-set
   flop; Cyclesim samples async reset only at the clock edge, so we instead capture the
   pulse in the FASTER [pclk] domain ([caught]) and consume it with a clk one-shot
   [req = (caught | req0) & ~req]. The [| req0] term also covers a pulse still high at a
   clk edge. Output-equivalent to the async-set flop; the co-sim is the proof. *)

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

let create (i : _ I.t) : _ O.t =
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
  (* request the next word at the start of each visible 32-px group; transfer it 31 px on *)
  let req0 = (sel_bottom hcnt ~width:5 ==:. 0 &: ~:hblank &: ~:vblank) -- "req0" in
  let xfer = sel_bottom hcnt ~width:5 ==:. 31 in
  (* ── clk domain: framebuffer DMA handshake (see header) ────────────────────── *)
  let req_w = wire 1 in
  let caught =
    reg_fb pspec ~width:1 ~f:(fun s -> mux2 req0 vdd (mux2 req_w gnd s)) -- "caught"
  in
  let pending = caught |: req0 in
  (* one-shot: a single [clk] cycle when a request is [pending] and we are not already in
     it *)
  let req = reg_fb cspec ~width:1 ~f:(fun q -> pending &: ~:q) in
  assign req_w req;
  let vidbuf = reg ~enable:req cspec i.viddata -- "vidbuf" in
  (* ── pclk domain: pixel shift register + sync/blank latches ────────────────── *)
  let pixbuf =
    reg_fb pspec ~width:32 ~f:(fun p ->
      mux2 xfer vidbuf (concat_msb [ gnd; select p ~high:31 ~low:1 ]))
  in
  let hs =
    reg_fb pspec ~width:1 ~f:(fun hs -> hcnt ==:. 1063 |: (hs &: (hcnt <>:. 1207)))
  in
  let vs =
    reg_fb pspec ~width:1 ~f:(fun vs -> vcnt ==:. 771 |: (vs &: (vcnt <>:. 777)))
  in
  let blank = reg_fb pspec ~width:1 ~f:(fun b -> mux2 xfer (vblank |: hblank) b) in
  (* ── outputs ───────────────────────────────────────────────────────────────── *)
  let vidadr =
    of_unsigned_int ~width:18 org
    +: concat_msb [ zero 3; ~:vcnt; select hcnt ~high:9 ~low:5 ]
  in
  (* displayed pixel: framebuffer bit [pixbuf[0]] XOR [inv] ([^:] binds tighter than
     [&:]), forced dark outside the visible region *)
  let pixel = lsb pixbuf ^: i.inv &: ~:blank in
  { O.req; vidadr; hsync = ~:hs; vsync = ~:vs; rgb = repeat pixel ~count:rgbw }
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

let%expect_test "vid — CDC: req0 (pclk pulse) captured into a one-cycle clk req" =
  let sim = make () in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  inp.inv := bits1 false;
  inp.viddata := word 0xDEADBEEF;
  (* The startup request: [hcnt = 0] at power-on, so [req0] fires at once. Watch [caught]
     (pclk) latch the pulse and hold it, the clk one-shot [req] fire for one clk cycle,
     then [vidbuf] grab [viddata] at the following clk edge. NB [req0] is combinational
     ([hcnt[4:0] = 0]); the trace samples it one base-tick behind [hcnt]'s registered
     update (a Cyclesim trace-phase artifact, not hardware), so it reads high one tick
     past [hcnt] leaving 0. *)
  Stdlib.Printf.printf "tick | hcnt req0 caught req | vidbuf\n";
  for t = 0 to 28 do
    Cyclesim.cycle sim;
    Stdlib.Printf.printf
      "%4d |  %2d    %d     %d     %d | %08X\n"
      t
      (peek sim "hcnt")
      (peek sim "req0")
      (peek sim "caught")
      (Bits.to_int_trunc !(outp.req))
      (peek sim "vidbuf")
  done;
  [%expect
    {|
    tick | hcnt req0 caught req | vidbuf
       0 |   0    1     0     0 | 00000000
       1 |   0    1     0     0 | 00000000
       2 |   0    1     0     0 | 00000000
       3 |   0    1     0     0 | 00000000
       4 |   1    1     1     0 | 00000000
       5 |   1    0     1     0 | 00000000
       6 |   1    0     1     0 | 00000000
       7 |   1    0     1     0 | 00000000
       8 |   1    0     1     0 | 00000000
       9 |   2    0     1     0 | 00000000
      10 |   2    0     1     0 | 00000000
      11 |   2    0     1     0 | 00000000
      12 |   2    0     1     1 | 00000000
      13 |   2    0     1     1 | 00000000
      14 |   3    0     0     1 | 00000000
      15 |   3    0     0     1 | 00000000
      16 |   3    0     0     1 | 00000000
      17 |   3    0     0     1 | 00000000
      18 |   3    0     0     1 | 00000000
      19 |   4    0     0     1 | 00000000
      20 |   4    0     0     1 | 00000000
      21 |   4    0     0     1 | 00000000
      22 |   4    0     0     1 | 00000000
      23 |   4    0     0     1 | 00000000
      24 |   5    0     0     1 | 00000000
      25 |   5    0     0     0 | DEADBEEF
      26 |   5    0     0     0 | DEADBEEF
      27 |   5    0     0     0 | DEADBEEF
      28 |   5    0     0     0 | DEADBEEF
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
   32 pixels one [pclk] apart — reconstructing the displayed word LSB-first *)
let sample_word sim ~pattern ~inv =
  let inp : _ I.t = Cyclesim.inputs sim in
  let outp : _ O.t = Cyclesim.outputs sim in
  inp.inv := bits1 inv;
  inp.viddata := word pattern;
  let hcnt = node sim "hcnt" in
  let aligned () =
    let h = Cyclesim.Node.to_int hcnt in
    h >= 32 && h land 31 = 0
  in
  let guard = ref 0 in
  while (not (aligned ())) && !guard < 4000 do
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
