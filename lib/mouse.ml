(* Public API and behaviour spec live in [mouse.mli].

   Port of [MousePM.v] (module [MouseP]). The mouse is bidirectional: [msclk]/[msdat] are
   open-drain inout in the RTL ([line = drive ? 0 : z]). Hardcaml has no inout, so each
   splits into a drive-low output ([*_oe]) + the resolved wire-value input; the open-drain
   wired-AND lives in the pad/testbench.

   Two phases, sequenced by [sent] (0..7) with [run = sent==7]:
   - INIT: send 7 commands ([cmd] — the IntelliMouse set-sample-rate 200/100/80 + enable
     scroll-button magic). Each needs a request-to-send: [req] pulls [msclk] low for ~1.1
     ms ([endcount] = [count] reaching count[14:12]==7 @25 MHz), then releases and clocks
     the 9-bit command out of [tx] on [msdat] (driven by [~tx[0]]) while the device
     clocks.
   - REPORT: the device streams 33-bit packets; [rx] assembles each (walking start bit,
     like [PS2.v]: preloaded all-1s, [endbit] when the marker reaches rx[0] for reports /
     rx[10] for commands), then [x]+=dx, [y]+=dy and [btns] latch on [done].

   [shift] is the bit strobe: a debounced [msclk] falling edge ([filter] = a 10-tap shift
   of [msclk], [shift] = ~req & filter==1). [done] = endbit & endcount & ~req completes a
   frame. [filter] has no reset (it just tracks [msclk]); [rst] (active-low) is woven into
   the other next-states, and [x]/[y]/[btns] clear on [~run]. Clock-only [Reg_spec], like
   the peers. *)

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
  (* the init command sequence, 9-bit (incl. odd parity); 0x1F3 = "set sample rate" *)
  let cmd =
    mux2
      (sent_v ==:. 0)
      (of_unsigned_int ~width:9 0x0F4)
      (mux2
         (sent_v ==:. 2)
         (of_unsigned_int ~width:9 0x0C8)
         (mux2
            (sent_v ==:. 4)
            (of_unsigned_int ~width:9 0x064)
            (mux2
               (sent_v ==:. 6)
               (of_unsigned_int ~width:9 0x150)
               (of_unsigned_int ~width:9 0x1F3))))
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
  (* request-to-send toggle: [req] flips each [endcount] while idle. Bound here (not
     inline) because [<--] shares precedence/associativity with [&:], so a bare op-chain
     RHS would mis-parse as [(req <-- …) &: …]. *)
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

(* ── Tests (co-located; AGENT.md §6) ────────────────────────────────────────────── A
   basic sanity smoke (elaborates + the request-to-send oscillator runs while idle), then
   an interactive device-model test: a plain-Cyclesim loop plays a PS/2 mouse — through
   the bidirectional init handshake to [run], then streaming movement reports — and checks
   the accumulated [x]/[y]/[btns]. The exhaustive bit-for-bit fidelity check vs
   [MousePM.v] is the Verilator co-sim. *)

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

(* The interactive PS/2-mouse device, played against the DUT on a plain Cyclesim loop. (We
   evaluated hardcaml_step_testbench here — its coroutine fits an interactive protocol —
   but the device is a single sequential task that uses none of its concurrency, and its
   per-cycle overhead made this ~5x slower over the ~350K-cycle init; see the
   step-testbench-deferred memory.) [cyc] advances one cycle after resolving the
   open-drain lines; [pulse] is one device clock; [send_byte] streams a device->host
   frame. *)

let%expect_test "mouse — device model: init handshake, then a movement report accumulates"
  =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let bit1 b = Bits.of_unsigned_int ~width:1 (if b then 1 else 0) in
  let rd r = Bits.to_int_trunc !r in
  let dev_msclk_low = ref false
  and dev_msdat_low = ref false in
  (* open-drain wired-AND: each line = ~(host pulls low | device pulls low) *)
  let resolve () =
    inp.msclk := bit1 (not (rd outp.msclk_oe = 1 || !dev_msclk_low));
    inp.msdat := bit1 (not (rd outp.msdat_oe = 1 || !dev_msdat_low))
  in
  let cyc () =
    resolve ();
    Cyclesim.cycle sim
  in
  let wait_until cond cap =
    let g = ref 0 in
    while (not (cond ())) && !g < cap do
      cyc ();
      g := !g + 1
    done
  in
  (* one device clock pulse: high a few cycles, then low long enough (>9 @ the 10-tap
     [filter]) for the DUT to see a debounced falling edge and [shift] *)
  let pulse () =
    dev_msclk_low := false;
    for _ = 1 to 6 do
      cyc ()
    done;
    dev_msclk_low := true;
    for _ = 1 to 16 do
      cyc ()
    done
  in
  (* out = {run, btns[2:0], 2'b0, y[9:0], 2'b0, x[9:0]} — read state straight from the port *)
  let run () = (rd outp.out lsr 27) land 1 = 1 in
  let xpos () = rd outp.out land 0x3FF in
  let ypos () = (rd outp.out lsr 12) land 0x3FF in
  let btns () = (rd outp.out lsr 24) land 7 in
  inp.rst_n := bit1 true;
  inp.msclk := bit1 true;
  inp.msdat := bit1 true;
  (* INIT: clock each command through the request-to-send handshake (msclk_oe 0->1->0,
     then clock the 9-bit frame, then idle so the DUT's [endcount] fires [done] ->
     [sent]++). Completion shows as the next inhibit (msclk_oe->1) — or [run] for the last
     command. *)
  let guard = ref 0 in
  while (not (run ())) && !guard < 8 do
    wait_until (fun () -> rd outp.msclk_oe = 1 || run ()) 60000;
    wait_until (fun () -> rd outp.msclk_oe = 0 || run ()) 60000;
    if not (run ())
    then (
      for _ = 1 to 25 do
        pulse ()
      done;
      dev_msclk_low := false;
      wait_until (fun () -> rd outp.msclk_oe = 1 || run ()) 60000);
    guard := !guard + 1
  done;
  Stdlib.Printf.printf "init: run=%d\n" (if run () then 1 else 0);
  (* REPORT: the device streams 3-byte movement packets (drives msdat + clocks), then
     idles so the DUT's [endcount]/[done] assembles each. Each byte is framed
     start/8-data-LSB-first/odd-parity/stop; status 0x08 = no buttons, +ve, no overflow. *)
  let parity b =
    let n = ref 0 in
    for i = 0 to 7 do
      n := !n + ((b lsr i) land 1)
    done;
    1 - (!n land 1)
  in
  let send_bit v =
    dev_msdat_low := not v;
    pulse ()
  in
  let send_byte b =
    send_bit false;
    for i = 0 to 7 do
      send_bit ((b lsr i) land 1 = 1)
    done;
    send_bit (parity b = 1);
    send_bit true
  in
  let send_report ~status ~mx ~my =
    let x0 = xpos ()
    and y0 = ypos () in
    send_byte status;
    send_byte mx;
    send_byte my;
    dev_msdat_low := false;
    (* idle for the DUT's [endcount] -> [done] -> accumulate *)
    wait_until (fun () -> xpos () <> x0 || ypos () <> y0) 40000
  in
  send_report ~status:0x08 ~mx:3 ~my:5;
  Stdlib.Printf.printf "report 1: x=%d y=%d btns=%d\n" (xpos ()) (ypos ()) (btns ());
  (* a second report accumulates onto the first (x += dx), it does not overwrite *)
  send_report ~status:0x08 ~mx:2 ~my:1;
  Stdlib.Printf.printf "report 2: x=%d y=%d btns=%d\n" (xpos ()) (ypos ()) (btns ());
  [%expect
    {|
    init: run=1
    report 1: x=3 y=5 btns=0
    report 2: x=5 y=6 btns=0
    |}]
;;
