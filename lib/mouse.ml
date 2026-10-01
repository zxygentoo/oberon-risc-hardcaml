(* A port of MousePM.v (module [MouseP]); the contract is in [mouse.mli].

   Initialisation: [cmd] holds the seven commands. For each, [req] pulls [msclk] low until
   [endcount] (about 1.1 ms at 25 MHz), then the 9-bit command leaves [tx] on [msdat],
   driven by [~tx[0]], on the device's clock. Reports: [rx] assembles each packet with a
   walking start bit — preloaded with ones, [endbit] when the marker reaches rx[0] for a
   report or rx[10] for a command — and [x], [y] and [btns] update on [done].

   [shift] is the bit strobe, a debounced falling edge of [msclk]: [filter] is a 10-tap
   shift register of [msclk]. [done = endbit & endcount & ~req] completes a frame.
   [filter] has no reset; the other registers take the active-low reset in their next-
   state logic, and [x]/[y]/[btns] are cleared while [run] is low. *)

open Hardcaml
open Signal

module I = struct
  type 'a t =
    { clock : 'a
    ; rst_n : 'a [@bits 1]
    ; msclk : 'a [@bits 1]
    ; msdat : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

module O = struct
  type 'a t =
    { msclk_oe : 'a [@bits 1]
    ; msdat_oe : 'a [@bits 1]
    ; out : 'a [@bits 28]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  let reset = ~:(i.rst_n) in
  let rx = Always.Variable.reg spec ~width:31 in
  let count = Always.Variable.reg spec ~width:15 in
  let filter = Always.Variable.reg spec ~width:10 in
  let tx = Always.Variable.reg spec ~width:10 in
  let x = Always.Variable.reg spec ~width:10 in
  let y = Always.Variable.reg spec ~width:10 in
  let btns = Always.Variable.reg spec ~width:3 in
  let sent = Always.Variable.reg spec ~width:3 in
  let req = Always.Variable.reg spec ~width:1 in
  let rx_v = rx.value -- "rx" in
  let count_v = count.value -- "count" in
  let filter_v = filter.value -- "filter" in
  let tx_v = tx.value -- "tx" in
  let x_v = x.value -- "x" in
  let y_v = y.value -- "y" in
  let btns_v = btns.value -- "btns" in
  let sent_v = sent.value -- "sent" in
  let req_v = req.value -- "req" in
  (* ── combinational ────────────────────────────────────────────────────────── *)
  let run = (sent_v ==:. 7) -- "run" in
  (* the init command sequence by [sent] slot, 9-bit (incl. odd parity): even slots are
     the payload bytes (0xF4 enable, then the IntelliMouse rates 200/100/80+scroll magic),
     odd slots are 0x1F3 "set sample rate" (slot 7 is dead — [run] holds [tx] at all-1s) *)
  let cmd =
    let c = of_unsigned_int ~width:9 in
    mux sent_v [ c 0x0F4; c 0x1F3; c 0x0C8; c 0x1F3; c 0x064; c 0x1F3; c 0x150; c 0x1F3 ]
  in
  let endcount = (select count_v ~high:14 ~low:12 ==:. 7) -- "endcount" in
  let shift = (~:req_v &: (filter_v ==:. 1)) -- "shift" in
  let endbit = mux2 run ~:(lsb rx_v) ~:(bit rx_v ~pos:10) -- "endbit" in
  let done_ = (endbit &: endcount &: ~:req_v) -- "done" in
  (* signed dx/dy with overflow (rx[7]/rx[8]) zeroing, sign from rx[5]/rx[6] *)
  let dx =
    concat_msb
      [ repeat (bit rx_v ~pos:5) ~count:2
      ; mux2 (bit rx_v ~pos:7) (zero 8) (select rx_v ~high:19 ~low:12)
      ]
  in
  let dy =
    concat_msb
      [ repeat (bit rx_v ~pos:6) ~count:2
      ; mux2 (bit rx_v ~pos:8) (zero 8) (select rx_v ~high:30 ~low:23)
      ]
  in
  (* bound by name first: [<--] has the same precedence as [&:], so the chain written
     inline would parse as [(req <-- …) &: …] *)
  let req_next = i.rst_n &: ~:run &: req_v ^: endcount in
  (* ── next-state ───────────────────────────────────────────────────────────── *)
  Always.(
    compile
      [ filter <-- concat_msb [ i.msclk; select filter_v ~high:9 ~low:1 ]
      ; count <-- mux2 (reset |: shift |: endcount) (zero 15) (count_v +:. 1)
      ; req <-- req_next
      ; sent <-- mux2 reset (zero 3) (mux2 (done_ &: ~:run) (sent_v +:. 1) sent_v)
      ; tx
        <-- mux2
              (reset |: run)
              (of_unsigned_int ~width:10 0x3FF)
              (mux2
                 req_v
                 (concat_msb [ cmd; gnd ])
                 (mux2 shift (concat_msb [ vdd; select tx_v ~high:9 ~low:1 ]) tx_v))
      ; rx
        <-- mux2
              (reset |: done_)
              (of_unsigned_int ~width:31 0x7FFFFFFF)
              (mux2
                 (shift &: ~:endbit)
                 (concat_msb [ i.msdat; select rx_v ~high:30 ~low:1 ])
                 rx_v)
      ; x <-- mux2 ~:run (zero 10) (mux2 done_ (x_v +: dx) x_v)
      ; y <-- mux2 ~:run (zero 10) (mux2 done_ (y_v +: dy) y_v)
      ; btns
        <-- mux2
              ~:run
              (zero 3)
              (mux2
                 done_
                 (concat_msb [ bit rx_v ~pos:1; bit rx_v ~pos:3; bit rx_v ~pos:2 ])
                 btns_v)
      ]);
  (* ── outputs ──────────────────────────────────────────────────────────────── *)
  let out = concat_msb [ run; btns_v; zero 2; y_v; zero 2; x_v ] in
  { O.msclk_oe = req_v; msdat_oe = ~:(lsb tx_v); out }
;;

(* ── Tests ── The request-to-send oscillator runs with no device attached; then a device
   model takes the port through the initialisation handshake to [run] and sends movement
   reports. Fidelity to MousePM.v is the co-simulation's and the proof's job. *)

let%expect_test "mouse — smoke: elaborates; req (msclk_oe) oscillates while idle" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let bit1 v = Bits.of_unsigned_int ~width:1 v in
  inp.rst_n := bit1 1;
  (* idle, open-drain pulled high (no device) *)
  inp.msclk := bit1 1;
  inp.msdat := bit1 1;
  (* ~1.1 ms request-to-send period is ~28672 cycles @25 MHz; run past two of them *)
  let toggles = ref 0
  and prev = ref 0 in
  for _ = 1 to 70000 do
    Cyclesim.cycle sim;
    let r = Bits.to_int_trunc !(outp.msclk_oe) in
    if r <> !prev then toggles := !toggles + 1;
    prev := r
  done;
  Stdlib.Printf.printf
    "msclk_oe toggles=%d  out=%08x  (idle: no device, init cannot complete)\n"
    !toggles
    (Bits.to_int_trunc !(outp.out));
  [%expect
    {| msclk_oe toggles=2  out=00000000  (idle: no device, init cannot complete) |}]
;;

module For_tests = struct
  (* The PS/2 mouse on the other end of the wire, played against the port on a plain
     Cyclesim loop. (hardcaml_step_testbench was tried here — its coroutines fit an
     interactive protocol — but the device is a single sequential task that uses none of
     that concurrency, and the per-cycle overhead made the ~350K-cycle init about 5x
     slower.) *)
  module Device = struct
    type t =
      { cyc : unit -> unit (* resolve the open-drain lines, then one clock *)
      ; out : unit -> int
      ; msclk_oe : unit -> int
      ; msclk_low : bool ref (* the device's own pull-lows *)
      ; msdat_low : bool ref
      }

    let attach ?(on_cycle = fun ~msclk_low:_ ~msdat_low:_ -> ()) sim =
      let inp : _ I.t = Cyclesim.inputs sim
      and outp : _ O.t = Cyclesim.outputs sim in
      let bit1 b = Bits.of_unsigned_int ~width:1 (if b then 1 else 0) in
      let rd r = Bits.to_int_trunc !r in
      let msclk_low = ref false
      and msdat_low = ref false in
      inp.rst_n := bit1 true;
      inp.msclk := bit1 true;
      inp.msdat := bit1 true;
      let cyc () =
        (* open-drain wired-AND: each line = ~(host pulls low | device pulls low) *)
        inp.msclk := bit1 (not (rd outp.msclk_oe = 1 || !msclk_low));
        inp.msdat := bit1 (not (rd outp.msdat_oe = 1 || !msdat_low));
        Cyclesim.cycle sim;
        on_cycle ~msclk_low:!msclk_low ~msdat_low:!msdat_low
      in
      { cyc
      ; out = (fun () -> rd outp.out)
      ; msclk_oe = (fun () -> rd outp.msclk_oe)
      ; msclk_low
      ; msdat_low
      }
    ;;

    (* out = {run, btns[2:0], 2'b0, y[9:0], 2'b0, x[9:0]} *)
    let run t = (t.out () lsr 27) land 1 = 1
    let btns t = (t.out () lsr 24) land 7
    let y t = (t.out () lsr 12) land 0x3FF
    let x t = t.out () land 0x3FF

    let wait_until t cond ~cap =
      let g = ref 0 in
      while (not (cond ())) && !g < cap do
        t.cyc ();
        g := !g + 1
      done
    ;;

    (* one device clock pulse: high a few cycles, then low long enough (>9, the 10-tap
       [filter]) for the port to see a debounced falling edge and [shift] *)
    let pulse t =
      t.msclk_low := false;
      for _ = 1 to 6 do
        t.cyc ()
      done;
      t.msclk_low := true;
      for _ = 1 to 16 do
        t.cyc ()
      done
    ;;

    (* Clock each init command through the request-to-send handshake ([msclk_oe] 0->1->0,
       then the 9-bit frame, then idle so the port's [endcount] fires [done] and [sent]
       advances). Completion shows as the next inhibit ([msclk_oe] -> 1), or as [run]
       after the last command. *)
    let init t =
      let guard = ref 0 in
      while (not (run t)) && !guard < 8 do
        wait_until t (fun () -> t.msclk_oe () = 1 || run t) ~cap:60000;
        wait_until t (fun () -> t.msclk_oe () = 0 || run t) ~cap:60000;
        if not (run t)
        then (
          for _ = 1 to 25 do
            pulse t
          done;
          t.msclk_low := false;
          wait_until t (fun () -> t.msclk_oe () = 1 || run t) ~cap:60000);
        guard := !guard + 1
      done
    ;;

    let send_byte t b =
      List.iter
        (fun v ->
          t.msdat_low := not v;
          pulse t)
        (Ps2.For_tests.frame_bits b)
    ;;

    (* a 3-byte movement packet, then idle until the port's [endcount] -> [done] has
       accumulated it *)
    let send_report t ~status ~mx ~my =
      let x0 = x t
      and y0 = y t in
      send_byte t status;
      send_byte t mx;
      send_byte t my;
      t.msdat_low := false;
      wait_until t (fun () -> x t <> x0 || y t <> y0) ~cap:40000
    ;;
  end
end

let%expect_test "mouse — device model: init handshake, then a movement report accumulates"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let module Device = For_tests.Device in
  let dev = Device.attach (Sim.create create) in
  Device.init dev;
  Stdlib.Printf.printf "init: run=%d\n" (if Device.run dev then 1 else 0);
  (* status 0x08 = no buttons, +ve, no overflow *)
  let report () =
    Stdlib.Printf.sprintf
      "x=%d y=%d btns=%d"
      (Device.x dev)
      (Device.y dev)
      (Device.btns dev)
  in
  Device.send_report dev ~status:0x08 ~mx:3 ~my:5;
  Stdlib.Printf.printf "report 1: %s\n" (report ());
  (* a second report accumulates onto the first (x += dx), it does not overwrite *)
  Device.send_report dev ~status:0x08 ~mx:2 ~my:1;
  Stdlib.Printf.printf "report 2: %s\n" (report ());
  [%expect
    {|
    init: run=1
    report 1: x=3 y=5 btns=0
    report 2: x=5 y=6 btns=0
    |}]
;;
