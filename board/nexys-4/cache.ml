(* The contract, and the coherence argument, are in [cache.mli].

   A line is one [multiport_memory] word, {valid, tag, data}, read asynchronously. The
   single write port's enable and data depend on the read of the same line, so they are
   wires, assigned after the memory. *)

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
    ; ben : 'a [@bits 1] (* core byte-access flag: 1 = byte store (write-update can't) *)
    ; ce : 'a [@bits 1] (* Cellram.ce — the access-retire pulse *)
    ; fill_data : 'a
         [@bits 32] (* Cellram.rdata — the fetched word, valid at [ce] on a miss *)
    ; wdata : 'a [@bits 32]
    (* core store data ([outbus]) — the word a write-update writes into a hit line *)
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

(* The cached address is the 22-bit word address [adr[23:2]]: its low [lines_log2] bits
   index, the rest is the tag. The tag covers the whole 16 MiB, so a word above 1 MiB
   cannot hit the line of its low alias. *)
let create ?(lines_log2 = 10) ?(write_update = false) (i : _ I.t) : _ O.t =
  (* outside 1..21 the index and tag selections would fail inside Hardcaml, with a width
     error far from the cause *)
  if lines_log2 < 1 || lines_log2 > 21
  then
    failwith
      (Stdlib.Printf.sprintf
         "Cache.create: lines_log2 = %d out of range (valid 1..21)"
         lines_log2);
  let lines = 1 lsl lines_log2 in
  let tag_w = 22 - lines_log2 in
  let line_w = 1 + tag_w + 32 in
  let wa = select i.adr ~high:23 ~low:2 in
  let index = select wa ~high:(lines_log2 - 1) ~low:0 in
  let tag = select wa ~high:21 ~low:lines_log2 in
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
      ~initialize_to:(Array.create ~len:lines (Bits.zero line_w))
      ~write_ports:[| write_port |]
      ~read_addresses:[| index |]
  in
  let stored = reads.(0) in
  let stored_valid = bit stored ~pos:(line_w - 1) in
  let stored_tag = select stored ~high:(line_w - 2) ~low:32 in
  let stored_data = select stored ~high:31 ~low:0 in
  let tag_match = stored_valid &: (stored_tag ==: tag) in
  let hit = i.cacheable_read &: tag_match in
  (* A read miss fills its line when it retires. A store that hits either rewrites the
     line (a word store under [write_update]; harmless to repeat over the cycles a frozen
     core holds the store) or drops it. The three never coincide, so one write port serves
     them. *)
  let fill = i.cacheable_read &: i.ce &: ~:hit in
  let store_hit = i.write &: tag_match in
  let update = if write_update then store_hit &: ~:(i.ben) else gnd in
  let invalidate = if write_update then store_hit &: i.ben else store_hit in
  assign we (fill |: update |: invalidate);
  assign
    wd
    (mux2 (fill |: update) (vdd @: tag @: mux2 fill i.fill_data i.wdata) (zero line_w));
  { O.hit; rdata = stored_data }
;;

(* ── Tests ── A fill makes a line hit; another address with the same index does not; a
   store drops the line. [multiport_memory]'s asynchronous read shows a write on the cycle
   after it, so a line filled in one cycle reads back in the next. *)

(* [set] pokes an input; [step] presents one cycle's inputs and clocks. Optional inputs
   left out keep their level. *)
let set r v w = r := Bits.of_unsigned_int ~width:w v

let step sim (inp : _ I.t) ?(read = 1) ?(write = 0) ?ben ?fill ?wdata ~adr ~ce () =
  set inp.adr adr 24;
  set inp.cacheable_read read 1;
  set inp.write write 1;
  Option.iter ben ~f:(fun v -> set inp.ben v 1);
  set inp.ce ce 1;
  Option.iter fill ~f:(fun v -> set inp.fill_data v 32);
  Option.iter wdata ~f:(fun v -> set inp.wdata v 32);
  Cyclesim.cycle sim
;;

let%expect_test "icache — fill hits, tag-mismatch misses, store snoop-invalidates \
                 [coherence]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let step = step sim inp in
  let hit () = Bits.to_int_trunc !(outp.hit) in
  let rdata () = Bits.to_unsigned_int !(outp.rdata) in
  (* A and C share index 0x10 but differ in tag (0 vs 1), so C must not false-hit on A. *)
  let a = 0x40 (* word 0x10: index 0x10, tag 0 *)
  and c = 0x1040 (* word 0x410: index 0x10, tag 1 *) in
  step ~read:1 ~write:0 ~adr:a ~ce:1 ~fill:0xDEADBEEF ();
  (* miss on A → fill *)
  step ~read:1 ~write:0 ~adr:a ~ce:0 ~fill:0 ();
  (* A → hit, serves the filled word *)
  Stdlib.Printf.printf "A after fill        : hit=%d rdata=0x%X\n" (hit ()) (rdata ());
  step ~read:1 ~write:0 ~adr:c ~ce:0 ~fill:0 ();
  (* C: same index, other tag → miss *)
  Stdlib.Printf.printf "C (same idx, tag+1) : hit=%d\n" (hit ());
  step ~read:0 ~write:1 ~adr:a ~ce:0 ~fill:0 ();
  (* store to A → snoop-invalidate *)
  step ~read:1 ~write:0 ~adr:a ~ce:0 ~fill:0 ();
  (* A → miss (line dropped) *)
  Stdlib.Printf.printf "A after store to A  : hit=%d\n" (hit ());
  [%expect
    {|
    A after fill        : hit=1 rdata=0xDEADBEEF
    C (same idx, tag+1) : hit=0
    A after store to A  : hit=0
    |}]
;;

(* With [write_update] a word store that hits refreshes the line, so the next load returns
   the stored word; a byte store still drops it. *)
let%expect_test "icache — write-update: word store refreshes in place, byte store \
                 invalidates [coherence]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create (create ~write_update:true) in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let step = step sim inp in
  let hit () = Bits.to_int_trunc !(outp.hit) in
  let rdata () = Bits.to_unsigned_int !(outp.rdata) in
  let a = 0x40 in
  step ~read:1 ~write:0 ~ben:0 ~adr:a ~ce:1 ~fill:0xAAAA0001 ~wdata:0 ();
  (* miss on A -> fill *)
  step ~read:1 ~write:0 ~ben:0 ~adr:a ~ce:0 ~fill:0 ~wdata:0 ();
  Stdlib.Printf.printf "A after fill       : hit=%d rdata=0x%X\n" (hit ()) (rdata ());
  step ~read:0 ~write:1 ~ben:0 ~adr:a ~ce:0 ~fill:0 ~wdata:0xBBBB0002 ();
  (* WORD store to A -> update in place *)
  step ~read:1 ~write:0 ~ben:0 ~adr:a ~ce:0 ~fill:0 ~wdata:0 ();
  Stdlib.Printf.printf "A after word store : hit=%d rdata=0x%X\n" (hit ()) (rdata ());
  step ~read:0 ~write:1 ~ben:1 ~adr:a ~ce:0 ~fill:0 ~wdata:0xCC ();
  (* BYTE store to A -> invalidate *)
  step ~read:1 ~write:0 ~ben:0 ~adr:a ~ce:0 ~fill:0 ~wdata:0 ();
  Stdlib.Printf.printf "A after byte store : hit=%d\n" (hit ());
  [%expect
    {|
    A after fill       : hit=1 rdata=0xAAAA0001
    A after word store : hit=1 rdata=0xBBBB0002
    A after byte store : hit=0
    |}]
;;

(* Two words that share index 0x10, one in low memory (byte 0x40) and one above 1 MiB
   (byte 0x100040). Their 22-bit tags differ, so the second misses; with an 18-bit tag it
   would have hit the first one's line. *)
let%expect_test "icache — 2a: a himem [1 MB, 16 MB) line does not alias low memory" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim
  and outp = Cyclesim.outputs sim in
  let step = step sim inp in
  let hit () = Bits.to_int_trunc !(outp.hit) in
  set inp.fill_data 0xD00DF00D 32;
  step ~adr:0x40 ~ce:1 () (* miss on low word 0x10 → fill *);
  step ~adr:0x40 ~ce:0 ();
  Stdlib.Printf.printf "low line filled    : hit=%d\n" (hit ());
  step ~adr:0x100040 ~ce:0 () (* himem word 0x40010: same index, wider tag → miss *);
  Stdlib.Printf.printf
    "himem alias of low : hit=%d (0 = distinct tag, no false hit)\n"
    (hit ());
  [%expect
    {|
    low line filled    : hit=1
    himem alias of low : hit=0 (0 = distinct tag, no false hit)
    |}]
;;

let%expect_test "icache — fill/hit/invalidate timing [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Cyclesim.Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let step = step sim inp in
  (* c0 miss+fill A, c1 hit A, c2 miss C (same index other tag), c3 store A (snoop), c4
     miss A *)
  step ~read:1 ~write:0 ~adr:0x40 ~ce:1 ~fill:0xDEADBEEF ();
  step ~read:1 ~write:0 ~adr:0x40 ~ce:0 ~fill:0 ();
  step ~read:1 ~write:0 ~adr:0x1040 ~ce:0 ~fill:0 ();
  step ~read:0 ~write:1 ~adr:0x40 ~ce:0 ~fill:0 ();
  step ~read:1 ~write:0 ~adr:0x40 ~ce:0 ~fill:0 ();
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
