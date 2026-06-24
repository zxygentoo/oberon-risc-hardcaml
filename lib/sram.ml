(* Public API and behaviour spec live in [ram.mli].

   Implementation note. The OberonStation main memory is external asynchronous SRAM, wired
   in RISC5Top through tri-state IOBUFs with per-byte write-enables ([SRbe0]/[SRbe1],
   derived from [ben] and [adr[1:0]]). We model it as four byte-lane memories (256 Ki x 8
   each) sharing the word address [adr[19:2]]: lane k is written when [wr] and the lane is
   enabled — a word store ([~ben]) enables all four, a byte store only lane [adr[1:0]].
   This is the [SRbe] semantics directly, and avoids the read-modify-write a single 32-bit
   array would need for sub-word writes. Reads are asynchronous (combinational); memory
   starts zeroed. *)

open! Base
open Hardcaml
open Signal

let depth = 1 lsl 18 (* 256 Ki words = 1 MiB *)

(* one shared zero image for the four byte lanes — read-only, built once *)
let zero_init = Array.create ~len:depth (Bits.of_unsigned_int ~width:8 0)

module I = struct
  type 'a t =
    { clock : 'a
    ; adr : 'a [@bits 20]
    ; wr : 'a [@bits 1]
    ; ben : 'a [@bits 1]
    ; wdata : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t = { rdata : 'a [@bits 32] } [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let word_adr = select i.adr ~high:19 ~low:2 in
  let lane = select i.adr ~high:1 ~low:0 in
  (* one 256 Ki x 8 memory per byte lane; lane k writes on a word store or a byte store to
     k *)
  let byte_lane k =
    let write_enable = i.wr &: (~:(i.ben) |: (lane ==:. k)) in
    let write_port =
      { Write_port.write_clock = i.clock
      ; write_address = word_adr
      ; write_enable
      ; write_data = select i.wdata ~high:((8 * k) + 7) ~low:(8 * k)
      }
    in
    (multiport_memory
       depth
       ~name:(Printf.sprintf "ram%d" k)
       ~initialize_to:zero_init
       ~write_ports:[| write_port |]
       ~read_addresses:[| word_adr |]).(0)
  in
  let rdata = concat_msb [ byte_lane 3; byte_lane 2; byte_lane 1; byte_lane 0 ] in
  { O.rdata }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness: random (wr, ben, adr, wdata) sequences against a plain-OCaml word-array
   model — the array is its own spec, no oracle. Addresses are confined to a small window
   so reads land on written cells (read-after-write coverage). Post-edge the read reflects
   this cycle's write applied (async memory settles after the edge), so the model commits
   the write, then compares. Behaviour: a frozen waveform of a word store, a byte store,
   and the reads between them (data tracks adr, a write in cycle N reads back in N+1). *)

let%expect_test "ram = word-array model, word + byte writes [qcheck, 500 sequences]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let win = 16 in
  (* words; addresses span 0..win*4-1 bytes *)
  (* One sim, reused across all sequences. [Sim.create] of the 1 MiB memory (4 × 256 Ki
     byte lanes) is the expensive part, so build it once and zero the small test window at
     the start of each sequence rather than rebuilding it 500× (which made this qcheck ~50
     s). *)
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let check_seq ops =
    for w = 0 to win - 1 do
      inp.adr := Bits.of_unsigned_int ~width:20 (w * 4);
      inp.wr := Bits.of_unsigned_int ~width:1 1;
      inp.ben := Bits.of_unsigned_int ~width:1 0;
      inp.wdata := Bits.of_unsigned_int ~width:32 0;
      Cyclesim.cycle sim
    done;
    let model = Array.create ~len:win 0 in
    List.for_all ops ~f:(fun (wr, ben, adr, wdata) ->
      inp.adr := Bits.of_unsigned_int ~width:20 adr;
      inp.wr := Bits.of_unsigned_int ~width:1 wr;
      inp.ben := Bits.of_unsigned_int ~width:1 ben;
      inp.wdata := Bits.of_unsigned_int ~width:32 wdata;
      Cyclesim.cycle sim;
      let w = adr lsr 2 in
      let l = adr land 3 in
      if wr = 1
      then
        if ben = 1
        then (
          let byte = (wdata lsr (8 * l)) land 0xFF in
          model.(w) <- model.(w) land lnot (0xFF lsl (8 * l)) lor (byte lsl (8 * l)))
        else model.(w) <- wdata;
      Bits.equal !(outp.rdata) (Bits.of_unsigned_int ~width:32 model.(w)))
  in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:500
       ~name:"ram"
       QCheck.(
         list_size
           (Gen.int_range 1 30)
           (quad
              (int_bound 1)
              (int_bound 1)
              (int_range 0 ((win * 4) - 1))
              (int_bound 0xFFFF_FFFF)))
       check_seq);
  [%expect {| |}]
;;

let%expect_test "ram — word store, byte store, async read [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let drive ~wr ~ben ~adr ~wdata =
    inp.wr := Bits.of_unsigned_int ~width:1 wr;
    inp.ben := Bits.of_unsigned_int ~width:1 ben;
    inp.adr := Bits.of_unsigned_int ~width:20 adr;
    inp.wdata := Bits.of_unsigned_int ~width:32 wdata;
    Cyclesim.cycle sim
  in
  (* word-store AABBCCDD to word 0; read it back; byte-store 0x11 to byte 1; read word 0 *)
  drive ~wr:1 ~ben:0 ~adr:0 ~wdata:0xAABBCCDD;
  drive ~wr:0 ~ben:0 ~adr:0 ~wdata:0x0;
  drive ~wr:1 ~ben:1 ~adr:1 ~wdata:0x0000_1100;
  drive ~wr:0 ~ben:0 ~adr:0 ~wdata:0x0;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "wr"
        ; port_name_is ~wave_format:Wave_format.Bit "ben"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "adr"
        ; port_name_is ~wave_format:Wave_format.Hex "wdata"
        ; port_name_is ~wave_format:Wave_format.Hex "rdata"
        ]
    ~wave_width:4
    ~display_width:58
    waves;
  [%expect
    {|
    ┌Signals─────┐┌Waves─────────────────────────────────────┐
    │wr          ││──────────┐         ┌─────────┐           │
    │            ││          └─────────┘         └─────────  │
    │ben         ││                    ┌─────────┐           │
    │            ││────────────────────┘         └─────────  │
    │            ││────────────────────┬─────────┬─────────  │
    │adr         ││ 0                  │1        │0          │
    │            ││────────────────────┴─────────┴─────────  │
    │            ││──────────┬─────────┬─────────┬─────────  │
    │wdata       ││ AABBCCDD │00000000 │00001100 │00000000   │
    │            ││──────────┴─────────┴─────────┴─────────  │
    │            ││──────────┬───────────────────┬─────────  │
    │rdata       ││ 00000000 │AABBCCDD           │AABB11DD   │
    │            ││──────────┴───────────────────┴─────────  │
    └────────────┘└──────────────────────────────────────────┘
    |}]
;;
