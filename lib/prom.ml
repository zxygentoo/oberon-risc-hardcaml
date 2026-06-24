(* Public API and behaviour spec live in [prom.mli].

   Implementation note. [PROM.v] is a [reg [31:0] mem[511:0]] read with [data <= mem[adr]]
   on the inverted clock — synchronous, but the negedge phase exists only to give on-chip
   block RAM half a cycle so [codebus] is ready before the CPU's posedge samples it into
   [ir]. Since [ir] is the sole consumer and samples on the posedge, a combinational read
   is edge-equivalent (AGENT.md §2): we build the async ROM now and defer the
   registered/BRAM form to the Phase-8 cycle co-sim. Built from the [rom] primitive
   (asynchronous, multi-read). *)

open! Base
open Hardcaml
open Signal

let depth = 512 (* 2^9 words; adr is [@bits 9] below *)
let data_width = 32

module I = struct
  type 'a t = { adr : 'a [@bits 9] } [@@deriving hardcaml]
end

module O = struct
  type 'a t = { data : 'a [@bits 32] } [@@deriving hardcaml]
end

let create ~contents (i : _ I.t) : _ O.t =
  if Array.length contents > depth
  then failwith "Prom: contents exceed the 512-word ROM depth";
  let image =
    Array.init depth ~f:(fun k ->
      let w = if k < Array.length contents then contents.(k) else 0 in
      Bits.of_unsigned_int ~width:data_width w)
  in
  let reads = rom ~read_addresses:[| i.adr |] image in
  { O.data = reads.(0) }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness: load a recognisable image and read back all 512 words — deterministic, so
   a plain loop, not qcheck; the image array is its own spec, no oracle. Behaviour: a
   frozen waveform of a few reads showing the asynchronous read (data tracks adr within
   the cycle). *)

let test_image = Array.init depth ~f:(fun k -> 0xC0DE0000 lor k)

let%expect_test "rom reads back its image [exhaustive, 512 words]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create (create ~contents:test_image) in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let ok = ref true in
  for a = 0 to depth - 1 do
    inp.adr := Bits.of_unsigned_int ~width:9 a;
    Cyclesim.cycle sim;
    if not (Bits.equal !(outp.data) (Bits.of_unsigned_int ~width:32 test_image.(a)))
    then ok := false
  done;
  Stdlib.Printf.printf "all %d words read back correctly: %b\n" depth !ok;
  [%expect {| all 512 words read back correctly: true |}]
;;

let%expect_test "rom — asynchronous read, data tracks adr [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create (create ~contents:test_image) in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let read a =
    inp.adr := Bits.of_unsigned_int ~width:9 a;
    Cyclesim.cycle sim
  in
  read 0;
  read 1;
  read 5;
  read 0x1FF;
  read 0x100;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Unsigned_int "adr"
        ; port_name_is ~wave_format:Wave_format.Hex "data"
        ]
    ~wave_width:4
    ~display_width:70
    waves;
  [%expect
    {|
    ┌Signals────────┐┌Waves──────────────────────────────────────────────┐
    │               ││──────────┬─────────┬─────────┬─────────┬───────── │
    │adr            ││ 0        │1        │5        │511      │256       │
    │               ││──────────┴─────────┴─────────┴─────────┴───────── │
    │               ││──────────┬─────────┬─────────┬─────────┬───────── │
    │data           ││ C0DE0000 │C0DE0001 │C0DE0005 │C0DE01FF │C0DE0100  │
    │               ││──────────┴─────────┴─────────┴─────────┴───────── │
    └───────────────┘└───────────────────────────────────────────────────┘
    |}]
;;
