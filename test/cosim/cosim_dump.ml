open Hardcaml

let set r v = r := Bits.of_unsigned_int ~width:(Bits.width !r) v
let rd r = Bits.to_int_trunc !r
let hex_digit n = "0123456789ABCDEF".[n land 0xF]
let rand32 rng = (Random.State.int rng 0x10000 lsl 16) lor Random.State.int rng 0x10000
