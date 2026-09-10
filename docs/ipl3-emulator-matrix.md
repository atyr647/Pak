# Which IPL3, which emulator, what should happen

A `.z64` `pak link` produces is not "a ROM" in the abstract. It is a payload
plus 4032 bytes of bootcode at `0x40..0xFFF`, and that bootcode decides which
machines the ROM will start on. This page is the matrix: which IPL3 Pak can put
there, which runner it has been observed on, and what the correct outcome is.

It exists because "it boots" was previously a claim with no table behind it,
and the one runner Pak's CI uses (ares) is also the most permissive about the
thing that breaks elsewhere. **A ROM that only runs on ares is not
standalone**, and the honest way to say that is a row per pair, including the
rows that fail.

The gate that keeps this page from rotting is `tcl/tools/ipl3_matrix_test.tcl`:
every row below is parsed out of this file, and the ones it can check on the
machine it is running on, it checks.

---

## The bootcodes

| id | What it is | Where it comes from | Ships in-tree |
|----|------------|---------------------|---------------|
| `compat` | libdragon's IPL3, **compat** build | `boot/bin/ipl3_compat.z64` at the revision `tools/fetch_libdragon.sh` pins | yes — `runtime/standalone/ipl3_compat.bin` |
| `none` | the region left zeroed | what `pak link` did before it shipped a bootcode | n/a |
| `custom` | whatever `pak link --ipl3 FILE` supplies | the user | no |

`pak link --ipl3` takes a name from this table, a raw 4032-byte bootcode, or a
`.z64` to lift the region out of. A name that does not resolve is an error
rather than a silent fall back to the default — the whole point of asking for a
different bootcode is that the default was not what you wanted.

`compat` is the only one Pak ships, and it is the right build for Pak because
the linker emits a flat image rather than an ELF, which is the case the compat
build exists for; see `runtime/standalone/ipl3_compat.README.md`.

## The matrix

| IPL3 | Runner | Expected | Checked by |
|------|--------|----------|------------|
| `compat` | ares (built by `tools/build_ares.sh`) | boots; draws the frame; no PIF boot-timeout in the log | `tcl/tools/ares_test.tcl` |
| `compat` | real hardware / flashcart | boots (same loader libdragon ships) | not automated — no hardware in CI |
| `compat` | mupen64plus 2.5.9 | **does not boot** — `IPL3 detected 64 MB of RDRAM != 8 MB` <!-- known-bug: mupen64plus-ipl3 --> | `tcl/tools/ipl3_matrix_test.tcl` (documented, run when mupen64plus is present) |
| `none` | any | does not boot — the PIF jumps into 4032 zero bytes <!-- known-bug: n/a — `none` is the absence of a bootcode, not a defect --> | `tcl/tools/ipl3_matrix_test.tcl` (header check, no emulator needed) |
| `custom` | whatever that bootcode supports | the user's problem | n/a |

### The mupen64plus row is not Pak's bug, and is still Pak's problem

mupen64plus 2.5.9 models RDRAM as modules and compares its configured total
against what IPL3's probe configured. libdragon's probe walks off the end of
this emulator's RDRAM and comes back with 64 MB, so the two disagree and it
stops:

```
Core Error: IPL3 detected 64 MB of RDRAM != 8 MB
Core Error: reserved opcode: 80000300:1
```

A ROM whose entire payload is `b .` / `nop` fails identically, so nothing above
ROM `0x1000` is involved — this is the bootcode and the emulator, not the
compiler.

It is **not** the `osMemSize` word at `0x80000318`, which is what this page and
`ipl3_compat.README.md` used to say. Patching the only `sw s0, 0x318(v0)` in
the blob to a `nop` leaves mupen64plus reporting exactly 64 MB, which it could
not do if that word were the source. The number comes from the RDRAM/RI
initialisation instead.

That means the honest status is: **Pak's default ROM boots ares and hardware,
and does not boot mupen64plus 2.5.9** <!-- known-bug: mupen64plus-ipl3 -->. It is carried as a live row in
`CURRENTLY_SUPPORTED.md`'s table of live bugs <!-- known-bug: mupen64plus-ipl3 -->,
and it stays there until Pak ships a bootcode that clears it.

### What has been ruled out

Four plausible causes, each tested against a real mupen64plus 2.5.9 and each
wrong. The reported number is **exactly 64 MB in every case** — it never
moves — which is the most informative fact here: whatever mupen64plus is
measuring, it is not something libdragon's probe computes.

| Hypothesis | How it was tested | Result |
|---|---|---|
| The `osMemSize` word at `0x80000318` | patch the only `sw s0, 0x318(v0)` to a `nop` | still 64 MB |
| ...maybe the word just needs a sane value | patch it to `sw $zero`, so the word is definitely 0 | still 64 MB |
| The chip-count loop runs away | rebuild from source with the loop capped at 8 MiB (verified in the object: `bne s2, 0x800000`) | still 64 MB |
| The `INITIAL_ID = 511` broadcast | rebuild with `INITIAL_ID = 16` | still 64 MB |

Shipping `ipl3_prod.z64` instead is not an option either: `boot/ipl3.c`'s only
`COMPAT` conditional is *where* the detected size is published, while
`rdram_init()` in `boot/rdram.c` is identical across all three builds.

### What is known about the trigger

Disassembling `libmupen64plus.so.2.0.0` around the error string puts the check
inside the RDRAM **register-write** handler, on the path taken when the write
is a broadcast to register 3 — `RDRAM_REG_MODE`, which `rdram_init()`
broadcasts two statements after parking every chip at `INITIAL_ID`. It compares
mupen64plus's configured size against a field reached through the rdram struct,
masked to 28 bits.

So the incompatibility is between libdragon's RDRAM initialisation *protocol*
and mupen64plus's RDRAM register model, not a tunable constant. Clearing it
needs either mupen64plus's own `rdram.c` (which would say what that field is)
or a reworked probe — and a reworked probe is exactly the code that cannot be
validated on an emulator, because it exists to drive real RDRAM chips.

### The build pipeline is ready for whoever tries next

`tools/build_ipl3.sh` rebuilds the compat bootcode from libdragon's source,
with an optional `--patch`. Build from source rather than editing the shipped
binary: the CIC checksums these 4032 bytes and libdragon's build produces a
blob that satisfies it.

Run it once with no patch first. The result is **not** byte-identical to
`ipl3_compat.bin` — a different GCC lays the code out differently, 1558 bytes'
worth — but it must fail on mupen64plus in exactly the same way. It does, which
is what makes a later behavioural difference attributable to a patch rather
than to the compiler.

## Boot termination

Independent of which IPL3 is used: something has to write `8` to the last word
of PIF RAM (`0xBFC007FC`) after boot, or the PIF halts the CPU five seconds in.
The compat loader deliberately does not, so `runtime/standalone/boot.S` does it
before calling `main`.

This is worth knowing because it is invisible on a lenient runner:
mupen64plus does not implement the timeout at all, and even on ares the picture
draws correctly for five seconds first. Only the log line names it, which is
why `tcl/tools/ares_test.tcl` reads the log and not just the screen.
