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

### The actual root cause

Found by building mupen64plus 2.5.9 from source and instrumenting it. The
short version: **libdragon's IPL3 detects zero bytes of RDRAM on
mupen64plus**, and the "64 MB" in the error message has nothing to do with it.

The error everyone reads is a red herring. mupen64plus's `write_rdram_regs`
does this, and the comment is its own:

```c
/* HACK: In the IPL3 procedure, at this point,
 * the amount of detected memory can be found in s4 */
size_t ipl3_rdram_size = r4300_regs(rdram->r4300)[20] & UINT32_C(0x0fffffff);
if (ipl3_rdram_size != rdram->dram_size) {
    DebugMessage(M64MSG_ERROR, "IPL3 detected %u MB of RDRAM != %u MB", ...);
}
```

It peeks at CPU register `$s4` when IPL3 broadcasts to `RDRAM_MODE_REG`,
because that is where *Nintendo's* IPL3 happens to keep the size. libdragon is
a different program and `$s4` holds something else entirely. The message is a
`DebugMessage` — it changes no state and stops nothing. It is noise.

The real failure is the line after it, `reserved opcode: 80000300:1`, and the
trace says why:

```
PAKTRACE: RI read reg=3 val=00000000      <- RI_SELECT == 0, so the cold-boot
                                             path runs and rdram_init() is used
PAKTRACE: PI write cart=10000B08 -> dram=00FFFF08 len=F8 rawdram=7FFFFF08
PAKTRACE: [80000400] = 00000000           <- the payload never arrived
reserved opcode: 80000300:1               <- executing osTvType as an opcode
```

`rawdram=0x7FFFFF08` is the whole story. `boot/loader.h` places stage 2 at
`LOADER_BASE(memsize, stage2size) = 0x80000000 + memsize - stage2size`, and
`0x80000000 + 0 - 0xF8` is exactly `0x7FFFFF08`. **`memsize` is zero.**
libdragon's probe found no chips at all, stage 2 was DMA'd to a nonsense
address, the payload load that stage 2 would have done never happened, and the
CPU fell into the boot-config block at `0x80000300` — where `osTvType == 1`,
which is not a valid instruction.

That also explains why capping the probe at 8 MiB changed nothing: the loop
was not overcounting, it was exiting on its first iteration.

### Why the probe finds nothing

The chip-detect loop turns a chip on and reads `RDRAM_REG_MODE` back to see
whether the `DE` bit stuck. On mupen64plus that read is routed through
`get_module()`, which matches the access against each module's `DEVICE_ID`
register — and the two sides encode that register differently:

| | id bits 0–5 | id bits 6–14 | id bit 15 |
|---|---|---|---|
| libdragon writes (`rdram_reg_w_deviceid`) | value[7:2] | value[23:15] | value[31] |
| mupen64plus reads (`idfield_value`) | value[31:26] | value[23:16] (8 bits) + value[23] | value[7] |

They agree only for device id 0. libdragon parks every chip at a high id
first, so from the second register access onward mupen64plus cannot find the
module, returns 0, the `DE` bit reads back clear, and the loop concludes there
is no chip there.

Teaching mupen64plus libdragon's `idfield_value` layout is not sufficient on
its own — `ri_address_to_id_field()` maps the access address to an id too, and
would have to agree as well. That was tried and the ROM still fails.

### What that means for Pak

Nothing Pak can do from the ROM side bridges this. It is a disagreement about
an RDRAM register layout between an emulator and a bootcode that boots real
hardware and ares. Clearing the row needs either mupen64plus's RDRAM model
changed, or libdragon writing device IDs in mupen64plus's layout instead --
and that second option is a change to the code whose entire job is driving
real RDRAM chips, which is exactly what cannot be validated on an emulator.

Hypotheses tested and eliminated along the way, each against a real
mupen64plus 2.5.9:

| Hypothesis | Test | Result |
|---|---|---|
| The `osMemSize` word at `0x80000318` | patch the only `sw s0, 0x318(v0)` to a `nop` | still fails |
| ...maybe it just needs a sane value | patch it to `sw $zero` | still fails |
| The chip-count loop runs away | rebuild with the loop capped at 8 MiB | still fails (it exits at the *first* chip) |
| The `INITIAL_ID = 511` broadcast | rebuild with `INITIAL_ID = 16` | still fails |
| Shipping `ipl3_prod.z64` instead | `boot/ipl3.c`'s only `COMPAT` difference is where memsize is published; `rdram_init()` is identical | would not help |

### The build pipeline is ready for whoever tries next

`tools/build_ipl3.sh` rebuilds the compat bootcode from libdragon's source,
with an optional `--patch`. Build from source rather than editing the shipped
binary: the CIC checksums these 4032 bytes and libdragon's build produces a
blob that satisfies it.

Run it once with no patch first. The result is **not** byte-identical to
`ipl3_compat.bin` — a different GCC lays the code out differently — but it must
fail on mupen64plus in exactly the same way. It does, which is what makes a
later behavioural difference attributable to a patch rather than to the
compiler.

## Boot termination

Independent of which IPL3 is used: something has to write `8` to the last word
of PIF RAM (`0xBFC007FC`) after boot, or the PIF halts the CPU five seconds in.
The compat loader deliberately does not, so `runtime/standalone/boot.S` does it
before calling `main`.

This is worth knowing because it is invisible on a lenient runner:
mupen64plus does not implement the timeout at all, and even on ares the picture
draws correctly for five seconds first. Only the log line names it, which is
why `tcl/tools/ares_test.tcl` reads the log and not just the screen.
