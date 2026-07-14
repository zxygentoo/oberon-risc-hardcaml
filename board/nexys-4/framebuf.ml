(* Public API and behaviour spec live in [framebuf.mli].

   Implementation note. The window compare and index subtract run combinationally off the
   core's store signals into the BRAM write port (registered inside the RAM primitive) —
   the same shape as {!Cache}'s snoop path. [Video.org] is not span-aligned (0x37FC0 mod
   0x8000 <> 0), so the index is a genuine 15-bit subtract, not a bit-slice. The read side
   registers [vid_ack]/[vidpar] alongside the RAM's own address register, so the three
   outputs change together on the cycle after [vidreq]. *)

open! Base
open Hardcaml
open Signal

let base = Risc5.Video.org
let span_log2 = 15
let size = 1 lsl span_log2

module I = struct
  type 'a t =
    { clock : 'a
    ; adr : 'a [@bits 24]
    ; write : 'a [@bits 1]
    ; ben : 'a [@bits 1]
    ; wdata : 'a [@bits 32]
    ; vidreq : 'a [@bits 1]
    ; vidadr : 'a [@bits 18]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { viddata : 'a [@bits 32]
    ; vid_ack : 'a [@bits 1]
    ; vidpar : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* the store's 22-bit word address (full 16 MiB — exactly {!Cache}'s cached address, and
     {!Cellram}'s since 2a). This MUST match Cellram's width: with a narrow 18-bit compare a
     himem store whose low 18 word-bits fall in [base, base+size) would false-match the
     window and corrupt the shadow (and break shadow ≡ PSRAM, since Cellram no longer
     aliases). The wide compare places all of himem outside the window. *)
  let wa = select i.adr ~high:23 ~low:2 in
  let in_window = wa >=:. base &: (wa <:. base + size) in
  let widx = select (wa -:. base) ~high:(span_log2 - 1) ~low:0 in
  let ridx = select (i.vidadr -:. base) ~high:(span_log2 - 1) ~low:0 in
  let lane = select i.adr ~high:1 ~low:0 in
  (* one 32768 x 8 BRAM per byte lane (the lib/ram.ml [SRbe] semantics): lane k written on
     a word store, or a byte store whose adr[1:0] = k *)
  let byte_lane k =
    let write_enable = i.write &: in_window &: (~:(i.ben) |: (lane ==:. k)) in
    (Ram.create
       ~name:(Printf.sprintf "fb%d" k)
       ~collision_mode:Read_before_write
       ~size
       ~write_ports:
         [| { Write_port.write_clock = i.clock
            ; write_address = widx
            ; write_enable
            ; write_data = select i.wdata ~high:((8 * k) + 7) ~low:(8 * k)
            }
         |]
       ~read_ports:
         [| { Read_port.read_clock = i.clock
            ; read_address = ridx
            ; read_enable = i.vidreq
            }
         |]
       ()).(0)
  in
  let viddata = concat_msb [ byte_lane 3; byte_lane 2; byte_lane 1; byte_lane 0 ] in
  { O.viddata
  ; vid_ack = reg spec i.vidreq
  ; vidpar = reg spec ~enable:i.vidreq (lsb i.vidadr)
  }
;;

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────── No oracle
   needed: the contract is a shadow RAM — stores in the window land (word and byte-lane),
   stores outside it don't (checked at the index they would alias to), and a [vidreq]
   returns the word one cycle later with [vid_ack]/[vidpar]. A waveform pins the read
   timing (ack/par/data move together, one cycle after req); a printf test covers the
   write-path cases. *)

let%expect_test "framebuf — vidreq timing: ack/par/viddata one cycle after req [waveform]"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  inp.write := b1 0;
  inp.ben := b1 0;
  (* store AABBCCDD at Org (byte 0xDFF00), then fetch it: Org has even parity, Org+1 odd *)
  inp.adr := Bits.of_unsigned_int ~width:24 (base * 4);
  inp.wdata := Bits.of_unsigned_int ~width:32 0xAABBCCDD;
  inp.write := b1 1;
  inp.vidadr := Bits.of_unsigned_int ~width:18 base;
  inp.vidreq := b1 0;
  Cyclesim.cycle sim;
  inp.write := b1 0;
  inp.vidreq := b1 1;
  Cyclesim.cycle sim;
  inp.vidreq := b1 0;
  Cyclesim.cycle sim;
  inp.vidadr := Bits.of_unsigned_int ~width:18 (base + 1);
  inp.vidreq := b1 1;
  Cyclesim.cycle sim;
  inp.vidreq := b1 0;
  Cyclesim.cycle sim;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "vidreq"
        ; port_name_is ~wave_format:Wave_format.Bit "vid_ack"
        ; port_name_is ~wave_format:Wave_format.Bit "vidpar"
        ; port_name_is ~wave_format:Wave_format.Hex "viddata"
        ]
    ~wave_width:4
    ~display_width:70
    waves;
  [%expect
    {|
    ┌Signals────────┐┌Waves──────────────────────────────────────────────┐
    │vidreq         ││          ┌─────────┐         ┌─────────┐          │
    │               ││──────────┘         └─────────┘         └───────── │
    │vid_ack        ││                    ┌─────────┐         ┌───────── │
    │               ││────────────────────┘         └─────────┘          │
    │vidpar         ││                                        ┌───────── │
    │               ││────────────────────────────────────────┘          │
    │               ││────────────────────┬───────────────────┬───────── │
    │viddata        ││ 00000000           │AABBCCDD           │00000000  │
    │               ││────────────────────┴───────────────────┴───────── │
    └───────────────┘└───────────────────────────────────────────────────┘
    |}]
;;

let%expect_test "framebuf — word store, byte-lane store, out-of-window store ignored" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  let outp = Cyclesim.outputs sim in
  let store ~adr ~ben ~wdata =
    inp.adr := Bits.of_unsigned_int ~width:24 adr;
    inp.ben := b1 ben;
    inp.wdata := Bits.of_unsigned_int ~width:32 wdata;
    inp.write := b1 1;
    inp.vidreq := b1 0;
    Cyclesim.cycle sim;
    inp.write := b1 0
  in
  let fetch wa =
    inp.vidadr := Bits.of_unsigned_int ~width:18 wa;
    inp.vidreq := b1 1;
    Cyclesim.cycle sim;
    inp.vidreq := b1 0;
    Cyclesim.cycle sim;
    Bits.to_unsigned_int !(outp.viddata)
  in
  (* word store at Org *)
  store ~adr:(base * 4) ~ben:0 ~wdata:0xAABBCCDD;
  Stdlib.Printf.printf "word store      : %08X\n" (fetch base);
  (* byte store to lane 1 of the same word (outbus byte-replicated, as the core drives) *)
  store ~adr:((base * 4) + 1) ~ben:1 ~wdata:0x11111111;
  Stdlib.Printf.printf "byte store lane1: %08X\n" (fetch base);
  (* a store one full span below Org aliases to shadow index 0 if the window compare is
     wrong — the word at Org must be untouched *)
  store ~adr:((base - (1 lsl span_log2)) * 4) ~ben:0 ~wdata:0xFFFFFFFF;
  Stdlib.Printf.printf "below window    : %08X\n" (fetch base);
  (* likewise one word past the span's end (word Org + 0x8000, aliasing to index 0) *)
  store ~adr:((base + (1 lsl span_log2)) * 4) ~ben:0 ~wdata:0xFFFFFFFF;
  Stdlib.Printf.printf "above window    : %08X\n" (fetch base);
  (* 2a himem-alias guard: word (Org + 2^18) is byte 0x1DFF00 in himem, but its low 18
     word-bits equal Org — an 18-bit window compare would corrupt shadow index 0. The
     22-bit compare (matching {!Cellram}) places it outside the window, so Org is
     untouched. *)
  store ~adr:((base + (1 lsl 18)) * 4) ~ben:0 ~wdata:0xFFFFFFFF;
  Stdlib.Printf.printf "himem alias Org : %08X\n" (fetch base);
  (* the span's last word is writable *)
  store ~adr:((base + (1 lsl span_log2) - 1) * 4) ~ben:0 ~wdata:0x12345678;
  Stdlib.Printf.printf "last word       : %08X\n" (fetch (base + (1 lsl span_log2) - 1));
  [%expect
    {|
    word store      : AABBCCDD
    byte store lane1: AABB11DD
    below window    : AABB11DD
    above window    : AABB11DD
    himem alias Org : AABB11DD
    last word       : 12345678
    |}]
;;
