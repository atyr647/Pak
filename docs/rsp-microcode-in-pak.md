# Writing RSP microcode in Pak

Status: **design note**. Nothing here is implemented. This exists to settle
*what the language should look like* before any of it is built, because the
grammar is frozen (`LANGUAGE.md`) and a bad answer here is expensive to undo.

---

## The question

The RSP is a second processor with a vector unit. Pak compiles for the CPU.
Today a Pak program can *run* a microcode task -- `n64.sp` loads it, kicks it,
and reads the results back (`tcl/tests/ares/rsp.pk64` does exactly that on real
hardware) -- but the microcode itself has to come from somewhere else, as a
blob of pre-assembled words.

So: what would it look like for that blob to be written in Pak?

The constraint that matters is not "can we emit RSP instructions." It is that
whatever we add has to still be Pak. Pak is a small language that says no a
lot. The design below tries to add exactly one new primitive type and one new
module, and to get everything else for free from concepts the language already
has.

---

## What Pak already decided

Five existing decisions do most of the work here, and the design just follows
them:

**1. Hardware is a module with a documented call order, enforced by the
checker.** `cache.writeback` -> `dma.read` -> `dma.wait` -> `cache.invalidate`
is not a comment, it is `E201`. `controller.poll()` before `controller.read()`.
`rdpq.sync_pipe()` between mode switches. When Pak meets a stateful piece of
hardware, it does *not* hide the state behind an operator -- it exposes it as a
module and makes the compiler enforce the sequence.

**2. Primitives are lowercase and describe their layout.** `i16`, `u32`,
`fix16.16`, `fix10.5`, `fix1.15`. Machine types are spelled the way the machine
is shaped, not given friendly names.

**3. `static` is persistent memory; `@aligned(N)` is where it sits.** Both
already mean exactly what a microcode needs them to mean.

**4. A backend says what it cannot do by refusing.** The standalone backend
does not pretend `t3d.model_draw` works; it reports `E010` and names the
reason. That is how a target communicates its limits.

**5. `entry` is where a program starts.** Not a function -- a program.

---

## The shape of the answer

### A microcode is a program, not a function

This is the one framing decision everything else follows from.

A microcode has its own instruction memory, its own data memory, its own
address space, and its own starting point. It does not share a stack, a heap,
or a pointer with the CPU program. That is not a function. That is a program
that happens to be small.

So it is an ordinary `.pk64` file with an ordinary `entry` block, built for a
third target:

```
pak build --target rsp src/transform.pk64
```

The same relationship the standalone backend already has to the libdragon
backend: same language, same front end, different machine, different HAL, and
a much longer list of things it refuses.

No new declaration form. No `@rsp_command`. No new file extension. It is a Pak
program; it just runs somewhere else.

### `vec8x16` -- the vector register

One new primitive type. The RSP's vector register is 8 lanes of 16 bits, so
that is what it is called, in the same style as `fix16.16`:

| Type       | Description                     | Size     |
|------------|---------------------------------|----------|
| `vec8x16`  | 8 lanes x 16 bits, one register | 16 bytes |

It is a value. It is copied by value. It lives in a register the way an `i32`
local does, and `@aligned(16)` `static`s of it live in DMEM.

Lanes are read and written with indexing Pak already has:

```pak
let x: i16 = v[0]
v[1] = 42 as i16
```

Broadcasting one lane across all eight -- which the hardware encodes as an
operand modifier, costing no instruction -- is a method, and the index must be
a literal because the encoding has a field for it, not a register:

```pak
let all_x: vec8x16 = v.broadcast(0)
```

Elementwise arithmetic uses the operators Pak already has, because these are
single instructions with no hidden state:

```pak
let c: vec8x16 = a + b        -- VADD
let d: vec8x16 = a - b        -- VSUB
let e: vec8x16 = a & b        -- VAND
let f: vec8x16 = a << 2       -- VSLL
```

These are the operators Pak already has, with the meanings Pak already gives
them -- `&` is bitwise (`and` is the logical operator and stays logical). No
new operator, and nothing that lowers to more than one instruction.

Division is deliberately absent: the hardware has no vector divide. That is a
refusal (see below), not an omission.

### `vacc` -- the accumulator is hardware, so it is a module

The RSP multiplies into an accumulator: 8 lanes of 48 bits, written by the
multiply family and read back in three 16-bit slices. There is exactly one of
them. A second multiply overwrites what the first left there unless you asked
it to accumulate.

That is stateful hardware with a required call order. Pak already has an answer
for that, and it is not an operator:

```pak
use rsp.vacc

vacc.mul(m0, v.broadcast(0))    -- VMULF: acc  = m0 * v.x
vacc.mac(m1, v.broadcast(1))    -- VMADF: acc += m1 * v.y
vacc.mac(m2, v.broadcast(2))
vacc.mac(m3, v.broadcast(3))
let result: vec8x16 = vacc.high()
```

Compare RSPL, which spells this with a `+*` operator whose left-hand side is
reassigned but whose accumulator silently survives across statements. That is a
neat trick and it is the opposite of how Pak treats every other piece of
hardware. `vacc.mac(...)` reads as what it is: a write to a register that is
still holding what you put there last line.

Checker rules, in the style of `E201`:

- reading `vacc.high()` / `.mid()` / `.low()` with no `vacc.mul` or `vacc.mac`
  before it in the same block is an error -- you are reading whatever the last
  unrelated multiply left behind
- `vacc.mac` with no `vacc.mul` before it is an error -- you are accumulating
  onto a stale value

Both are exactly the shape of "you did not call `cache.writeback` first."

The 48-bit width is why there are three readers. `high()` is the one a
transform wants (`fix1.15` inputs, integer-ish output); `mid()` and `low()`
exist because the hardware does and hiding two thirds of a register would be a
lie.

### DMEM is `static`

```pak
@aligned(16)
static vertices: [64]vec8x16

@aligned(16)
static mvp: [4]vec8x16
```

That is DMEM. Same keyword, same annotation, same meaning as on the CPU --
memory that persists for the life of the program, at a fixed address. The only
new fact is that the address space is 4 KB, which the checker knows and
enforces at build time rather than letting a program silently overflow into
nothing.

### The ABI is a struct both sides `use`

The CPU DMAs input in before it kicks the task and DMAs results out after. So
the interface between the two programs is a memory layout, and Pak already has
a way for two files to agree on a memory layout: a `struct` in a `module` both
of them import.

```pak
-- src/shared/vtxjob.pk64
module shared.vtxjob

@aligned(16)
struct VtxJob {
    mvp:      [4]vec8x16,
    count:    i32,
    vertices: [64]vec8x16
}
```

The microcode `use`s it to know where things are; the CPU program `use`s it to
fill it in. No generated headers, no offset constants, no magic numbers -- the
same struct, compiled twice, which is what it already means for a struct to be
in a shared module.

### The CPU side loads it as an asset

A microcode is a file that the build converts into a packed artifact the ROM
carries and the program looks up by name. Pak has one concept for that:

```pak
asset vtx_ucode: Ucode from "rsp/transform.pk64"
```

`.png` -> `.sprite` and `.wav` -> `.wav64` already work this way
(`pak::ASSET_PACKED_EXT`); `.pk64` -> `.ucode` is the same mapping with the
same machinery. The handle is the loaded image, and the module that runs it
already exists:

```pak
use n64.sp

sp.init()
sp.load_ucode(vtx_ucode, vtx_ucode_len)
sp.load_data(&job as u32, 0, sizeof(VtxJob))
sp.run(0)
sp.wait()
sp.read_data(&job as u32, 0, sizeof(VtxJob))
```

Every one of those calls exists today, with those signatures
(`sp.load_ucode(src, len)`). The only new thing is the asset type that produces
`vtx_ucode` and its length -- and a `Ucode` asset needing to hand over two
values is a wrinkle worth deciding deliberately: either the handle is a small
struct with `.addr` and `.len`, or the asset declaration emits `<name>_len`
beside it the way it already emits `<name>_path`. The second is more consistent
with what assets already do.

---

## A whole microcode

```pak
-- rsp/transform.pk64 -- transform a batch of vertices by an MVP matrix.
--
--   pak build --target rsp rsp/transform.pk64
--
-- DMEM is the interface: the CPU fills in a VtxJob, kicks this, and reads the
-- transformed vertices back out of the same struct.

use rsp.vacc
use shared.vtxjob

@aligned(16)
static job: VtxJob

entry {
    let mut i: i32 = 0
    while i < job.count {
        let v: vec8x16 = job.vertices[i]

        vacc.mul(job.mvp[0], v.broadcast(0))
        vacc.mac(job.mvp[1], v.broadcast(1))
        vacc.mac(job.mvp[2], v.broadcast(2))
        vacc.mac(job.mvp[3], v.broadcast(3))

        job.vertices[i] = vacc.high()
        i = i + 1
    }
}
```

That is Pak. A `use`, a `static`, an `entry`, a `while`, an index, a method
call. A person who has read `LANGUAGE.md` and nothing else can read it. The
only two things they have not seen before are `vec8x16` and `vacc`, and both
are named after the hardware they are.

That is not a claim made by eye: the structural shape above -- statics of array
type with `@aligned(16)`, a struct-typed `static` with no initialiser, indexing
a struct's array field, `sizeof`, method calls on a value, module calls --
parses and checks clean against today's parser with placeholder types
substituted for `vec8x16`. **No grammar change is required.** What is required
is one primitive type, one module, one build target, and their type rules.

---

## What the RSP target refuses

Generously, and by name, the way the standalone backend already does:

| Refused | Why |
|---|---|
| `f32`, `f64` | no FPU |
| `alloc` / `free` | no heap; DMEM is 4 KB and static |
| `Str`, `CStr` | no |
| recursion | no stack |
| function pointers, `dyn Trait` | no indirect calls worth having |
| `i64` / `u64` | not in the scalar subset |
| `/` and `%` | no divide; use the reciprocal instructions |
| every `n64.*` module | display, controller, EEPROM -- none of it is reachable from here |
| a program over 4 KB of code, or statics over 4 KB | IMEM and DMEM, checked at build |

The last one is the interesting one: it is a *build-time* limit the compiler
can enforce exactly, which is a nicer failure than the usual N64 experience of
finding out on hardware.

---

## The part that is actually hard

Everything above is design. This is engineering, and it is where the real work
is:

**Instruction scheduling.** The vector unit has issue-to-use latency. A naive
one-statement-one-instruction codegen produces code that is correct only by
accident. RSPL's own commit log is *still* iterating on this ("look-ahead
register alloc", "allow MAC sequences to be reordered") years in.

The honest v1 answer is to be correct and slow: insert enough separation to
never hazard, accept the stalls, and make the gate prove correctness rather
than speed. Getting fast comes later and is a different project.

**Verification.** There is no GNU `as` for RSP vector opcodes, so the
`n64enc-vs-gas` trick does not directly transfer. The available oracle is
`armips` -- the assembler libdragon and RSPL both use -- fetched and pinned the
way `libdragon` and Tiny3D already are, with the encoder diffed against it
byte-for-byte. Same gate shape, different reference.

---

## Suggested order

1. **Scalar-only RSP target.** No vectors at all. `entry`, `static`s in DMEM,
   `while`, integer math -- compiled to the RSP's scalar half, which is a MIPS I
   subset `tcl/n64enc.tcl` already assembles correctly (proven by the existing
   ares test). Ship it when a Pak-written task runs on ares and returns the
   right answer. This is mostly wiring existing pieces together and it makes
   every later step testable.
2. **`vec8x16` and the elementwise operators.** New type, new encodings,
   `armips` differential gate. No accumulator yet.
3. **`vacc`.** The multiply family and the checker rules that keep its call
   order honest.
4. **`asset ... : Ucode`.** The build path that turns step 1's output into
   something the CPU program carries and loads.

Steps 1 and 4 are what make it *usable*; 2 and 3 are what make it *fast*. They
are separable, and doing them in this order means there is something working at
the end of each.
