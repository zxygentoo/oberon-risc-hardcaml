(* Consolidated RTL-fidelity dumper for the FP units. Drives a Hardcaml FP unit (selected
   by the first argument) over a stimulus set and writes "x y z cycles" / "x y u v z
   cycles" lines (cycles = how many clock cycles the unit stalls), which the matching
   Verilator harness (test/cosim/<unit>.cpp) replays through the reference
   test/_po/verilog/src/<Unit>.v to assert RTL z == port z AND RTL stall-length == port
   stall-length — value- AND cycle-fidelity, the latter the simulation preview of the
   Phase-8 equivalence proof. This is a port-vs-RTL FIDELITY check, so the stimuli are (a)
   the frozen fp_vectors lines tagged for this unit (the expected-z column is ignored — we
   compare against the RTL, not the software oracle) and (b) a deterministic random fuzz
   pass for breadth.

   The three FP units share one dumper because the drive protocol (run -> drain on stall
   -> read z) is identical; they differ only in the modifier bits (the adder carries u/v
   for FLT/FLOOR, mul/div don't) and the frozen-vector line tag (A / M / D). A per-unit
   [driver] captures exactly those two differences; everything else below is shared.

   Usage: fp_dump <fp_adder|fp_multiplier|fp_divider> <path to fp_vectors.txt> (-> stdout) *)

open Hardcaml
open Cosim_dump

(* the shared run -> drain -> read -> release protocol. [run]/[stall]/[z] are the unit's
   ports (the same [Bits.t ref] type across all three units), and [sim] is used
   polymorphically — the caller has already set the data inputs (x/y and any u/v) for this
   op. *)
let drive sim ~run ~stall ~z =
  set run 1;
  Cyclesim.cycle sim;
  (* [cycles] counts the clock cycles with [run] asserted until [stall] drops — i.e. the
     stall length (= the unit's state-counter terminal: FPAdd 3, FPMul 25, FPDiv 26). The
     <unit>.cpp drives the RTL with the identical run -> drain protocol and the identical
     count, so equal counts ⇔ the port stalls for exactly as many cycles as the RTL. *)
  let cycles = ref 1 in
  while Bits.to_int_trunc !stall = 1 do
    Cyclesim.cycle sim;
    incr cycles;
    if !cycles > 40 then failwith "FP unit did not terminate"
  done;
  let result = Bits.to_unsigned_int !z in
  set run 0;
  Cyclesim.cycle sim;
  result, !cycles
;;

(* a unit-specific driver: its frozen-vector line [tag], whether it carries u/v modifiers,
   and a closure that drives one op (setting only the inputs that unit actually has) and
   returns (z, stall-cycle count). *)
type driver =
  { tag : string
  ; has_uv : bool
  ; run : u:int -> v:int -> x:int -> y:int -> int * int (* z, stall-cycle count *)
  }

let adder_driver () =
  let module A = Risc5.Fp_adder in
  let module Sim = Cyclesim.With_interface (A.I) (A.O) in
  let sim = Sim.create A.create in
  let inp = (Cyclesim.inputs sim : _ A.I.t)
  and outp = (Cyclesim.outputs sim : _ A.O.t) in
  let run ~u ~v ~x ~y =
    set inp.u u;
    set inp.v v;
    set inp.x x;
    set inp.y y;
    drive sim ~run:inp.run ~stall:outp.stall ~z:outp.z
  in
  { tag = "A"; has_uv = true; run }
;;

let mul_driver () =
  let module M = Risc5.Fp_multiplier in
  let module Sim = Cyclesim.With_interface (M.I) (M.O) in
  let sim = Sim.create M.create in
  let inp = (Cyclesim.inputs sim : _ M.I.t)
  and outp = (Cyclesim.outputs sim : _ M.O.t) in
  let run ~u:_ ~v:_ ~x ~y =
    set inp.x x;
    set inp.y y;
    drive sim ~run:inp.run ~stall:outp.stall ~z:outp.z
  in
  { tag = "M"; has_uv = false; run }
;;

let div_driver () =
  let module D = Risc5.Fp_divider in
  let module Sim = Cyclesim.With_interface (D.I) (D.O) in
  let sim = Sim.create D.create in
  let inp = (Cyclesim.inputs sim : _ D.I.t)
  and outp = (Cyclesim.outputs sim : _ D.O.t) in
  let run ~u:_ ~v:_ ~x ~y =
    set inp.x x;
    set inp.y y;
    drive sim ~run:inp.run ~stall:outp.stall ~z:outp.z
  in
  { tag = "D"; has_uv = false; run }
;;

let () =
  let unit_name = Sys.argv.(1) in
  let vectors_path = Sys.argv.(2) in
  let d =
    match unit_name with
    | "fp_adder" -> adder_driver ()
    | "fp_multiplier" -> mul_driver ()
    | "fp_divider" -> div_driver ()
    | other -> failwith (Printf.sprintf "fp_dump: unknown unit %S" other)
  in
  let n = ref 0 in
  let emit ~u ~v ~x ~y =
    incr n;
    let z, cycles = d.run ~u ~v ~x ~y in
    if d.has_uv
    then Printf.printf "%08X %08X %d %d %08X %d\n" x y u v z cycles
    else Printf.printf "%08X %08X %08X %d\n" x y z cycles
  in
  (* (a) corner stimuli: the frozen vectors tagged for this unit (expected-z column
         ignored). *)
  let h s = int_of_string ("0x" ^ s) in
  let ic = open_in vectors_path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      try
        while true do
          match
            String.split_on_char ' ' (input_line ic) |> List.filter (fun s -> s <> "")
          with
          | tag :: rest when String.equal tag d.tag ->
            (match rest, d.has_uv with
             | [ x; y; u; v; _ ], true -> emit ~u:(h u) ~v:(h v) ~x:(h x) ~y:(h y)
             | [ x; y; _ ], false -> emit ~u:0 ~v:0 ~x:(h x) ~y:(h y)
             | _ -> ())
          | _ -> ()
        done
      with
      | End_of_file -> ());
  (* (b) fuzz: deterministic random stimuli for breadth — any 32-bit pattern is a valid
     fidelity stimulus (port vs RTL, not against IEEE semantics). Each draw is bound with
     an explicit let so the RNG consumption order is independent of argument-evaluation
     order. *)
  let rng = Random.State.make [| 0xF9_AD |] in
  for _ = 1 to 20000 do
    let u = if d.has_uv then Random.State.int rng 2 else 0 in
    let v = if d.has_uv then Random.State.int rng 2 else 0 in
    let x = rand32 rng in
    let y = rand32 rng in
    emit ~u ~v ~x ~y
  done;
  Printf.eprintf
    "fp_dump(%s): %d stimuli (fp_vectors %s-lines + 20000 fuzz)\n"
    unit_name
    !n
    d.tag
;;
