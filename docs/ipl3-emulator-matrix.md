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
| `custom` | whatever `pak link --ipl3 FILE.z64` lifts out of another ROM | the user | no |

`compat` is the default and the only one Pak ships. It is the right build for
Pak because Pak's linker emits a flat image rather than an ELF, which is
exactly the case the compat build exists for; see
`runtime/standalone/ipl3_compat.README.md` for the loader's two header fields
and why `0x10` carries the payload size.

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

### What would clear it

Not what this page used to say. "Patch out the `0x80000318` store" was the
obvious fix and the experiment above disproves it, so the real options are
bigger:

1. **Replace the RDRAM initialisation** with a probe mupen64plus agrees with.
   The honest fix, and real IPL3 engineering.
2. **Ship an emulator-only bootcode** that skips RDRAM init entirely. Both
   emulators present working RDRAM, so a loader that only DMAs the payload in
   and jumps would boot them. It would not boot a console, so it could only be
   an opt-in second blob, never the default.

Both edit the 4032 bytes the CIC checksums, so both need that checksum restored
or they trade "boots hardware and ares" for "boots emulators" <!-- known-bug: n/a — states what would close the row above -->.

The gate is ready either way: `tcl/tools/ipl3_matrix_test.tcl` runs the
mupen64plus row for real when the emulator is installed and asserts the failure
still reproduces, so when a bootcode fixes it that assertion is what flips.
Until then `--ipl3` is the escape hatch: any bootcode the user supplies goes in
verbatim.

## Boot termination

Independent of which IPL3 is used: something has to write `8` to the last word
of PIF RAM (`0xBFC007FC`) after boot, or the PIF halts the CPU five seconds in.
The compat loader deliberately does not, so `runtime/standalone/boot.S` does it
before calling `main`.

This is worth knowing because it is invisible on a lenient runner:
mupen64plus does not implement the timeout at all, and even on ares the picture
draws correctly for five seconds first. Only the log line names it, which is
why `tcl/tools/ares_test.tcl` reads the log and not just the screen.
