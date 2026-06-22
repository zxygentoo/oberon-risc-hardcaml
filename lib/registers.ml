(* Public API and behaviour spec live in [registers.mli].

   Implementation note. Wirth's [Registers.v] builds the triple-port file from Xilinx
   [RAM16X1D] dual-port distributed-RAM primitives: each gives one read at the write
   address (SPO) plus one read-only second port (DPO), so two blocks per data bit — kept
   identical, writes broadcast to both — yield the three read ports (dout0 = SPO[rfb]
   @rno0, dout1 = DPO[rfb] @rno1, dout2 = DPO[rfc] @rno2). That duplication
   is *structure*, not spec (AGENT.md §2/§3): we express the behaviour — three
   asynchronous reads, one synchronous write — with [multiport_memory] and let synthesis
   infer the distributed RAM (it may re-derive Wirth's very duplication). Async read /
   sync write is the timing the core and the oracle depend on (§8). *)

open! Base
open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; wr : 'a [@bits 1]
    ; rno0 : 'a [@bits 4]
    ; rno1 : 'a [@bits 4]
    ; rno2 : 'a [@bits 4]
    ; din : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { dout0 : 'a [@bits 32]
    ; dout1 : 'a [@bits 32]
    ; dout2 : 'a [@bits 32]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  (* one synchronous write port: din -> R[rno0] on the clock edge when wr *)
  let write_port =
    { Write_port.write_clock = i.clock
    ; write_address = i.rno0
    ; write_enable = i.wr
    ; write_data = i.din
    }
  in
  (* sixteen 32-bit words, init 0 (RAM16X1D's INIT); three asynchronous (combinational)
     reads at rno0/rno1/rno2 *)
  let reads =
    multiport_memory
      16
      (* named so a simulation can peek/poke the array by name
         (Cyclesim.lookup_mem_by_name "regfile") for differential testing; a name is
         metadata, not behaviour. *)
      ~name:"regfile"
      ~initialize_to:(Array.init 16 ~f:(fun _ -> Bits.of_unsigned_int ~width:32 0))
      ~write_ports:[| write_port |]
      ~read_addresses:[| i.rno0; i.rno1; i.rno2 |]
  in
  { O.dout0 = reads.(0); dout1 = reads.(1); dout2 = reads.(2) }
;;

(* ── Tests (co-located; AGENT.md §6) ──────────────────────────────────────────
   Correctness: qcheck random (wr, rno0/1/2, din) *sequences* against a plain-OCaml 16×32
   array model — no oracle needed (the array is its own spec). After each full cycle the
   post-edge read reflects the array with this cycle's write applied; the model commits
   the write, then compares. Behaviour: a frozen waveform — note hardcaml_waveterm
   samples *before* the clock edge, so its read ports show the pre-write (operand) value:
   a write in cycle N reads back from N+1 (R1 written in c1, read at c4). Same memory, two
   sampling phases. *)

let%expect_test "registers = 16×32 array model [qcheck, 500 sequences]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let w32 v = Bits.of_unsigned_int ~width:32 v in
  let check_seq ops =
    let sim = Sim.create create in
    let inp = Cyclesim.inputs sim in
    let outp = Cyclesim.outputs sim in
    let mem = Array.create ~len:16 0 in
    List.for_all ops ~f:(fun (wr, (rno0, rno1, rno2, din)) ->
      inp.wr := Bits.of_unsigned_int ~width:1 wr;
      inp.rno0 := Bits.of_unsigned_int ~width:4 rno0;
      inp.rno1 := Bits.of_unsigned_int ~width:4 rno1;
      inp.rno2 := Bits.of_unsigned_int ~width:4 rno2;
      inp.din := w32 din;
      Cyclesim.cycle sim;
      (* post-edge: the read reflects the array with this cycle's write applied — commit
         to the model, then compare *)
      if wr = 1 then mem.(rno0) <- din;
      Bits.equal !(outp.dout0) (w32 mem.(rno0))
      && Bits.equal !(outp.dout1) (w32 mem.(rno1))
      && Bits.equal !(outp.dout2) (w32 mem.(rno2)))
  in
  QCheck.Test.check_exn
    (QCheck.Test.make
       ~count:500
       ~name:"registers"
       QCheck.(
         list_size
           (Gen.int_range 1 20)
           (pair
              (int_bound 1)
              (quad (int_bound 15) (int_bound 15) (int_bound 15) (int_bound 0xFFFF_FFFF))))
       check_seq);
  [%expect {| |}]
;;

let%expect_test "registers — writes, 3-port read, wr=0 holds [waveform]" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Waveform = Hardcaml_waveterm.For_cyclesim.Waveform in
  let module D = Hardcaml_waveterm.Display_rule in
  let sim = Sim.create create in
  let waves, sim = Waveform.create sim in
  let inp = Cyclesim.inputs sim in
  let set r v w = r := Bits.of_unsigned_int ~width:w v in
  let drive ~wr ~rno0 ~rno1 ~rno2 ~din =
    set inp.wr wr 1;
    set inp.rno0 rno0 4;
    set inp.rno1 rno1 4;
    set inp.rno2 rno2 4;
    set inp.din din 32;
    Cyclesim.cycle sim
  in
  (* c1-c3 write R1,R2,R3 — each destination reads 0 pre-write, and lands next cycle; c4
     reads all three at once (wr=0, so din=DEADBEEF is ignored); c5 permutes the addresses
     and the outputs follow (async read) *)
  drive ~wr:1 ~rno0:1 ~rno1:2 ~rno2:3 ~din:0x11111111;
  drive ~wr:1 ~rno0:2 ~rno1:1 ~rno2:3 ~din:0x22222222;
  drive ~wr:1 ~rno0:3 ~rno1:1 ~rno2:2 ~din:0x33333333;
  drive ~wr:0 ~rno0:1 ~rno1:2 ~rno2:3 ~din:0xDEADBEEF;
  drive ~wr:0 ~rno0:3 ~rno1:2 ~rno2:1 ~din:0x0;
  Waveform.print
    ~display_rules:
      D.
        [ port_name_is ~wave_format:Wave_format.Bit "wr"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "rno0"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "rno1"
        ; port_name_is ~wave_format:Wave_format.Unsigned_int "rno2"
        ; port_name_is ~wave_format:Wave_format.Hex "din"
        ; port_name_is ~wave_format:Wave_format.Hex "dout0"
        ; port_name_is ~wave_format:Wave_format.Hex "dout1"
        ; port_name_is ~wave_format:Wave_format.Hex "dout2"
        ]
    ~wave_width:4
    ~display_width:70
    waves;
  [%expect
    {|
    ┌Signals────────┐┌Waves──────────────────────────────────────────────┐
    │wr             ││──────────────────────────────┐                    │
    │               ││                              └─────────────────── │
    │               ││──────────┬─────────┬─────────┬─────────┬───────── │
    │rno0           ││ 1        │2        │3        │1        │3         │
    │               ││──────────┴─────────┴─────────┴─────────┴───────── │
    │               ││──────────┬───────────────────┬─────────────────── │
    │rno1           ││ 2        │1                  │2                   │
    │               ││──────────┴───────────────────┴─────────────────── │
    │               ││────────────────────┬─────────┬─────────┬───────── │
    │rno2           ││ 3                  │2        │3        │1         │
    │               ││────────────────────┴─────────┴─────────┴───────── │
    │               ││──────────┬─────────┬─────────┬─────────┬───────── │
    │din            ││ 11111111 │22222222 │33333333 │DEADBEEF │00000000  │
    │               ││──────────┴─────────┴─────────┴─────────┴───────── │
    │               ││──────────────────────────────┬─────────┬───────── │
    │dout0          ││ 00000000                     │11111111 │33333333  │
    │               ││──────────────────────────────┴─────────┴───────── │
    │               ││──────────┬───────────────────┬─────────────────── │
    │dout1          ││ 00000000 │11111111           │22222222            │
    │               ││──────────┴───────────────────┴─────────────────── │
    │               ││────────────────────┬─────────┬─────────┬───────── │
    │dout2          ││ 00000000           │22222222 │33333333 │11111111  │
    │               ││────────────────────┴─────────┴─────────┴───────── │
    └───────────────┘└───────────────────────────────────────────────────┘
    |}]
;;
