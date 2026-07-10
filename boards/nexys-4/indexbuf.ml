(* Public API and behaviour spec live in [indexbuf.mli].

   Implementation notes.

   The decision function is ordered dithering's per-output-bit core: bit =
   (lum[src[x/3.2]] > thr[thr_row][x & 63]) — DOOM's [__dg_dither_fs] is one instance of
   it (the hash test pins that equivalence with the DOOM table). The GEOMETRY is baked (it
   is the mode); the CONTENT — LUT and threshold map — is client-uploaded at runtime:

   - [row_map_image] (1024 x 14 ROM): output row y -> [{sy[8], thr_row[6]}] — the 200 ->
     768 Bresenham (acc += 96 per source line, deal acc/25 output rows) with the out2
     alternation baked in. Indexed by y = ~raw_row: [vidadr = org + {~vcnt, col}]
     (video.mli), so the 10-bit complement of the span row IS the screen row — the
     machine's bottom-up flip costs one bitwise NOT. Rows 768..1023 (blanking-time
     lookahead) are don't-care entries; a fetch there still acks (garbage data is never
     displayed).

   - the slot-threshold RAM (2048 x 32, four byte lanes, CPU-written at [thr_base]):
     [{thr_row[6], phase[1], slot[4]}] -> the slot's 3-or-4 thresholds, one byte each, K=3
     slots padded with 255 — an 8-bit luminance can never exceed 255, so comparing all
     four unconditionally is K-awareness for free. phase = col LSB: the threshold column =
     (32*col + bit) & 63 = 32*(col & 1) + bit, since bit <= 31. [slot_quad] is the
     packing's OCaml shape (tests upload with it; DOOM's __dg_upload_thresholds and
     Mandel.Mod's Upload are the C/Oberon shapes).

   The compose FSM (one word = 32 output px = 10 source bytes, slot j = byte src_base + j,
   src_base = sy*320 + col*10):

   cnt 0 idle; vidreq latches [{col, rr, par}] + the row-map read, clears acc, cnt := 1
   cnt 1..10 present pixel-RAM + threshold-RAM read addresses for slot j = cnt-1 (sync
   reads); pipe [{jd, lane_d, vd}] into the compute stage cnt 2..11 slot jd's byte + quad
   are out: lane-mux -> async LUT -> 4 compares -> OR into acc at xoff[jd] cnt 12 vid_ack;
   cnt := 0. Latency 12 clk — inside Video's ~2-group prefetch budget (~59 clk at 60 MHz)
   and its ~29.5-clk sustained request spacing.

   Verification, three rungs here (the DOOM repo's doom_sim golden is the fourth): a
   full-frame FNV hash of the OCaml model ≡ the gcc-compiled shipped dither.c (recipe at
   the test), a random differential hardware ≡ model through the real write/read ports —
   including the threshold-upload contract with three different tables — and a
   framebuf-style write-path/mode test. *)

open! Base
open Hardcaml
open Signal

let base = 0x310000
let size = 0x10000
let lut_off = 64000
let ctl_off = 64256

(* the slot-threshold table's own 8 KiB window (carved from the ABI §8 spare row, just
   below the pixel window): 2048 CPU-written quads — the hardware ships CONTENT-FREE,
   every client uploads its rendition before mode-on *)
let thr_base = 0x30E000
let thr_size = 0x2000

(* ── the out2 fullscreen geometry (dither.c's __dg_dither_fs, transliterated) ── *)

(* slot j of a word covers xw[j] output bits starting at bit xoff[j] (LSB leftmost) *)
let xw = [| 3; 3; 3; 3; 4; 3; 3; 3; 3; 4 |]
let xoff = [| 0; 3; 6; 9; 12; 16; 19; 22; 25; 28 |]

(* output row y (0..767) -> (source row, threshold-map row). Entries 768..1023 pad the
   10-bit index space (blanking-row fetches; don't-care). *)
let row_map =
  let map = Array.create ~len:1024 (0, 0) in
  let y = ref 0 in
  let acc = ref 0 in
  for sy = 0 to 199 do
    acc := !acc + 96;
    let i = ref 0 in
    while !acc >= 25 do
      acc := !acc - 25;
      map.(!y) <- sy, ((2 * sy) + (!i land 1)) land 63;
      y := !y + 1;
      i := !i + 1
    done
  done;
  assert (!y = 768);
  map
;;

let row_map_image =
  Array.init 1024 ~f:(fun y ->
    let sy, thr_row = row_map.(y) in
    Bits.of_unsigned_int ~width:14 ((sy lsl 6) lor thr_row))
;;

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
    ; mode : 'a [@bits 1]
    }
  [@@deriving hardcaml]
end

let create (i : _ I.t) : _ O.t =
  let spec = Reg_spec.create () ~clock:i.clock in
  (* ── write side: window decode ── [base] is 64 KiB-aligned, so the compare is the
     full top byte of the 24-bit address — all of himem outside [base, base+64K) is
     excluded exactly (Framebuf's wide-compare lesson, for free here) *)
  let in_window = select i.adr ~high:23 ~low:16 ==:. base lsr 16 in
  let off = select i.adr ~high:15 ~low:0 in
  let page = select off ~high:15 ~low:8 in
  let is_lut = page ==:. lut_off lsr 8 in
  let is_ctl = page ==:. ctl_off lsr 8 in
  let lane = select i.adr ~high:1 ~low:0 in
  let wr_win = i.write &: in_window in
  let mode = reg spec ~enable:(wr_win &: is_ctl) (lsb i.wdata) -- "ixb_mode" in
  (* ── FSM state ── *)
  let cnt = Always.Variable.reg spec ~width:4 in
  let col = Always.Variable.reg spec ~width:5 in
  let par = Always.Variable.reg spec ~width:1 in
  let acc = Always.Variable.reg spec ~width:32 in
  let jd = Always.Variable.reg spec ~width:4 in
  let lane_d = Always.Variable.reg spec ~width:2 in
  let vd = Always.Variable.reg spec ~width:1 in
  (* probe naming for the DOOM repo's doom_sim frame capture: ixb_ack + ixb_word (below)
     and ixb_col are in the viddata cone, so Cyclesim's DCE keeps them; the completed
     request's ROW is tracked by the harness off the soc-level vidreq/vidadr wires — a row
     register HERE would be dead datapath since the sync row-map rework, and DCE prunes
     dead named nodes (the pruned-ixb_row lesson, a 10c-DCE sibling) *)
  let col_v = col.value -- "ixb_col" in
  let word_off = select (i.vidadr -:. Risc5.Video.org) ~high:14 ~low:0 in
  (* the row map, SYNC read (timing: the first bitstream carried both constant ROMs as
     async LUT mux trees — ~1.2k LUTs of congestion that squeezed the icache/regfile paths
     to WNS +0.003; registered array reads cut the paths and give Vivado the
     initialized-array shape it can place as BRAM). The address is the SCREEN ROW OF THE
     INCOMING REQUEST — ~(vidadr - org)[14:5], computed from the module inputs — read as
     the request is accepted, so [{sy, thr_row}] are registered and valid from cycle 1 on:
     latency unchanged. *)
  let y_req = ~:(select word_off ~high:14 ~low:5) in
  let accept = cnt.value ==:. 0 &: i.vidreq in
  let rm_read =
    (multiport_memory
       1024
       ~name:"ixb_rowmap"
       ~initialize_to:row_map_image
       ~write_ports:
         [| { Write_port.write_clock = i.clock
            ; write_address = zero 10
            ; write_enable = gnd
            ; write_data = zero 14
            }
         |]
       ~read_addresses:[| y_req |]).(0)
  in
  let rm = reg spec ~enable:accept rm_read in
  let sy = select rm ~high:13 ~low:6 in
  let thr_row = select rm ~high:5 ~low:0 in
  let sy16 = uresize sy ~width:16 in
  let col16 = uresize col_v ~width:16 in
  let src_base = sll sy16 ~by:8 +: sll sy16 ~by:6 +: sll col16 ~by:3 +: sll col16 ~by:1 in
  let issue = cnt.value >=:. 1 &: (cnt.value <=:. 10) in
  let j = cnt.value -:. 1 in
  let src_addr = src_base +: uresize j ~width:16 in
  (* ── the pixel shadow: four byte-lane 16384x8 sync-read BRAMs (the Framebuf /
     lib/ram.ml idiom). LUT/CTL-page stores also land here (word indices 16000..16383) —
     harmless: the FSM's max read is word 15999 (sy < 200). *)
  let rd_idx = select src_addr ~high:15 ~low:2 in
  let pix_lane k =
    (Ram.create
       ~name:(Printf.sprintf "ixb_pix%d" k)
       ~collision_mode:Read_before_write
       ~size:(size / 4)
       ~write_ports:
         [| { Write_port.write_clock = i.clock
            ; write_address = select i.adr ~high:15 ~low:2
            ; write_enable = wr_win &: (~:(i.ben) |: (lane ==:. k))
            ; write_data = select i.wdata ~high:((8 * k) + 7) ~low:(8 * k)
            }
         |]
       ~read_ports:
         [| { Read_port.read_clock = i.clock; read_address = rd_idx; read_enable = issue }
         |]
       ()).(0)
  in
  let byte = mux lane_d.value [ pix_lane 0; pix_lane 1; pix_lane 2; pix_lane 3 ] in
  (* ── the luminance LUT: four byte-lane 64x8 async-read LUTRAMs (the register-file idiom
     — async keeps the compute stage one cycle: byte -> lum -> compares) *)
  let lut_lane k =
    (multiport_memory
       64
       ~name:(Printf.sprintf "ixb_lut%d" k)
       ~write_ports:
         [| { Write_port.write_clock = i.clock
            ; write_address = select off ~high:7 ~low:2
            ; write_enable = wr_win &: is_lut &: (~:(i.ben) |: (lane ==:. k))
            ; write_data = select i.wdata ~high:((8 * k) + 7) ~low:(8 * k)
            }
         |]
       ~read_addresses:[| select byte ~high:7 ~low:2 |]).(0)
  in
  let lum =
    mux (select byte ~high:1 ~low:0) [ lut_lane 0; lut_lane 1; lut_lane 2; lut_lane 3 ]
  in
  (* ── the slot thresholds — a CPU-WRITTEN RAM, not a ROM: the hardware ships
     content-free, every client uploads its 2048 quads (see [slot_quad]) at the [thr_base]
     window before mode-on (DOOM its blue noise, Mandel its Bayer). Four byte-lane
     sync-read BRAMs (the pixel-shadow idiom); addressed with the ISSUE stage's j (not
     jd), so the sync read lands exactly when the compute stage (jd) needs it — the same
     pairing as the pixel BRAM read ── *)
  let in_thr = select i.adr ~high:23 ~low:13 ==:. thr_base lsr 13 in
  let wr_thr = i.write &: in_thr in
  let thr_addr = concat_msb [ thr_row; lsb col_v; select j ~high:3 ~low:0 ] in
  let thr_lane k =
    (Ram.create
       ~name:(Printf.sprintf "ixb_thr%d" k)
       ~collision_mode:Read_before_write
       ~size:(thr_size / 4)
       ~write_ports:
         [| { Write_port.write_clock = i.clock
            ; write_address = select i.adr ~high:12 ~low:2
            ; write_enable = wr_thr &: (~:(i.ben) |: (lane ==:. k))
            ; write_data = select i.wdata ~high:((8 * k) + 7) ~low:(8 * k)
            }
         |]
       ~read_ports:
         [| { Read_port.read_clock = i.clock
            ; read_address = thr_addr
            ; read_enable = issue
            }
         |]
       ()).(0)
  in
  let cuts = concat_msb [ thr_lane 3; thr_lane 2; thr_lane 1; thr_lane 0 ] in
  let bit k = lum >: select cuts ~high:((8 * k) + 7) ~low:(8 * k) in
  let nib = concat_msb [ bit 3; bit 2; bit 1; bit 0 ] in
  let xoff_sig =
    mux jd.value (List.map ~f:(fun v -> of_unsigned_int ~width:5 v) (Array.to_list xoff))
  in
  let shifted = log_shift ~f:sll (uresize nib ~width:32) ~by:xoff_sig in
  Always.(
    compile
      [ vd <-- gnd
      ; if_
          (cnt.value ==:. 0)
          [ when_
              i.vidreq
              [ col <-- select word_off ~high:4 ~low:0
              ; par <-- lsb i.vidadr
              ; acc <-- zero 32
              ; cnt <-- of_unsigned_int ~width:4 1
              ]
          ]
          [ cnt <-- mux2 (cnt.value ==:. 12) (zero 4) (cnt.value +:. 1)
          ; when_
              issue
              [ jd <-- j; lane_d <-- select src_addr ~high:1 ~low:0; vd <-- vdd ]
          ; when_ vd.value [ acc <-- (acc.value |: shifted) ]
          ]
      ]);
  let vid_ack = (cnt.value ==:. 12) -- "ixb_ack" in
  let viddata = acc.value -- "ixb_word" in
  { O.viddata; vid_ack; vidpar = par.value; mode }
;;

(* ── Tests (co-located; AGENT.md §6) ─────────────────────────────────────────

   Rung 1 — model ≡ the shipped C kernel. The expect constant below is the output of gcc
   -m32 -O2 -funsigned-char on a driver that #includes the DOOM repo's libc/dither.c
   verbatim (same-TU access to its static __dg_lum), fills src[64000] then __dg_lum[256]
   from the LCG s := s*1664525 + 1013904223 (seed 12345, byte = (s >> 16) & 0xFF), runs
   __dg_dither_fs(src, fb + 767*32, -32) — the machine geometry — and FNV-1a-64-hashes the
   frame in (y asc, col asc) word order, 4 LE bytes per word. Any drift in row_map / the
   threshold table / slot packing / the compare direction moves the hash. *)

(* the slot-quad packing a CLIENT derives from its 64x64 threshold map and uploads at
   [thr_base + 4a], a = [{row[6], phase[1], slot[4]}]: the slot's 3-or-4 thresholds one
   byte each (LSB = leftmost output bit), K=3 slots padded with 255 (a compare an 8-bit
   luminance can never win). The software contract's other half — the DOOM blob's
   __dg_upload_thresholds and Mandel.Mod's Upload both implement exactly this. *)
let slot_quad ~thr a =
  let thr_row = a lsr 5
  and phase = (a lsr 4) land 1
  and j = a land 15 in
  if j > 9
  then 0
  else (
    let cut k =
      if k < xw.(j) then thr.((thr_row * 64) + (32 * phase) + xoff.(j) + k) else 255
    in
    cut 0 lor (cut 1 lsl 8) lor (cut 2 lsl 16) lor (cut 3 lsl 24))
;;

(* the reference model: one composed fb word for screen row [y], word column [col], over a
   64000-byte [pixels] image, a 256-byte [lut] and a 4096-byte 64x64 threshold map [thr] —
   dither.c's decision function verbatim (the hash test below pins the equivalence) *)
let reference_word ~thr ~pixels ~lut ~y ~col =
  let sy, thr_row = row_map.(y) in
  let sbase = (sy * 320) + (col * 10) in
  let w = ref 0 in
  for j = 0 to 9 do
    let lum = lut.(pixels.(sbase + j)) in
    for k = 0 to xw.(j) - 1 do
      if lum > thr.((thr_row * 64) + (32 * (col land 1)) + xoff.(j) + k)
      then w := !w lor (1 lsl (xoff.(j) + k))
    done
  done;
  !w
;;

(* The DOOM blue-noise table — TEST-ORACLE DATA ONLY, deliberately unexported (the mli
   seals it: nothing in the design can reference one client's content). Verbatim from the
   DOOM repo's libc/dither.c [__dg_bn64] (bin/bluenoise.ml default output, sigma 1.5,
   values 1..254); the hash test pins model ≡ the gcc-compiled C kernel, and the
   differential uses it as the first uploaded table. *)
let bn64 =
  [|  15;  85;  28;  49; 151; 221;  66; 206;   6; 197; 223; 137;  97; 215;  61;  33;
     186; 102;  26; 218;  18; 180;  62;  31; 130;  94;  43; 185;  71;  47;  95; 152;
      64;  27;  77; 204; 135; 253; 189; 124; 150; 198;  76; 221;  97; 235;  39; 130;
      28;  74; 176; 205;  91; 184; 143;  26; 189;   8; 209;  81; 230;  63;  32; 216;
     149; 186; 126; 233; 108; 175;  37; 123;  90;  49; 173;  18; 235; 166; 114;  83;
     158; 230; 141; 189;  76; 132; 225; 112; 212; 178;   3; 117; 250; 199; 171;   9;
     215; 145; 180; 113;  32; 163;  12;  87; 232;  23; 136;   5; 117;  57; 171; 228;
     158;  48; 248; 139;  39; 241;  57; 212;  95; 247; 153;  27; 172; 105; 240; 121;
      98; 225;  72; 198;  17;  79; 239; 149; 184; 244; 104; 128;  77;  40; 201; 237;
       8;  69;  47;  97; 250;  43; 155;  14;  82;  52; 224; 142;  31;  82; 127; 240;
     103;  52; 231;  89; 220;  65; 213; 173;  50; 108; 182; 250; 152; 190;  19;  85;
     203; 122;  13; 105; 164;   1; 122; 160;  35; 115;  56; 201; 131;  10; 161;  44;
      61;   4; 158;  43; 134; 211; 101;  13;  73;  31; 157;  57; 192; 147;  22; 135;
     175; 123; 207; 168;   4; 198;  91; 187; 241; 160;  66;  99; 164; 216;  57;  25;
     187; 132;  11;  44; 149; 127; 100;  30; 141; 224;  90;  64;  37; 215; 106; 144;
      60; 233; 183;  77; 222; 197;  88; 231;  72; 140; 184;  89; 219;  73; 189; 210;
     242; 179; 103; 247; 185;  59; 166; 229; 132; 201; 219;   1; 242;  94; 221;  52;
      89; 241;  34; 146; 113; 232;  67; 138;  33; 114; 191; 237;  10; 183; 111; 156;
      75; 205; 164; 237; 190;  18; 243; 195;  73; 206;  14; 168; 129;  78; 242;  10;
     165;  95;  26; 152;  42;  63; 177;  18; 207; 237;   6;  41; 253; 111;  29; 136;
     115;  33; 143;  82;   9; 121;  35; 192;  54; 112;  81; 170; 120;  67; 181; 112;
     195;  17;  77; 218;  57;  25; 172;  99; 203;  17; 148;  44;  77; 137; 229;  41;
     251;  98;  60; 117;  79; 167;  55; 120; 157;  42; 112; 230; 200;  27; 178; 116;
      45; 190; 214; 118; 251; 137; 106; 150;  47;  98; 166; 123; 154;  55; 171;  83;
     221; 200;  64; 216; 160; 237;  87; 150;  23; 253; 144;  35; 214;  15; 154;  37;
     225; 140; 106; 186; 160; 125; 213;  49; 253;  80; 220; 128; 202;  21;  90; 197;
       6; 129;  24; 210;  36;  96; 221;  12; 184; 246; 147;  51;  96; 155;  68; 209;
     237; 133;  58;  83;  13; 205;  33; 193; 119; 181;  67; 212;  18; 197; 231;  15;
      53; 167; 123;  27;  99; 198;  67; 222;  97; 181;  49; 105; 188; 130; 245;  80;
     167;  58; 250;  40;  86; 238;   8; 110; 151; 177;  57; 101; 246; 165;  63; 144;
     173; 223; 186; 148; 248; 133; 199;  71; 101;  28;  79; 193;   2; 252; 138;  32;
      87;   5; 156; 230; 172;  94; 241;  76; 224;  21; 244;  92; 134;  72; 106; 150;
      88;  11; 251; 183;  45; 137;  17; 170; 127;   8; 200; 237;  61;  27;  99; 202;
       4; 123; 157;  15; 197; 143;  71; 192;  30; 121;   1; 187;  30; 119; 225; 103;
      52;  82; 106;  65;   2; 175;  41; 152; 225; 137; 174; 115; 213;  58; 106; 188;
     168; 110; 195;  39; 130;  56; 158;   4; 133;  55; 148;  35; 176; 240;  40; 185;
     229; 104; 147;  78; 220; 108; 241;  55; 211;  75; 152;  87; 162; 218; 139;  48;
     177; 212;  69; 228; 105;  50; 217; 167;  90; 212; 235; 153;  75;  43; 183;  16;
     243;  31; 163; 230; 124;  87; 239; 114;   8;  60; 238;  40; 133; 164;  17; 231;
      52; 244;  73; 212;  17; 187; 115; 208; 174;  87; 195; 222; 113;   2; 207; 126;
      21; 204;  56; 169;   4; 196; 156;  29; 104; 233;  32; 122;  11; 179;  73; 232;
     114;  92;  33; 132; 179;  24; 124; 241;  43;  69; 135;  97; 229; 206; 128; 157;
     210; 138; 190;  47; 205;  26;  63; 189; 161; 208;  89;  19; 228;  69; 206;  84;
     139;  24; 124;  96; 150; 226;  71;  44; 236; 109;  24;  65; 166;  84; 142;  64;
     188; 118;  35; 243; 122;  61;  88; 188; 131; 172;  58; 204; 249; 102;  35; 152;
      19; 223; 193;  82; 247; 154;  98;   9; 160; 202;  20;  52; 168;   8;  90;  55;
      77; 118;  12;  95; 149; 171; 219;  94;  44; 125; 186; 153; 103; 176; 119;  38;
     158; 222; 178;  61; 250;  29; 102; 144;  13; 157; 251; 131; 211;  44; 246; 164;
      86; 234; 141;  94; 206; 145;  41; 250;   6; 216;  93; 146;  43; 131; 192; 241;
      63; 169; 145;   6;  54; 204;  68; 224; 130; 108; 246; 194; 142; 113; 250; 189;
      36; 235; 214;  68; 253; 110;  13; 140; 242;  24;  70; 249;  50;  10; 224; 190;
     100;   7; 201;  43; 170; 126; 202; 222;  79; 187;  48;  94;  12; 182; 104;  28;
     154;  10;  70; 179;  18; 227; 171; 117;  73; 157;  19; 184;  81; 214;   2;  87;
     125;  44; 108; 230; 172; 116;  30; 190;  49; 177;  85;  34;  65; 213;  23; 135;
     167; 104; 176;  29; 132;  53; 197;  78; 170; 212; 108; 142; 200;  86; 134;  59;
     248;  79; 114; 143;  87;  10;  60; 178;  32; 114; 202; 146; 230; 121;  56; 215;
      42; 198; 221;  51; 109;  79;  26; 209;  52; 237; 112; 226;  66; 160; 110; 176;
     219; 197;  78;  35; 136;  84; 244; 143;  75;  13; 154; 224; 101; 172;  81; 232;
      60;   3; 144; 199;  84; 163; 228;  31; 118;  56;   3; 180;  34; 236; 167;  23;
     149; 208;  33; 240; 186; 228; 156;  96; 136; 233;  66;  20; 163;  76; 239; 133;
     113;  89; 166; 126; 240; 195; 132;  96; 142; 188;  39; 134;  24; 247;  53;  30;
     141;  11; 251; 182; 215;  14; 166; 104; 206; 236; 116; 184;   5; 146;  47; 202;
     124;  93; 244;  45; 218;   7;  98; 147; 191; 231;  93; 216; 124;  69; 110; 185;
      50; 121; 163;  66;  21; 109;  44; 240;   3; 169;  91; 208;  41; 190;   5; 175;
      66; 253;  29; 148;   1;  47; 160; 245;  11;  82; 167; 101; 202; 144; 187; 234;
      65;  95; 155;  51; 122;  63; 225;  44;  24; 137;  62;  41; 247; 119; 223;  17;
     161; 189;  71; 115; 180; 127; 246;  43;  72; 132; 167;  49; 153;  14; 218;  91;
     238;   1; 221;  93; 200; 130; 208;  74; 185;  53; 128; 223; 109; 140;  96; 212;
      17; 192;  57; 100; 211; 182;  69;  35; 200; 220;  60; 231;   7;  75;  98; 124;
     169; 211; 111;  24; 200;  93; 151; 184;  81; 170; 215;  91; 199;  67; 181;  87;
      42; 230;  28; 154;  20;  61; 197; 160;  11; 239;  26;  79; 252; 173;  38; 198;
     136;  75; 178; 141;  53; 172;  30; 148; 116; 247;  29; 153;  61; 242;  34; 157;
     137; 115; 171; 234;  80; 118; 226; 102; 125; 147;  28; 119; 174;  45; 216;  15;
      40;  80; 230; 174; 138; 237;   2; 126; 254; 107;  11; 155; 132;  22; 110; 150;
     208; 133; 101; 206; 236;  82; 112; 215;  96; 179; 116; 201; 137;  87; 119;  62;
     159;  29; 106; 231;  11; 250;  88; 218;  15; 199;  85; 179;  18; 198;  82; 228;
      73; 221;  38; 154;  25; 141;  14; 168;  50; 181;  88; 242; 155; 194; 136; 246;
     182; 146;   7;  58;  83;  36; 208;  67; 196;  51; 231;  36; 171; 226;  50; 241;
      10;  62; 167;  46; 130; 174;  27;  53; 140;  39; 220;  59;   5; 189; 224;  16;
     247; 211;  44; 191;  69; 120; 162;  58; 105; 143;  42; 234; 103; 167; 124;  46;
     204;   7;  92; 200;  62; 237; 193;  78; 249;   5; 207;  67; 104;  20;  84; 110;
      63; 201; 127; 249; 189; 114; 162; 101;  26; 146; 120; 204;  75;  98; 190; 126;
      83; 181; 252;  90;   1; 223; 153; 249; 186;  81; 159; 103; 242;  47; 145; 180;
     114;  86; 130; 155;  93; 214;  39; 236; 190;  72; 219; 121;  65;   3; 247; 179;
     108; 144; 249; 127; 178; 100;  44; 153; 216; 114; 139;  34; 220;  55; 233; 161;
      17; 222; 103;  28; 144; 214;  48; 242; 175;  80; 185;  56; 248;   3; 159;  34;
     220; 110;  25; 145; 186;  70;  94; 119;  12; 230;  22; 124; 169;  77; 101;  36;
      66; 201;   6; 243;  25; 183; 144;   4; 128; 173;  19; 155; 207; 139;  91;  29;
      60; 173;  76;  46;  20; 210; 132;  23;  92;  57; 197; 175; 123; 148; 203;  39;
     177;  88;  49; 170;  72;  15;  88; 127;   9; 233; 104;  21; 143; 117; 207;  70;
     150; 199;  53; 231; 116; 210;  34; 199;  67; 134; 194; 212;  28; 234; 198; 162;
     231; 138;  54; 168; 109;  64; 206; 100;  50; 252;  92;  36; 183;  48; 221; 154;
     240;  15; 219; 111; 166; 243;  69; 185; 234; 164;  18;  82; 253;   1;  74; 115;
     139; 244; 196; 122; 232; 177; 221; 155; 200;  44; 163; 219;  86; 178;  46; 245;
      11; 131;  81; 162;  16;  57; 141; 238; 157; 100;  37;  89;  61; 137;   9; 121;
      22; 178; 214;  80; 235; 135;  33; 232; 157;  68; 211; 109; 239;  73; 118; 189;
      43; 128; 195; 147;  86;   3; 113; 148;  35; 104; 209;  48; 158;  97; 229; 189;
      24;  68;  10; 148;  35; 105;  60;  27; 111;  72; 133; 195;  33; 235; 107; 170;
      95; 224;  39; 194; 248;  99; 171;   5;  50; 178; 247; 148; 185; 217;  93; 251;
      73; 101;  39; 123;  14; 176;  86; 193; 120;   9; 170; 136;  13; 161;  23;  86;
     209;  96;  58;  27; 227; 200;  50; 213;  76; 138; 237; 120; 184;  31; 135;  53;
     158; 233; 110; 209;  80; 245; 192; 143; 211; 249;   6;  63; 153;  76;  17; 139;
      62; 180; 107; 143;  70; 126; 221;  82; 213; 122;  70;  15; 111;  38; 159;  52;
     191; 150; 227; 200; 154;  51; 216;  24;  75; 224;  47; 191;  83; 201; 232; 140;
       6; 163; 234; 183;  68; 122; 157; 250;   9; 190;  58;  13; 219;  70; 199; 105;
     215;  84; 180;  51; 159;   3; 123;  49;  85; 176; 101; 232; 124; 183; 222; 200;
      34; 242;   9; 212;  24; 187;  41; 111; 193;  22; 223; 162; 238;  80; 126; 210;
      30; 112;   5;  65;  95; 249; 107; 145; 185; 130;  97; 248;  32; 125;  50; 176;
     252; 113;  38; 137; 102; 175;  23;  94; 129; 167;  87; 148; 109; 172; 243;   6;
      42; 125;  27; 135; 226;  94; 183; 222;  16; 156;  40; 203;  20;  52; 113;  88;
     163; 127;  84; 156;  54; 164; 230;  28; 151;  91; 132;  56; 203;   1; 175; 234;
      88; 170; 243; 138; 183;  18; 165;  40; 239;  16; 167;  65; 152; 217; 107;  68;
     149;  79; 216;  14; 244;  43; 196;  64; 216;  42; 202; 247;  23;  45;  88; 147;
     169; 201; 251;  70; 196;  40; 165;  69; 111; 229; 140;  80; 165; 252; 149;   4;
     208;  49; 226; 114; 245;  95; 131;  75; 252; 173;  43; 187; 100; 141;  67;  21;
     147;  47; 197;  33;  81; 209; 122;  66;  89; 198; 111; 227;   2;  91; 188;  20;
     128; 198;  50; 153;  87; 220; 147; 108; 240;  16; 121;  65; 159; 194; 132; 233;
      59;  96;  10; 153; 115;  19; 241; 130;  30; 188;  57; 117; 212;  97;  39; 235;
      72; 181;  18; 192;  71;   2; 178; 205;  61;   8; 234; 118;  31; 249; 205; 118;
     226;  71; 128; 107; 232;  53; 175; 228; 153;  32;  53; 138; 207;  42; 162; 221;
      28;  93; 168; 209;  62; 128;   5; 171;  80; 139; 186; 100; 223; 116;  75;  18;
     217; 120; 184;  83; 233;  61; 144; 205;  97; 245;  11; 172;  25;  66; 194; 121;
     159;  98; 134;  38; 146; 218;  45; 115; 143;  95; 211; 152;  81; 164;  52;  97;
     182;   8; 213; 160;  15; 143;  98;   7; 211; 129; 244; 175;  72; 118; 235;  59;
     181; 245;   7; 110; 183;  32; 236;  54; 208;  31; 232;  49;   2; 205;  38; 177;
     155;  33; 207;  47; 172; 214;  85;  45; 159;  74; 217; 133; 238; 109; 145;  14;
     219;  57; 242; 203; 169; 102; 240;  27; 194; 168;  22;  64; 227;  11; 193;  33;
     156; 246;  92;  60; 190; 253;  38; 185; 108;  77;  15;  98; 192;  19; 144; 103;
      46; 125;  71; 142; 227;  96; 193; 119; 151;  94; 163; 180;  83; 150; 235; 107;
      64; 246; 138; 105;  16; 125; 190;   1; 182; 124;  35;  88; 186;  48; 229;  84;
     176;  26; 111;  78;  19;  57; 136;  83; 229;  54; 127; 181; 108; 137; 219; 120;
      77; 138;  41; 168; 117;  77; 134;  62; 239; 169; 205; 150;  38; 250;  78; 210;
     156; 195; 217;  22;  48; 157;  77;  17; 244;  68;  20; 124; 252;  56; 135;  87;
     191;   5;  78; 223; 161;  36; 252; 114; 224;  61; 204; 154;   5; 166; 205;  36;
     131; 196; 151; 223; 126; 182; 211; 157;  10; 104; 217;  36; 241;  89;  56; 174;
     229;  23; 199; 237;  20; 219; 203; 156;  26;  46; 119;  65; 214; 125; 173;  13;
     109;  34;  90; 175; 251; 130; 216;  41; 184; 133; 221; 103; 200;  12; 184;  27;
     227; 117; 151;  58; 194;  95;  69; 146;  24;  99; 139; 249;  78; 102; 122;  67;
     245;  91;  49;  12; 251;  96;  29;  68; 244; 145; 191;  74; 151;  28; 199;   3;
     101;  65; 111; 148;  51; 103;   2;  93; 217; 139; 231;   8; 165;  92;  54; 232;
      76; 241; 147; 116;  64;   4; 169; 109; 207;  55; 174;  39;  71; 160; 114; 209;
      52; 169; 239;  22; 128; 231; 173;  47; 236; 180;  16;  54; 191;  22; 234; 156;
       8; 173; 213;  73; 164;  43; 201; 121; 176;  45;  92;   7; 209; 166; 130; 244;
     156; 216; 184;  83; 228; 179; 126; 194;  74; 176; 106;  81; 241;  29; 196; 138;
     186;  57;  17; 209; 193; 101; 233;  82; 144;   8;  91; 238; 142; 225;  37;  99;
     140;  81;  39; 202;  84;   7; 209; 107; 155;  81; 219; 117; 212; 135; 182;  46;
     220; 105; 135; 191; 109; 143; 236;  82;  17; 224; 135; 253; 115;  62;  80;  34;
     122;  47;  12; 131;  31; 159;  60;  39; 250;  20;  54; 192; 152; 116; 219;   1;
     126; 226; 165;  81;  36; 156;  52;  26; 248; 166; 118; 187;  16;  84; 173; 246;
       7; 214; 183; 106; 142; 166;  64;  27; 199; 130;  41; 169;  66;  30;  97;  75;
     147;  22;  62;  32; 228;   3;  56; 189; 163; 110;  59; 174;  41; 233; 181; 204;
      92; 170; 249; 194;  70; 240; 210; 146; 116; 161; 225; 135;  40;  70; 168;  97;
     155;  31; 111; 245; 136; 218; 184; 129; 197;  63;  32; 208;  60; 121; 195;  55;
     155; 125;  59; 249;  31; 222; 117; 241;  72;   4; 247;  87; 227; 158; 204; 252;
     117; 196; 240; 171;  78; 157; 129;  98; 214;  23; 152; 202;  14; 102; 140;  21;
     222;  62; 146;  88; 119;  14;  99;  25;  84; 204;   5;  91; 210;  19; 252;  45;
     215;  68; 191;   6;  60;  89;  13; 108;  76; 225; 154;  99; 244; 138;  19;  79;
     233;  96;  20; 158;  75; 179;  45; 140; 163; 185; 106; 146;  15; 112;  54;   4;
     163;  40;  93; 121; 217; 199;  29; 245;  44;  74; 238;  87; 127; 219;  49; 157;
     115;   7; 230;  37; 206; 140; 174; 227; 189;  61; 127; 241; 178; 105; 196;  83;
     180; 140; 229;  99; 177; 237; 150; 206;  41; 135;   1; 180;  46; 217; 163; 203;
      35; 181; 227; 132; 204; 100;  13; 217;  90;  54; 208;  37; 174; 238; 138; 186;
      79; 213; 151;  10;  49; 106;  69; 175; 145; 121; 187;  38; 171;  72; 191; 246;
      78; 186; 103; 166;  55; 236;  74;  45; 152;  31; 170;  75;  48; 150; 132;   9;
     114;  48;  22; 156; 126;  31;  54; 229; 165;  86; 235; 118;  74;  25;  92; 113;
     147;  70; 109;   2;  52; 243; 124; 195;  29; 234; 133;  78; 194;  65;  99;  33;
     235; 131;  64; 246; 187; 139; 227;   8; 204;  94;  19; 223; 151;   1;  97;  31;
     135; 217;  26; 126; 191;   3; 112; 134; 248; 102; 223; 119;  21; 236;  62; 224;
     166;  87; 206; 249;  74; 196;  97; 120;  16; 189;  36; 207; 149; 174; 226;   9;
     251;  43; 215; 189; 165;  84; 150;  62; 112; 158;  10; 220; 119;  18; 215; 169;
     110;  18; 205;  88; 161;  24;  82; 164;  47; 250; 137;  61; 108; 232; 205; 177;
      51; 154;  68; 251;  86; 149; 217;  21;  83; 206;   9; 191; 164; 207;  97;  29;
     194; 136;  63; 111;   8; 221; 173;  65; 253; 145; 108;  60; 245; 130;  52; 188;
     123; 161;  89; 137;  34; 226;  21; 180; 253;  42; 101; 165;  51; 248; 152;  73;
     197;  54; 176; 117;  43; 237; 128; 218; 113;  73; 176; 199;  42; 132;  66; 117;
     238;  11;  99; 205;  42; 177;  63; 194; 158;  54; 142;  95;  71;  40; 128; 246;
       3; 218;  36; 185; 159;  46; 142;  22; 199;  78; 178;   8;  99;  30;  86; 213;
      66;  23; 229;  61; 114; 200;  72; 136; 202;  84; 228; 188; 141;  91;  40; 129;
      26; 228; 140;  12; 209; 103;  57; 192;  30; 156;   9;  88; 242; 161;  15;  85;
     169; 214; 129; 162;  24; 105; 243; 121;  37; 178; 241;  28; 227; 149; 183;  76;
     120; 154;  96; 241; 128;  86; 235; 102; 125;  47; 218; 159; 196; 230; 167; 145;
     102; 175; 197;  11; 248; 170; 105;   6;  56; 128;  25;  70;   1; 206; 179; 239;
     104; 162;  65; 252;  76; 177;   2; 141;  96; 238; 215; 122;  32; 187; 225; 145;
      37;  58; 186;  77; 226; 137;  12;  85; 225;  68; 112; 133; 201;  12; 104;  51;
     172; 227;  19;  58; 211;  15; 179; 206;  30; 237; 133;  25; 114;  74;  45;   5;
     244;  40; 126; 148;  91;  46; 216; 160; 238; 176; 213; 109; 236; 123;  79;  14;
     211;  85;  32; 193; 131; 155; 232; 203;  68; 182;  48; 148;  64; 102;  23; 200;
     110; 246;   4; 116;  45; 196; 163; 207; 141;   1; 193;  86;  58; 162; 239; 205;
      37;  72; 140; 181; 113;  76;  42; 153;  69; 172;  92;  55; 242; 138; 220; 192;
     115;  82; 232;  70; 187;  28; 142;  76;  34;  93; 152;  50; 172;  34; 159;  59;
     185; 146; 223; 105;  49;  23;  85;  41; 125;  16; 106; 204; 171; 252; 129;  70;
     174;  88; 215; 147; 235;  92;  59;  32; 103; 253; 169;  42; 231; 116;  25;  90;
     251; 109; 197;  33; 162; 246; 139; 224; 117;   7; 205; 148; 182;  18;  94;  63;
     173; 208;  26; 164; 222; 123; 244; 193; 118; 226;  16; 134; 195;  98; 245; 132;
      43; 117;   6; 170; 238; 119; 214; 159; 249; 143;  74; 232;   3;  91;  46; 210;
     137;  28; 160;  67;  21; 127; 180; 222;  74; 153;  20; 213; 139;  69; 188; 146;
     125;   9; 233;  92; 214;   2; 100;  57; 185; 248;  73; 107;  38; 209; 129; 157;
      13; 139;  55; 109;   3;  64; 100;  12;  58; 184;  81; 211;  64;   8; 216;  83;
     231; 191;  69;  90; 201;  60; 184; 100;  30; 196; 165;  37; 134; 220; 160;  12;
     239;  54; 195; 106; 170; 248;   7; 112; 190;  53; 122;  93; 178;   5; 218;  49;
     210; 164;  65; 149;  48; 127; 202;  25;  90; 158;  21; 230; 165;  83; 252;  49;
     225;  97; 245; 191; 136; 176; 206; 162; 233; 128;  38; 243; 155; 120; 174;  20;
     149;  31; 247; 134;  21; 142;  11;  77; 223;  55; 119;  85; 192;  62; 108; 183;
      95; 123; 226;  37; 210;  79; 149;  38; 137; 236; 206;  34; 244; 105; 155;  83;
     183; 102;  20; 191;  80; 235; 174; 144; 216;  50; 134; 189;  60;   1; 113; 198;
      29; 175;  71;  37; 230;  85;  48;  25; 145;  90; 174; 106;  30; 203;  71; 110;
     208;  94; 162;  45; 222; 168; 243; 115; 175;   6; 240; 215;  18; 147; 228;  32;
      68; 173;   6; 141;  99;  53; 198; 227;  89;  10; 165;  80;  56; 130; 233;  27;
      42; 247; 133; 225; 107;  17;  63; 115;  36; 238;  95; 118; 223; 149; 182;  66;
     126; 148; 212; 118;  19; 152; 248; 110; 210;  67;   3; 224;  55; 145; 251;  44;
     180;  61; 124; 198; 107;  84;  34; 209; 151;  71; 141; 103; 167;  44; 126; 202;
     250; 150;  85; 236; 186;  14; 162; 121;  66; 181; 110; 147; 200;  14; 171;  72;
     148; 203;  56; 172;  38; 159; 252; 198;  81; 162; 203;  16;  45;  89; 210; 102;
     239;  10;  87; 168; 219;  57; 131; 179;  40; 238; 195; 134; 170;  94;  14; 129;
     216;   2; 229;  27;  67; 188; 131;  50;  95; 199;  40; 182;  66; 243;  80;  15;
     104;  46; 214;  63; 132; 108; 243;  25; 213;  44; 250;  24; 228; 100; 193; 120;
      96;  25;  85; 119; 217; 131;  95;   4; 179;  28;  67; 145; 248; 170;  21;  40;
     163;  59; 194;  45; 102; 197;  78;  13; 100; 153; 113;  26;  74; 185; 226; 157;
      79; 103; 173; 150; 252;   7; 165; 224;  15; 248; 127;  22; 208;  99; 195; 169;
     131; 188;  22; 167;  36; 204;  72; 144;  98; 190; 134;  75; 161;  39;  60; 239;
     158; 229; 182;  10;  73; 190;  51; 229; 141; 104; 218; 185; 127;  75; 234; 136;
     217; 116; 251; 143;   5; 237; 160; 216; 188;  51;  81; 212; 240;  47; 111;  28;
     196; 238;  36;  89; 136; 212; 113;  65; 154; 107;  76; 231; 138;   1; 153;  33;
     234;  69; 115; 246;  93; 178;  49; 229; 166;   2;  58; 113; 220; 140; 207;   4;
     129;  51; 201; 139; 243;  29; 152;  70; 119; 243;  50;  92;  11; 112;  54; 179;
      91;  25;  73; 177; 124;  37;  62; 120;  23; 253; 166; 124;   6; 146; 207;  69;
     142;  56; 118; 203;  52;  80;  37; 235; 180;  29; 192; 164;  59; 119; 218;  53;
      94; 212; 158;   4; 135; 220;  16; 123;  81; 240; 203; 173;  18;  89; 181;  74;
     172; 107;  33;  90; 164; 111; 221; 202;  13; 158;  30; 213; 167; 227; 195;   4;
     154; 201;  42; 221;  86; 190; 146; 227;  90; 141;  32; 192;  61; 177;  92; 249;
       9; 189; 160;  14; 240; 168; 194;  90; 135;  53; 222;  93;  35; 242;  77; 182;
     142;  26; 193;  83;  59; 154; 101; 193;  33; 139;  96;  48; 233; 125;  35; 253;
      17; 210; 239;  64; 187;  48;  21;  99; 178;  82; 197; 135;  67;  38; 129;  77;
     244; 134; 106; 163;  19; 246; 104;   8; 181;  70; 222;  98; 231; 120;  30; 164;
     129;  75; 218;  95; 127;  27; 146;  12; 209; 118;   6; 151; 201; 175; 106;  10;
     253; 122;  46; 236; 203;  26; 242;  67; 162; 224;  12; 151; 188;  64; 215;  93;
      55; 122; 151;   6; 213; 125; 250;  63; 140; 236;  56; 107; 253; 156; 100; 211;
      59;  16; 234;  53; 207;  71; 168;  55; 208; 111;  46; 156;  13;  76; 210;  50;
     230; 108;  38; 177;  68; 226; 107; 250;  78; 173; 237;  70; 128;  22; 147; 204;
      68;  98; 177; 145; 109; 172; 130; 215;  51; 114;  73; 248; 102;  21; 142; 162;
     192;  80; 177;  98; 143;  76; 159; 196;  37; 120;   7; 183;  20; 202;  27; 165;
     116; 188;  88; 152; 112; 133;  34; 240; 151;  24; 198; 129; 247; 180; 141;  97;
     195;  22; 243; 149; 205;  43; 184;  60;  32; 140; 101;  46; 214;  89;  41; 225;
     165;  31; 228;   9;  72;  42;  89;   5; 184; 207; 133;  36; 168; 202; 112; 234;
      41; 228;  22; 218;  39; 234;  11; 105; 225; 171; 211;  92; 144;  79; 232;  47;
     223; 143;  35; 199;   1; 222; 187;  93; 123; 227; 174;  84;  35;  59; 225;   3;
     171; 136;  59; 116;  19;  86; 131; 166; 201; 226;  17; 187; 248; 161; 112;  58;
     125; 194;  85; 133; 210; 188; 251; 151; 100;  23; 158;  86; 220;  51;  77;   2;
     159; 105; 131;  63; 196; 116; 181;  54;  84;  27; 150; 242;  55; 123; 179;  94;
      12;  74; 171; 245;  82;  48; 144;  11;  76;  58;  16; 104; 205; 161; 114;  79;
      41; 213;  91; 186; 232; 157; 217;   2; 113;  85; 155; 121;  65;   9; 179; 243;
      14; 153;  51; 239; 161;  17; 123;  46; 228;  62; 239; 182;  13; 124; 245; 138;
      59; 203; 251; 168;  90;  20; 136; 247; 161; 115;  71;  38; 193;   4; 151; 249;
     130; 208;  56; 120; 161; 103; 236; 200; 167; 245; 149; 220; 134;  19; 235; 192;
     122; 247; 160;   7;  52; 103;  71;  39; 242;  53; 176;  33; 204; 142;  79; 198;
     101; 219; 117;  23;  66; 108; 221;  78; 169; 129; 107;  44; 146; 194;  92; 178
  |]
[@@ocamlformat "disable"]

let%expect_test "indexbuf — reference model ≡ gcc-compiled dither.c (full frame)" =
  let lcg = ref 12345 in
  let next_byte () =
    lcg := ((!lcg * 1664525) + 1013904223) land 0xFFFFFFFF;
    (!lcg lsr 16) land 0xFF
  in
  let pixels = Array.create ~len:64000 0 in
  for k = 0 to 63999 do
    pixels.(k) <- next_byte ()
  done;
  let lut = Array.create ~len:256 0 in
  for k = 0 to 255 do
    lut.(k) <- next_byte ()
  done;
  let h = ref 0xcbf29ce484222325L in
  let fnv_byte b =
    h := Stdlib.Int64.mul (Stdlib.Int64.logxor !h (Stdlib.Int64.of_int b)) 0x100000001b3L
  in
  for y = 0 to 767 do
    for col = 0 to 31 do
      let w = reference_word ~thr:bn64 ~pixels ~lut ~y ~col in
      for k = 0 to 3 do
        fnv_byte ((w lsr (8 * k)) land 0xFF)
      done
    done
  done;
  Stdlib.Printf.printf "%016Lx\n" !h;
  [%expect {| b66f831b508c374f |}]
;;

(* Rung 2 — hardware ≡ model, through the real ports: threshold-table UPLOADS through the
   [thr_base] window (the content-free contract — first Bluenoise, then random maps),
   random LUT (word stores), random 10-byte source spans (word AND byte stores
   alternating), random (y, col); every fetched word diffed against [reference_word]. *)

let%expect_test "indexbuf — hardware ≡ model differential (300 random words)" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  let store ~adr ~ben ~wdata =
    inp.adr := Bits.of_unsigned_int ~width:24 adr;
    inp.ben := b1 ben;
    inp.wdata := Bits.of_unsigned_int ~width:32 wdata;
    inp.write := b1 1;
    Cyclesim.cycle sim;
    inp.write := b1 0
  in
  let fetch ~y ~col =
    let rr = 1023 - y in
    inp.vidadr := Bits.of_unsigned_int ~width:18 (Risc5.Video.org + (rr * 32) + col);
    inp.vidreq := b1 1;
    Cyclesim.cycle sim;
    inp.vidreq := b1 0;
    let word = ref (-1) in
    for _ = 1 to 16 do
      if !word < 0
      then (
        Cyclesim.cycle sim;
        if Bits.to_unsigned_int !(outp.vid_ack) = 1
        then word := Bits.to_unsigned_int !(outp.viddata))
    done;
    !word
  in
  inp.write := b1 0;
  inp.vidreq := b1 0;
  let st = Stdlib.Random.State.make [| 42 |] in
  let rnd n = Stdlib.Random.State.int st n in
  let pixels = Array.create ~len:64000 0 in
  let lut = Array.create ~len:256 0 in
  let load_lut () =
    for k = 0 to 255 do
      lut.(k) <- rnd 256
    done;
    for w = 0 to 63 do
      let v =
        lut.(4 * w)
        lor (lut.((4 * w) + 1) lsl 8)
        lor (lut.((4 * w) + 2) lsl 16)
        lor (lut.((4 * w) + 3) lsl 24)
      in
      store ~adr:(base + lut_off + (4 * w)) ~ben:0 ~wdata:v
    done
  in
  let thr = Array.create ~len:4096 0 in
  let load_thr () =
    (* first phase: the DOOM blue noise; later phases: random maps — the upload IS the
       contract (2048 slot quads, word stores at thr_base) *)
    for k = 0 to 4095 do
      thr.(k) <- (if rnd 2 = 0 then bn64.(k) else rnd 256)
    done;
    for a = 0 to 2047 do
      store ~adr:(thr_base + (4 * a)) ~ben:0 ~wdata:(slot_quad ~thr a)
    done
  in
  let first_thr () =
    Array.blit ~src:bn64 ~src_pos:0 ~dst:thr ~dst_pos:0 ~len:4096;
    for a = 0 to 2047 do
      store ~adr:(thr_base + (4 * a)) ~ben:0 ~wdata:(slot_quad ~thr a)
    done
  in
  first_thr ();
  let mismatches = ref 0 in
  let cases = 300 in
  for case = 0 to cases - 1 do
    if case % 50 = 0 then load_lut ();
    if case = 100 || case = 200 then load_thr ();
    let y = rnd 768
    and col = rnd 32 in
    let sy, _ = row_map.(y) in
    let sbase = (sy * 320) + (col * 10) in
    for b = sbase to sbase + 9 do
      pixels.(b) <- rnd 256
    done;
    if case land 1 = 0
    then
      (* word stores covering the span *)
      for w = sbase / 4 to (sbase + 9) / 4 do
        let v =
          pixels.(4 * w)
          lor (pixels.((4 * w) + 1) lsl 8)
          lor (pixels.((4 * w) + 2) lsl 16)
          lor (pixels.((4 * w) + 3) lsl 24)
        in
        store ~adr:(base + (4 * w)) ~ben:0 ~wdata:v
      done
    else
      (* byte stores, wdata byte-replicated as the core drives outbus *)
      for b = sbase to sbase + 9 do
        let v = pixels.(b) in
        store ~adr:(base + b) ~ben:1 ~wdata:(v lor (v lsl 8) lor (v lsl 16) lor (v lsl 24))
      done;
    let got = fetch ~y ~col in
    let want = reference_word ~thr ~pixels ~lut ~y ~col in
    if got <> want
    then (
      mismatches := !mismatches + 1;
      if !mismatches <= 5
      then Stdlib.Printf.printf "MISMATCH y=%d col=%d got=%08X want=%08X\n" y col got want)
  done;
  Stdlib.Printf.printf "%d cases, %d mismatches\n" cases !mismatches;
  [%expect {| 300 cases, 0 mismatches |}]
;;

(* Rung 3 — the write path and the control bit, framebuf-style. *)

let%expect_test "indexbuf — mode bit, LUT byte store, out-of-window store ignored" =
  let module Sim = Cyclesim.With_interface (I) (O) in
  let sim = Sim.create create in
  let inp = Cyclesim.inputs sim in
  let outp = Cyclesim.outputs sim in
  let b1 v = Bits.of_unsigned_int ~width:1 v in
  let store ~adr ~ben ~wdata =
    inp.adr := Bits.of_unsigned_int ~width:24 adr;
    inp.ben := b1 ben;
    inp.wdata := Bits.of_unsigned_int ~width:32 wdata;
    inp.write := b1 1;
    Cyclesim.cycle sim;
    inp.write := b1 0
  in
  let fetch ~y ~col =
    let rr = 1023 - y in
    inp.vidadr := Bits.of_unsigned_int ~width:18 (Risc5.Video.org + (rr * 32) + col);
    inp.vidreq := b1 1;
    Cyclesim.cycle sim;
    inp.vidreq := b1 0;
    for _ = 1 to 12 do
      Cyclesim.cycle sim
    done;
    Bits.to_unsigned_int !(outp.viddata)
  in
  inp.write := b1 0;
  inp.vidreq := b1 0;
  (* the content-free contract: upload the threshold quads first (here the DOOM blue noise
     — values in [1,254], so lum 200 clears many and lum 0 clears none) *)
  for a = 0 to 2047 do
    store ~adr:(thr_base + (4 * a)) ~ben:0 ~wdata:(slot_quad ~thr:bn64 a)
  done;
  let mode () = Bits.to_unsigned_int !(outp.mode) in
  (* mode: off at power-up, set by a CTL store, cleared by another *)
  Stdlib.Printf.printf "mode at power-up : %d\n" (mode ());
  store ~adr:(base + ctl_off) ~ben:0 ~wdata:1;
  Stdlib.Printf.printf "mode after set   : %d\n" (mode ());
  store ~adr:(base + ctl_off) ~ben:1 ~wdata:0;
  Stdlib.Printf.printf "mode after clear : %d\n" (mode ());
  (* LUT index 5 -> 200 via a byte store; pixel bytes 0..9 = index 5 *)
  store ~adr:(base + lut_off + 5) ~ben:1 ~wdata:0xC8C8C8C8;
  store ~adr:(base + 0) ~ben:0 ~wdata:0x05050505;
  store ~adr:(base + 4) ~ben:0 ~wdata:0x05050505;
  store ~adr:(base + 8) ~ben:0 ~wdata:0x05050505;
  let lit = fetch ~y:0 ~col:0 in
  (* the same span via a store one 64K page below the window: must change nothing *)
  store ~adr:(base - 0x10000) ~ben:0 ~wdata:0x00000000;
  let lit2 = fetch ~y:0 ~col:0 in
  Stdlib.Printf.printf "lum200 word nonzero : %d\n" (Bool.to_int (lit <> 0));
  Stdlib.Printf.printf "out-of-window inert : %d\n" (Bool.to_int (Int.equal lit lit2));
  (* LUT index 5 -> 0: everything under threshold, the word goes dark *)
  store ~adr:(base + lut_off + 5) ~ben:1 ~wdata:0;
  Stdlib.Printf.printf "lum0 word           : %08X\n" (fetch ~y:0 ~col:0);
  [%expect
    {|
    mode at power-up : 0
    mode after set   : 1
    mode after clear : 0
    lum200 word nonzero : 1
    out-of-window inert : 1
    lum0 word           : 00000000
    |}]
;;
