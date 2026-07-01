(* Public API + the placement/coherence/geometry rationale live in [icache.mli].

   Implementation note. The line is packed into one [multiport_memory] word:
   {valid[1]; tag[tag_w]; data[32]}, read asynchronously (combinational hit). One synchronous
   write port serves both fill (read-miss retire) and invalidate (snooped store) — they never
   coincide (the core is single-issue: a cycle is a fetch, a load, or a store), so [we]/[wd]
   just mux between them. The write port is feedback-driven ([fill]/[invalidate] depend on the
   read of the same line), so [we]/[wd] are wires assigned after the memory. *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; adr : 'a [@bits 24] (* core byte address (fetch or load/store) *)
    ; cacheable_read : 'a
         [@bits 1] (* mem_pend & ~wr & ~cpu_internal — a PSRAM fetch/load *)
    ; write : 'a [@bits 1] (* wr & ~cpu_internal — a PSRAM store, to snoop *)
    ; ce : 'a [@bits 1] (* Cellram.ce — the access-retire pulse *)
    ; fill_data : 'a [@bits 32]
    (* Cellram.rdata — the fetched word, valid at [ce] on a miss *)
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { hit : 'a [@bits 1] (* combinational: cacheable_read & valid & tag-match *)
    ; rdata : 'a [@bits 32] (* the cached word (meaningful when [hit]) *)
    }
  [@@deriving hardcaml]
end

(* [lines_log2] = log2 of the number of lines (default 1024 lines = 4 KiB of data). The
   cached address is the 18-bit word address of the 1 MB window ([adr[19:2]]); index = its
   low [lines_log2] bits, tag = the rest. *)
let create ?(lines_log2 = 10) (i : _ I.t) : _ O.t =
  let lines = 1 lsl lines_log2 in
  let tag_w = 18 - lines_log2 in
  let line_w = 1 + tag_w + 32 in
  let wa = select i.adr ~high:19 ~low:2 in
  let index = select wa ~high:(lines_log2 - 1) ~low:0 in
  let tag = select wa ~high:17 ~low:lines_log2 in
  (* one synchronous write port, feedback-driven (fill/invalidate depend on the read) *)
  let we = wire 1 in
  let wd = wire line_w in
  let write_port =
    { Write_port.write_clock = i.clock
    ; write_address = index
    ; write_enable = we
    ; write_data = wd
    }
  in
  let reads =
    multiport_memory
      lines
      ~name:"icache_mem"
      ~initialize_to:(Array.init lines ~f:(fun _ -> Bits.of_unsigned_int ~width:line_w 0))
      ~write_ports:[| write_port |]
      ~read_addresses:[| index |]
  in
  let stored = reads.(0) in
  let stored_valid = bit stored ~pos:(line_w - 1) in
  let stored_tag = select stored ~high:(line_w - 2) ~low:32 in
  let stored_data = select stored ~high:31 ~low:0 in
  let tag_match = stored_valid &: (stored_tag ==: tag) in
  let hit = i.cacheable_read &: tag_match in
  (* fill a read miss when it retires; drop a line a store overwrites. Mutually exclusive
     (read cycle vs store cycle), so one write port serves both. *)
  let fill = i.cacheable_read &: i.ce &: ~:hit in
  let invalidate = i.write &: tag_match in
  assign we (fill |: invalidate);
  assign wd (mux2 fill (vdd @: tag @: i.fill_data) (zero line_w));
  { O.hit; rdata = stored_data }
;;

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── Coherence
   is the property that matters (§5): a fill makes a line hit, a tag-mismatch at the same
   index does *not* (no false hit), and a snooped store drops the line. Drive the raw [I]
   ports — the cache is its own spec, no oracle — and check hit/rdata; then freeze a
   waveform of the same sequence. Note [multiport_memory]'s async read is post-write in
   Cyclesim (like the register file, §6), so a line filled this cycle reads back next
   cycle; the [fill] write enable is latched from the *pre*-edge [hit] (= 0 on the miss),
   so a read miss fills exactly once. *)

let%expect_test "icache — fill hits, tag-mismatch misses, store snoop-invalidates \
                 [coherence]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  let step ~read ~write ~adr ~ce ~fill =
    set inp.adr adr 24;
    set inp.cacheable_read read 1;
    set inp.write write 1;
    set inp.ce ce 1;
    set inp.fill_data fill 32;
    Cyclesim.cycle sim
  in
  let hit () = Bits.to_int_trunc !(outp.hit) in
  let rdata () = Bits.to_unsigned_int !(outp.rdata) in
  (* A and C share index 0x10 but differ in tag (0 vs 1), so C must not false-hit on A. *)
  let a = 0x40 (* word 0x10: index 0x10, tag 0 *)
  and c = 0x1040 (* word 0x410: index 0x10, tag 1 *) in
  step ~read:1 ~write:0 ~adr:a ~ce:1 ~fill:0xDEADBEEF;
  (* miss on A → fill *)
  step ~read:1 ~write:0 ~adr:a ~ce:0 ~fill:0;
  (* A → hit, serves the filled word *)
  Stdlib.Printf.printf "A after fill        : hit=%d rdata=0x%X\n" (hit ()) (rdata ());
  step ~read:1 ~write:0 ~adr:c ~ce:0 ~fill:0;
  (* C: same index, other tag → miss *)
  Stdlib.Printf.printf "C (same idx, tag+1) : hit=%d\n" (hit ());
  step ~read:0 ~write:1 ~adr:a ~ce:0 ~fill:0;
  (* store to A → snoop-invalidate *)
  step ~read:1 ~write:0 ~adr:a ~ce:0 ~fill:0;
  (* A → miss (line dropped) *)
  Stdlib.Printf.printf "A after store to A  : hit=%d\n" (hit ());
  [%expect
    {|
    A after fill        : hit=1 rdata=0xDEADBEEF
    C (same idx, tag+1) : hit=0
    A after store to A  : hit=0
    |}]
;;

let%expect_test "icache — fill/hit/invalidate timing [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  let step ~read ~write ~adr ~ce ~fill =
    set inp.adr adr 24;
    set inp.cacheable_read read 1;
    set inp.write write 1;
    set inp.ce ce 1;
    set inp.fill_data fill 32;
    Cyclesim.cycle sim
  in
  (* c0 miss+fill A, c1 hit A, c2 miss C (same index other tag), c3 store A (snoop), c4
     miss A *)
  step ~read:1 ~write:0 ~adr:0x40 ~ce:1 ~fill:0xDEADBEEF;
  step ~read:1 ~write:0 ~adr:0x40 ~ce:0 ~fill:0;
  step ~read:1 ~write:0 ~adr:0x1040 ~ce:0 ~fill:0;
  step ~read:0 ~write:1 ~adr:0x40 ~ce:0 ~fill:0;
  step ~read:1 ~write:0 ~adr:0x40 ~ce:0 ~fill:0;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "cacheable_read"
        ; port_name_is ~wave_format:Wave_format.Bit "write"
        ; port_name_is ~wave_format:Wave_format.Bit "ce"
        ; port_name_is ~wave_format:Wave_format.Hex "adr"
        ; port_name_is ~wave_format:Wave_format.Bit "hit"
        ; port_name_is ~wave_format:Wave_format.Hex "rdata"
        ]
    ~wave_width:4
    ~display_width:74
    waves;
  [%expect
    {|
    ┌Signals─────────┐┌Waves─────────────────────────────────────────────────┐
    │cacheable_read  ││──────────────────────────────┐         ┌─────────    │
    │                ││                              └─────────┘             │
    │write           ││                              ┌─────────┐             │
    │                ││──────────────────────────────┘         └─────────    │
    │ce              ││──────────┐                                           │
    │                ││          └───────────────────────────────────────    │
    │                ││────────────────────┬─────────┬───────────────────    │
    │adr             ││ 000040             │001040   │000040                 │
    │                ││────────────────────┴─────────┴───────────────────    │
    │hit             ││          ┌─────────┐                                 │
    │                ││──────────┘         └─────────────────────────────    │
    │                ││──────────┬─────────────────────────────┬─────────    │
    │rdata           ││ 00000000 │DEADBEEF                     │00000000     │
    │                ││──────────┴─────────────────────────────┴─────────    │
    └────────────────┘└──────────────────────────────────────────────────────┘
    |}]
;;
