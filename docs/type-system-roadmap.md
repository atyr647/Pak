# Type system roadmap

Status: **design note, nothing implemented**. This records which ideas from
dependently- and linearly-typed languages -- ATS in particular -- are worth
taking into Pak's checker, which are not, and why adopting such a language as a
substrate was considered and rejected.

The motivating question was: should Pak be rebuilt as a DSL that elaborates
into an ATS-typed core, inheriting dependent types, linear resource tracking
and precise layouts "for free"?

The answer was no. The reasoning is recorded in section 4 so it does not have
to be re-litigated. The *ideas* are worth taking; the dependency is not.

---

## 1. What Pak already checks

Pak is not an untyped substrate waiting for a type system. Three of the
invariants that motivate the dependent-typing pitch are already enforced, as
flow analysis in `tcl/typechecker.tcl`:

| Code | Invariant | Mechanism | Where |
|------|-----------|-----------|-------|
| `E202` | DMA buffer is 16-byte aligned | `aligned_vars` set, populated by `@aligned(16)` | `check_dma_call`, ~1119 |
| `E201` | Cache written back before DMA | `cache_written` set, populated by `cache.writeback` | same |
| `E401` | No use after move | `is_moved` per scope | `check_expr`, ~618 |

Alignment, DMA ownership ordering, and affine move semantics -- three of the
six invariants on the original wish list -- in a few dozen lines each.

They are crude. They also catch the real bugs, and their diagnostics name the
fix:

```
error[E202]: buffer 'tex' may not be 16-byte aligned for DMA
  help: Declare it with @aligned(16): @aligned(16) let tex: ...
```

That help text is worth more day to day than a soundness proof. Any replacement
must preserve it.

---

## 2. Known holes

These are the places the current checks are unsound, in rough order of how
often they will bite.

**Alignment does not survive a function boundary.** `aligned_vars` is tracked
per function, keyed by variable *name*. Pass a DMA buffer to a helper and the
knowledge evaporates:

```pak
@aligned(16) let buf: [512]u8     -- E202 satisfied here
load_texture(&buf, addr)          -- and lost here
```

Inside `load_texture`, the parameter carries no alignment, so either the check
fires spuriously or (worse) does not fire on a genuinely misaligned caller.
This is the single highest-value fix available.

**Cache-writeback tracking is name-based and flow-insensitive across
branches.** `cache_written` is a flat set; a writeback on one side of an `if`
is credited unconditionally.

**Nothing relates a buffer to its capacity.** Slices are `{ptr, len}` fat
pairs at runtime, but the checker does not relate a static index to a static
length, so a constant out-of-bounds index into a fixed array is not a
compile-time error.

**Resource pairing is unchecked.** `rdpq` attach/detach, `sync_pipe` between
mode switches in a frame, audio buffer acquire/release, EEPROM transaction
boundaries -- all are documented conventions (`N64_HARDWARE.md`) with no
enforcement.

---

## 3. Worth taking

Each of these is an independent, incremental change to the existing checker. In
value order.

### 3.1 Alignment as a type property

Move `@aligned(N)` off the declaration and into the type, so it propagates
through parameters, returns and struct fields:

```pak
fn load_texture(dst: *aligned(16) u8, src: u32, len: i32)
```

The call site must supply a pointer known to be 16-byte aligned; the body gets
the property for free. Fixes the hole in section 2 and makes `E202`
compositional instead of local.

Roughly a weekend of work in `typechecker.tcl` plus type-syntax changes. This
is the one to do first.

### 3.2 Capacity-indexed slices

Let a slice type carry a static capacity where one is known, and check constant
indices against it:

```pak
let verts: []Vtx cap 64
verts[64]        -- error at compile time
```

Deliberately weak: constant indices only, no solver, no proof obligations.
On the N64 most sizes are compile-time constants -- framebuffer 320x240,
display list 8 KiB, EEPROM block 8 bytes -- so constant propagation recovers
most of the benefit that full dependent typing would provide, at a fraction of
the machinery.

### 3.3 Affine resource tracking for a fixed set of resources

Not a general linear type system. A small, closed list of resources that must
be acquired, used and released in order:

- DMA transfer in flight (`dma.read` -> `dma.wait`)
- `rdpq` attach / detach
- mode switch -> `sync_pipe` -> mode switch within a frame
- audio buffer acquire / release
- EEPROM transaction

`E401` already demonstrates the machinery. Generalising it to a handful of
named resource kinds with a state machine per kind is a contained change, and
turns five documented conventions into five compiler errors.

### 3.4 Memory region as a type property

Framebuffers live in uncached KSEG1; the heap is cached KSEG0. Confusing them
produces bugs that look like rendering glitches. A region tag on pointer types
(`*kseg1 u16`) would make `fb_fill(heap_ptr, ...)` a type error rather than a
mystery.

Lower priority than the above -- the current code gets this right by
convention because the addresses are constants -- but it becomes valuable as
soon as buffers are passed around dynamically.

---

## 4. Why not build on ATS

Recorded so it does not get reconsidered from taste rather than facts.

**ATS2 compiles to C.** The standalone backend emits MIPS directly and links a
`.z64` with no external toolchain at all -- no `mips64-elf-gcc`, `as`, `ld`,
`objcopy` or `n64tool` (`docs/toolchain-free-rom.md`). Building on ATS makes
the pipeline `Pak -> ATS -> C -> gcc -> ld -> objcopy`, deleting the most
distinctive engineering asset the project has.

**It specifically breaks the live-development plan.** Hot patching is cheap
because `.pakobj` is a text format Pak owns, with its own relocation records:
`pak link --base` plus `--defsyms` is a small change to a 430-line file
(`docs/live-development.md` s7). With gcc and GNU ld in the pipeline, every
hot patch means driving a linker script, emitting ELF, and parsing ELF
relocations back out host-side.

**Elaborating a DSL into a dependently-typed core has a known failure mode:
error messages.** Constraint failures surface in terms of the generated core,
not the source the developer wrote. Someone writes `dma.read(buf, addr, 512)`
and receives a solver error about an unsatisfiable static in machine-generated
code they have never seen. Fixing that means threading source provenance
through elaboration and building a constraint-failure -> diagnostic mapping;
that mapping is the bulk of the work, is a research problem rather than an
engineering one, and has no reference implementation to copy. Compare the
`E202` diagnostic in section 1, which is already better than what the
substrate would produce.

**The payoff is smaller here than it looks.** Dependent types earn their
complexity when sizes are dynamic and interrelated. N64 sizes are
overwhelmingly compile-time constants. The weak, constant-only version in
section 3.2 captures most of the value.

**Cost.** ~24,600 lines of working Tcl, two backends plus an RSP target, a MIPS
simulator, an RDP disassembler, a flat linker, a ROM packer, 32 canonical
examples and a CI gate. The pivot discards roughly the backend half (~9,000
lines across `mips_codegen`, `n64enc`, `n64link`, `n64rom`) and takes on a
dependency with a very small active community and a long-running unfinished
successor version. For a solo maintainer, the bus factor of the dependency is
worse than the bus factor of the project.

**What survives the rejection**: the underlying idea -- encode N64 invariants in
types -- is right, and section 3 is how to get it. Implement an ATS-*inspired*
typed core inside Pak's own checker; keep the backend.

---

## 5. Sequencing

Do not start section 3 yet.

The list in section 3 is a well-reasoned guess about which invariants matter.
It is not evidence. The live-development plane
(`docs/live-development.md`) will produce evidence: a month of hot-patching a
real game on real silicon yields a list of things that actually went wrong,
and that list will not be the list above.

A type system designed against real failure data will be smaller, sharper and
more pleasant to use than one designed against anticipated failure data. The
tether is also the cheaper project.

**Order: build the tether, play the game, collect the failures, then design the
types.**

The one exception is 3.1. The hole is known, concrete, and independent of any
evidence-gathering -- it can be fixed whenever there is an idle weekend.
