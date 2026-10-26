# Third-party material

What in this repository comes from elsewhere, where it came from, and the terms it
carries. Everything not listed here is this project's own work under the MIT license
in [`LICENSE`](LICENSE).

| Path | What it is | Upstream | Terms |
| --- | --- | --- | --- |
| `lib/` | The machine: a Hardcaml port of the Project Oberon RISC5 Verilog — the core, its arithmetic units, the peripherals | [projectoberon.net][po] `OStationVerilog.zip`, the revision `test/rtl-sources.txt` pins | the port is MIT; it derives from Project Oberon 2013 software — [notice A](#a-project-oberon-2013) |
| `lib/rom.ml` | The Project Oberon boot loader PROM image, as the C emulator carries it | [`pdewacht/oberon-risc-emu`][c] `src/risc-boot.inc`, by way of [`oberon-risc-emu-ocaml`][emu] | [notice B](#b-oberon-risc-emu); the image itself is Project Oberon 2013 software — [notice A](#a-project-oberon-2013) |
| `test/formal/proofs/core_stubs.v`, `test/formal/proofs/mouse_shim.v`, `test/cosim/vid_cosim.v`, `test/cosim/mouse_cosim.v` | Stubs and wrappers that reproduce reference modules' port lists or quote a few of their lines | as `lib/` | [notice A](#a-project-oberon-2013) for what they reproduce |
| `board/nexys-4/nexys4.xdc` | The board's pin assignments, taken from Digilent's master constraints file | [`Digilent/digilent-xdc`][xdc] `Nexys-4-Master.xdc` | MIT, © 2017 Digilent — [notice C](#c-digilent-xdc) |
| `vendor/oberon-risc-emu-ocaml` | The OCaml emulator, the verification oracle, with the disk image the gates boot — a git submodule | [`zxygentoo/oberon-risc-emu-ocaml`][emu] | its own `LICENSE` (ISC) and `THIRD_PARTY.md` |

Not vendored: the reference Verilog itself. `test/fetch-rtl.sh` downloads
`OStationVerilog.zip` from projectoberon.net on first use and checks it against the
checksums in `test/rtl-sources.txt`.

## Notices

### A. Project Oberon 2013

```
Project Oberon, Revised Edition 2013

Book copyright (C)2013 Niklaus Wirth and Juerg Gutknecht;
software copyright (C)2013 Niklaus Wirth (NW), Juerg Gutknecht (JG), Paul
Reed (PR/PDR).

Permission to use, copy, modify, and/or distribute this software and its
accompanying documentation (the "Software") for any purpose with or
without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHORS DISCLAIM ALL WARRANTIES
WITH REGARD TO THE SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY, FITNESS AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, SPECIAL, DIRECT, INDIRECT, OR
CONSEQUENTIAL DAMAGES OR ANY DAMAGES OR LIABILITY WHATSOEVER, WHETHER IN
AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE DEALINGS IN OR USE OR PERFORMANCE OF THE SOFTWARE.
```

### B. oberon-risc-emu

```
Copyright © 2014 Peter De Wachter

Permission to use, copy, modify, and/or distribute this software for
any purpose with or without fee is hereby granted, provided that the
above copyright notice and this permission notice appear in all
copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
PERFORMANCE OF THIS SOFTWARE.
```

### C. digilent-xdc

```
MIT License

Copyright (c) 2017 Digilent

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

[po]: http://www.projectoberon.net
[c]: https://github.com/pdewacht/oberon-risc-emu
[emu]: https://github.com/zxygentoo/oberon-risc-emu-ocaml
[xdc]: https://github.com/Digilent/digilent-xdc
