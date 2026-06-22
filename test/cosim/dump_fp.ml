(* Consolidated RTL-fidelity dumper for the FP units. Drives a Hardcaml FP unit (selected
   by the first argument) over a stimulus set and writes "x y z" / "x y u v z" lines,
   which the matching Verilator harness (test/cosim/<unit>.cpp) replays through the
   reference _po/verilog/src/<Unit>.v to assert RTL z == port z. This is a port-vs-RTL
   FIDELITY check, so the stimuli are (a) the frozen fp_vectors lines tagged for this unit
   (the expected-z column is ignored — we compare against the RTL, not the software
   oracle) and (b) a deterministic random fuzz pass for breadth.

   The three FP units share one dumper because the drive protocol (run -> drain on stall
   -> read z) is identical; they differ only in the modifier bits (the adder carries u/v
   for FLT/FLOOR, mul/div don't) and the frozen-vector line tag (A / M / D). A per-unit
   [driver] captures exactly those two differences; everything else below is shared.

   Usage: dump_fp <fp_adder|fp_multiplier|fp_divider> <path to fp_vectors.txt> (-> stdout) *)

open Hardcaml

(* set an input ref to [v], using the port's own declared width (1 for run, 32 for
   x/y/...). *)
let set r v = r := Bits.of_unsigned_int ~width:(Bits.width !r) v

(* the shared run -> drain -> read -> release protocol. [run]/[stall]/[z] are the unit's
   ports (the same [Bits.t ref] type across all three units), and [sim] is used
   polymorphically — the caller has already set the data inputs (x/y and any u/v) for this
   op. *)
let drive sim ~run ~stall ~z =
  set run 1;
  Cyclesim.cycle sim;
  let safety = ref 0 in
  while Bits.to_int_trunc !stall = 1 do
    Cyclesim.cycle sim;
    incr safety;
    if !safety > 40 then failwith "FP unit did not terminate"
  done;
  let result = Bits.to_unsigned_int !z in
  set run 0;
  Cyclesim.cycle sim;
  result
;;

(* a unit-specific driver: its frozen-vector line [tag], whether it carries u/v modifiers,
   and a closure that drives one op (setting only the inputs that unit actually has) and
   returns z. *)
type driver =
  { tag : string
  ; has_uv : bool
  ; run : u:int -> v:int -> x:int -> y:int -> int
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

(* fp_divider's driver slots in here once Risc5.Fp_divider lands — identical to
   [mul_driver] but over Fp_divider and tag "D". *)

let () =
  let unit_name = Sys.argv.(1) in
  let vectors_path = Sys.argv.(2) in
  let d =
    match unit_name with
    | "fp_adder" -> adder_driver ()
    | "fp_multiplier" -> mul_driver ()
    | other -> failwith (Printf.sprintf "dump_fp: unknown unit %S" other)
  in
  let n = ref 0 in
  let emit ~u ~v ~x ~y =
    incr n;
    let z = d.run ~u ~v ~x ~y in
    if d.has_uv
    then Printf.printf "%08X %08X %d %d %08X\n" x y u v z
    else Printf.printf "%08X %08X %08X\n" x y z
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
  let rand32 () =
    (Random.State.int rng 0x10000 lsl 16) lor Random.State.int rng 0x10000
  in
  for _ = 1 to 20000 do
    let u = if d.has_uv then Random.State.int rng 2 else 0 in
    let v = if d.has_uv then Random.State.int rng 2 else 0 in
    let x = rand32 () in
    let y = rand32 () in
    emit ~u ~v ~x ~y
  done;
  Printf.eprintf
    "dump_fp(%s): %d stimuli (fp_vectors %s-lines + 20000 fuzz)\n"
    unit_name
    !n
    d.tag
;;
