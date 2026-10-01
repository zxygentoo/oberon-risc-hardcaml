(* Contract in [test_gen.mli]. *)

let seed =
  match Sys.getenv_opt "QCHECK_SEED" with
  | None -> 0
  | Some s ->
    (match int_of_string_opt s with
     | Some n -> n
     | None -> failwith (Printf.sprintf "QCHECK_SEED must be an integer, got %S" s))
;;

let check_exn test = QCheck.Test.check_exn ~rand:(Random.State.make [| seed |]) test

open QCheck.Gen

let mask32 = 0xFFFF_FFFF
let hex32 = Printf.sprintf "0x%08X"

let word32_gen =
  oneof_weighted
    [ ( 2
      , oneof_list
          [ 0
          ; 1
          ; 2
          ; 0x7FFF_FFFE
          ; 0x7FFF_FFFF
          ; 0x8000_0000
          ; 0x8000_0001
          ; 0xFFFF_FFFE
          ; mask32
          ] )
    ; 1, map (fun k -> 1 lsl k) (int_bound 31)
    ; 1, map (fun k -> (1 lsl k) - 1) (int_range 1 32)
    ; 8, int_bound mask32
    ]
;;

let word32 = QCheck.make ~print:hex32 word32_gen

let fp32_gen =
  let edge =
    map3
      (fun s e m -> (s lsl 31) lor (e lsl 23) lor m)
      (int_bound 1)
      (oneof_list [ 0; 1; 2; 126; 127; 128; 150; 253; 254; 255 ])
      (oneof_weighted
         [ 1, oneof_list [ 0; 1; 0x40_0000; 0x7F_FFFE; 0x7F_FFFF ]
         ; 1, int_bound 0x7F_FFFF
         ])
  in
  oneof_weighted [ 1, edge; 3, int_bound mask32 ]
;;

let fp32 = QCheck.make ~print:hex32 fp32_gen

let divisor_gen =
  oneof_weighted
    [ 1, oneof_list [ 1; 2; 3; 0x4000_0000; 0x7FFF_FFFF ]
    ; 6, map2 (fun v sh -> max 1 (v lsr sh)) (int_bound 0x7FFF_FFFF) (int_bound 30)
    ]
;;

let divisor = QCheck.make ~print:hex32 divisor_gen

let signed ~bits =
  let lo = -(1 lsl (bits - 1))
  and hi = (1 lsl (bits - 1)) - 1 in
  let around = [ 0x7F; 0x80; 0xFF; 0x100; 0x7FFF; 0x8000; 0xFFFF; 0x1_0000 ] in
  let edges =
    [ lo; lo + 1; -2; -1; 0; 1; 2; hi - 1; hi ]
    @ List.concat_map (fun v -> [ v; -v ]) around
    |> List.filter (fun v -> v >= lo && v <= hi)
  in
  QCheck.make
    ~print:string_of_int
    (oneof_weighted [ 1, oneof_list edges; 1, int_range (-64) 63; 2, int_range lo hi ])
;;
