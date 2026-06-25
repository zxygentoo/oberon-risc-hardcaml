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
  let count_v = count.value in
  let filter_v = filter.value in
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
   basic sanity smoke here (elaborates + the request-to-send oscillator runs while the
   lines are idle); the interactive device-model verification (playing a PS/2 mouse
   through the bidirectional init dialogue + report accumulation) is built with
   hardcaml_step_testbench next, and the exhaustive fidelity check vs MousePM.v is the
   Verilator co-sim. *)

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
