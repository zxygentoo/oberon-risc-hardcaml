(* Public contract in [golden.mli]. *)

module R = Emu.Risc

(* the idle desktop the vendored disk image boots to (FNV-1a of the framebuffer) *)
let desktop_hash = 0xb9bdbf56ba51298dL
let fb_w = 32 (* framebuffer width in 32-px words *)
let fb_h = 768
let fb_words = fb_w * fb_h
let fb_base_word = 0x39FC0 (* display_start 0xE7F00 / 4 *)

(* Boot the oracle as the frontend / test_boot.ml does, advance [frames] at the synthetic
   60 Hz clock, and snapshot the framebuffer + its hash. *)
let boot_oracle_fb ~frames =
  let tmp = Disk.copy_to_temp Disk.image in
  let risc = Oracle.create ~disk:tmp in
  Emu.Headless.run_frames risc frames;
  let fb = Array.init fb_words (fun i -> R.framebuffer_word risc i) in
  let hash = Emu.Headless.framebuffer_hash risc in
  Disk.rm_temp tmp;
  (* the goldens are differential, so pin the reference itself: an oracle that stopped
     drawing would otherwise match a SoC that also draws nothing *)
  if not (Array.exists (fun w -> w <> 0) fb)
  then failwith "boot_oracle_fb: the oracle framebuffer is blank";
  if (not Disk.custom) && not (Int64.equal hash desktop_hash)
  then
    failwith
      (Printf.sprintf
         "boot_oracle_fb: oracle desktop hash 0x%Lx, expected the pinned 0x%Lx"
         hash
         desktop_hash);
  fb, hash
;;

let pixel fb ~x ~y = (fb.((y * fb_w) + (x / 32)) lsr (x land 31)) land 1

let popcount fb =
  Array.fold_left
    (fun acc w ->
      let rec pc n a = if n = 0 then a else pc (n lsr 1) (a + (n land 1)) in
      acc + pc (w land 0xFFFFFFFF) 0)
    0
    fb
;;

(* Downsample to ASCII: one char per [sx]x[sy] block, '#' if any pixel in the block is
   set. Rows run top (y high) to bottom (y = 0) since Oberon's origin is bottom-left. *)
let render fb ~sx ~sy =
  let buf = Buffer.create 8192 in
  let y = ref (fb_h - sy) in
  while !y >= 0 do
    for cx = 0 to (1024 / sx) - 1 do
      let set = ref false in
      for dy = 0 to sy - 1 do
        for dx = 0 to sx - 1 do
          if pixel fb ~x:((cx * sx) + dx) ~y:(!y + dy) = 1 then set := true
        done
      done;
      Buffer.add_char buf (if !set then '#' else ' ')
    done;
    Buffer.add_char buf '\n';
    y := !y - sy
  done;
  Buffer.contents buf
;;

(* FNV-1a over the framebuffer words, matching Emu.Headless.framebuffer_hash, so a SoC
   framebuffer hash compares directly to the oracle's. *)
let fb_fnv fb =
  let prime = 0x0000_0100_0000_01b3L
  and offset = 0xcbf2_9ce4_8422_2325L in
  let word h w =
    List.fold_left
      (fun h k ->
        Int64.mul (Int64.logxor h (Int64.of_int ((w lsr (k * 8)) land 0xFF))) prime)
      h
      [ 0; 1; 2; 3 ]
  in
  Array.fold_left word offset fb
;;

(* The goldens' settle loop: run [chunk]-cycle bursts of [tick] and snapshot [read_fb]
   after each, until the framebuffer is drawn (nonzero) and then unchanged for [settle]
   consecutive chunks, or [cap] cycles. [pc]/[spi_bytes] feed the progress line only.
   [?target] short-circuits: once the snapshot hashes to the oracle's value the verdict is
   already decided (the report re-diffs word-exact), so the stability confirmation would
   only burn [settle] more chunks — exit immediately instead. Returns (last framebuffer,
   settled?). *)
let run_to_settle ?target ~cap ~chunk ~settle ~tick ~read_fb ~pc ~spi_bytes () =
  let cyc = ref 0
  and prev = ref [||]
  and stable = ref 0
  and matched = ref false
  and drawn = ref false in
  while !cyc < cap && !stable < settle && not !matched do
    for _ = 1 to chunk do
      tick ();
      incr cyc
    done;
    let fb = read_fb () in
    let pop = popcount fb in
    if pop > 0 then drawn := true;
    if !drawn && fb = !prev then incr stable else stable := 0;
    prev := fb;
    (match target with
     | Some t when Int64.equal (fb_fnv fb) t -> matched := true
     | _ -> ());
    Printf.printf
      "  soc @%3dM cyc: pc=0x%X spi=%d pop=%d%s\n%!"
      (!cyc / 1_000_000)
      (pc ())
      (spi_bytes ())
      pop
      (if !matched then "  (= oracle hash — early exit)" else "")
  done;
  !prev, !stable >= settle || !matched
;;

(* The scan-out half of the goldens' verdict: the image rebuilt from the [rgb] pins over
   one raster frame ({!Tb.scan_frame}) must equal the framebuffer memory the golden
   hashed, with nothing lit in blanking. Prints the verdict; exits on failure. *)
let scanout_report ~soc_fb ~scan ~stray =
  let diffs = ref 0
  and first = ref (-1) in
  Array.iteri
    (fun i w ->
      if w <> soc_fb.(i)
      then (
        incr diffs;
        if !first < 0 then first := i))
    scan;
  if !diffs = 0 && stray = 0
  then
    Printf.printf
      "SCANOUT PASS — one raster frame off the rgb pins reproduces the framebuffer \
       pixel-exact (%d px lit, blanking dark)\n"
      (popcount scan)
  else (
    Printf.printf
      "SCANOUT FAIL: %d/%d words differ from the framebuffer (first word %d: rgb=0x%08X \
       fb=0x%08X); %d px lit in blanking\n"
      !diffs
      fb_words
      !first
      (if !first >= 0 then scan.(!first) else 0)
      (if !first >= 0 then soc_fb.(!first) else 0)
      stray;
    exit 1)
;;

(* The goldens' verdict: diff the framebuffers word-for-word, render both to ASCII, print
   PASS or FAIL-and-exit. [machine] names the SoC under test in the report. *)
let report ~machine ~oracle_fb ~oracle_hash ~soc_fb ~soc_hash ~settled =
  let diffs = ref 0
  and first = ref (-1) in
  Array.iteri
    (fun i w ->
      if w <> oracle_fb.(i)
      then (
        incr diffs;
        if !first < 0 then first := i))
    soc_fb;
  Printf.printf
    "--- oracle ---\n%s\n--- %s ---\n%s\n%!"
    (render oracle_fb ~sx:16 ~sy:16)
    machine
    (render soc_fb ~sx:16 ~sy:16);
  if !diffs = 0 && Int64.equal soc_hash oracle_hash
  then
    Printf.printf
      "VISUAL GOLDEN PASS — %s: framebuffer byte-identical to the oracle (hash 0x%Lx)\n"
      machine
      oracle_hash
  else (
    Printf.printf
      "VISUAL GOLDEN FAIL — %s: %d/%d framebuffer words differ (first word 0x%X: \
       soc=0x%08X oracle=0x%08X); settled=%b\n"
      machine
      !diffs
      fb_words
      (if !first >= 0 then fb_base_word + !first else 0)
      (if !first >= 0 then soc_fb.(!first) else 0)
      (if !first >= 0 then oracle_fb.(!first) else 0)
      settled;
    exit 1)
;;
