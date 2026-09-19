# Live development on real hardware

Status: **design note, nothing implemented**. This describes a tethered
development plane -- a resident monitor on the N64 talking to a host service
over the cartridge's USB link -- that lets a human or a coding agent inspect,
modify, patch, profile and test a running Pak program on real silicon without
touching the console.

Everything below that says "already exists" has been checked against the tree
and cites the file. Everything else is unbuilt.

---

## 1. Layering

```
            human terminal  /  coding agent
                          |
                  structured host API
                          |
     host: pak compiler | symbol db | patch linker | tether daemon
                          |
                   framed binary protocol
                          |
                    SC64 USB (cartridge PI)
                          |
    N64: resident monitor -> dispatch slots -> Pak runtime + game
```

Three interfaces onto one machine. The host API is the primary one; a human
REPL is a client of the same command set, not a separate path.

The organising principle: **never make the agent infer physical reality when
the development plane can measure it.** Where a function lives, why the machine
faulted, what the screen shows, whether a patch helped -- all of it should be
answerable by asking the console rather than by reading source.

---

## 2. What already exists

Substantially more than a from-scratch plan assumes.

| Piece | State | Where |
|-------|-------|-------|
| Cartridge-space debug channel (ISViewer) | works | `runtime/standalone/runtime.pk64` ~2634 |
| PI single-word KSEG1 read/write pattern | works | `vi_read` / `vi_write`, same file |
| PI DMA (cart <-> RDRAM) | works | `dma_read` / `dma_write`, ~2108 |
| Game-installable CPU exception handler | works | `exception_set_handler`, ~2609 |
| Reserved linker-defined symbols | works | `tcl/n64link.tcl` ~345 |
| Link-time memory-map overlap check | works | `tcl/n64link.tcl` ~337 |
| Symbol table (name -> final vaddr) | works | `tcl/n64link.tcl` ~288 |
| Relocatable object format with relocs | works | `.pakobj`, `tcl/n64link.tcl` |
| Function pointers / indirect dispatch | works | `fn(A,B) -> R`, `jalr` |
| RDP command disassembler | works | `tcl/rdpdis.tcl` |
| MIPS simulator (host-side execution) | works | `tcl/mips_sim.tcl` |

Two of these carry more weight than the rest:

**ISViewer is a working one-way transport today.** Magic word at `0xB3FF0000`,
write pointer at `0xB3FF0014`, buffer from `0xB3FF0020`, all single 32-bit PI
accesses through KSEG1. It is N64 -> host only, so it cannot carry commands --
but it means symbolized crash reporting and assertion output can be built and
proven *before* any SC64-specific code is written.

**The reserved-symbol mechanism is exactly the shape the monitor needs.** The
linker already emits `__fb0`, `__zb`, `__dl_base`, `__ab`, `__heap_start`,
`__heap_end`, `__stack_top` with duplicate-definition checks. Adding
`__monitor_start`, `__patch_arena_start`/`_end` is an append to that `foreach`
list, and the existing overlap check at ~337 is where the arena's bounds check
belongs.

---

## 3. Physical constraints

These are facts about the standalone runtime, not choices. A plan that
contradicts them is wrong.

| Region | Address | Source |
|--------|---------|--------|
| Code base | `0x80000400` | `tcl/n64link.tcl:38`, `tcl/n64rom.tcl:22` |
| FB0 / FB1 / FB2 | `0xA0200000` / `0xA0225800` / `0xA024B000` | `runtime.pk64` ~101 |
| Z buffer | `0xA0271000` | same |
| Display list (8 KiB) | `0xA0297000` | `DL_BASE`, ~673 |
| Heap | `0x802A0000` -> `0x803C0000` | `HEAP_BASE` / `HEAP_LIMIT` |
| Heap ceiling w/ Expansion Pak | `0x807F0000` | `HEAP_LIMIT_EXPANDED` |
| Initial stack | `0x80400000`, growing down | `boot.S:32` |

Consequences:

- **The 256 KiB from `0x803C0000` to `0x80400000` is stack headroom, not free
  memory.** A monitor placed at `0x803E0000` sits in the stack's growth path.
- **RDRAM size is a runtime fact, not a link-time one.** `g_boot_memsize` is
  written by `boot.S` at reset from the word IPL3 leaves in RSP DMEM. The
  linker cannot choose a different layout for 4 MiB and 8 MiB consoles.
  Therefore: **place the development plane at a fixed address valid on every
  console** (below `0x80400000`) and let the heap expand upward into the
  Expansion Pak as it already does. The dev plane does not need to be in high
  memory; it needs to be at an address that does not move.
- **All cartridge MMIO must be uncached KSEG1** (`0xB...`), never KUSEG
  (`0x18000000` and friends are unmapped without TLB entries and fault on
  first touch), and must respect `pi_wait` before access.
- **The standalone backend has no RSP microcode.** It builds raw RDP command
  lists at `DL_BASE` and drives `DPC_START`/`DPC_END` directly, out of XBUS
  mode. Display-list inspection therefore means decoding **RDP** commands, not
  GBI (`SETTIMG`/`TRIFAN`/`ENDDL` are F3DEX RSP commands and do not appear).
  `tcl/rdpdis.tcl` already decodes the right thing.
- **The fault path saves no general registers.** `boot.S` saves the o32
  caller-saved set only on the *interrupt* path (~198). `.Lfault` masks
  Status (clearing IE), resets `$sp` to `0x80400000-16`, and dispatches to
  `g_exc_handler`. Capturing registers for a crash snapshot requires adding a
  save to `.Lfault`, and it must target a **fixed static buffer, not the
  stack**, because `$sp` at fault time may be the garbage that caused the
  fault. The handler also runs with interrupts off, so it must poll the
  transport in a bare spin loop.

---

## 4. Which language the monitor is written in

**Decision: Pak. Do not build a Forth.**

The monitor's actual job is a framed-protocol command dispatcher plus a patch
manager. That is not a language problem. The only part that wants a language is
the escape hatch -- "do something the command set does not cover" -- and the
hot-patch pipeline already provides one: compile a Pak function on the host,
relocate it, upload it, call it. Once `UPLOAD_BLOB` + `CALL_FUNCTION` exist,
arbitrary target-side execution exists, in the same language as the game, with
the same types, the same symbols and the same compiler.

Forth's value proposition is "interactively execute arbitrary code on a machine
that has no host compiler attached." That premise has inverted: the host has
the entire Pak toolchain on it.

Evidence that a Pak monitor is well within reach: `runtime/standalone/runtime.pk64`
is ~2600 lines of Pak already doing MMIO, PI DMA, SI/Joybus, an RDP driver and
interrupt handling. A USB FIFO driver and a command dispatcher are strictly
easier than what is already written.

What is genuinely given up, stated honestly:

| Forth advantage | Assessment |
|---|---|
| Sub-second round trip for a one-liner | Real, but matters only to a human, and a fixed command set covers most interactive poking |
| Compose new behaviour on-target without the host | Real, and unnecessary when the host is always attached |
| Independent of Pak's own codegen | Real -- a monitor compiled by the compiler it debugs shares its bugs. Mitigated by keeping the ISViewer asm path as a fallback, and `boot.S` is hand-written anyway |
| Small and auditable | A Pak monitor is comparably small |

Against those: a second language, a second ABI to document and honour, a second
mental model, a dictionary and interpreter to maintain, and a build-order
dependency in front of everything else.

**If, after using the tether, a target-resident interactive evaluator is still
wanted**, add a small RPN evaluator over the existing command primitives --
perhaps 200 lines of Pak, giving composability without a second toolchain. The
thing to skip is Forth-the-system: dictionary, compiler, immediate words,
`CREATE`/`DOES>`. Revisit from evidence, not in advance.

---

## 5. Transport: SC64

SC64 is the right cartridge for this: open-source firmware, publicly documented
USB protocol, actively maintained host tooling. Register addresses and FIFO
semantics should be taken from the sc64 project's own documentation and live in
a transport backend module, not in this note.

The transport interface the rest of the monitor sees stays small and
cart-agnostic:

```
usb_present() -> bool
usb_readable() -> i32      -- bytes available, never blocks
usb_read(buf, n) -> i32
usb_write(buf, n) -> i32
usb_reset()
```

A blocking read primitive may exist for the crash handler, which has nothing
better to do. The frame-servicing path must never block.

---

## 6. Protocol

Framed and binary. Human-readable text is a host-side rendering concern.

```
magic | version | type | request_id | length | payload | checksum
```

Responses carry `request_id`, `status`, `error_code`, `payload`.

Command set, roughly in build order:

```
PING  READ_MEMORY  WRITE_MEMORY  LOOKUP_SYMBOL  CAPTURE_FRAME
GET_CRASH  CLEAR_CRASH  READ_HW_STATE
CALL_FUNCTION  PROFILE_FUNCTION
UPLOAD_BLOB  INSTALL_PATCH  ROLLBACK_PATCH
INJECT_INPUT  STEP_FRAME  PAUSE  RESUME
RUN_TEST  SNAPSHOT
```

Servicing runs from a safe point in the main loop -- after `vi_wait_vblank()`
-- **not** from the VI interrupt handler. Commands are serviced under a bounded
budget (bytes and commands per frame) so an agent's request cannot turn a 60 fps
game into a stalled debugger.

`CAPTURE_FRAME` is the exception to the budget: 320x240x16 is 153,600 bytes and
will not fit in a per-frame quota. It should pause the game or accept a
deliberate multi-frame stall. Reading it is otherwise trivial -- the
framebuffers are at fixed, linker-exported, uncached addresses.

---

## 7. Hot patching

Pak emits position-dependent code with `R_MIPS_26` / `R_MIPS_HI16` /
`R_MIPS_LO16` relocations. A single compiled function is **not** a flat blob:
every call it makes and every global it touches is an unresolved relocation.
The host must link the patch to its destination address against the running
ROM's symbol table.

```
patch.pk64 -> pak objgen -> patch.pakobj
                                 |
                  host patch linker: --base <addr> --defsyms rom.map
                                 |
                          linked flat blob + checksum
                                 |
                    UPLOAD_BLOB -> patch arena
                                 |
              verify size / checksum / ABI / no unresolved relocs
                                 |
                  D-cache writeback-invalidate over the range
                                 |
                  I-cache invalidate over the range
                                 |
                       publish dispatch pointer  <-- last
```

Two compiler changes are needed, both contained:

- `pak::LINK_BASE_ADDR` is a fixed global (`tcl/n64link.tcl:38`). Needs
  `pak link --base <addr>`.
- The linker errors on undefined symbols. Needs `--defsyms rom.map` to resolve
  them against the resident ROM.

**The dispatch pointer is published last.** If any verification step fails the
old implementation stays live. Each installed patch records slot, generation,
previous target, new target, size and checksum, so rollback is a pointer store.

`boot.S` ~66 already does an I-cache hit-invalidate loop for its exception
trampoline -- copy that. Note the line sizes differ on the R4300i (I-cache and
D-cache are not the same); get both right.

Dispatch slots need no compiler work to begin with: a `static update_player:
fn(*Player, f32)` in Pak source *is* a slot. Compiler-emitted slot metadata is a
later convenience.

---

## 8. Determinism is a property of the game

Frame stepping, input replay, differential debugging and reproducible bug
reports all assume the program is a pure function of (initial state, input
sequence). The monitor cannot provide that. It requires a fixed timestep, a
seeded RNG, and no logic keyed off measured frame time -- properties designed
into the Pak program, painful to retrofit.

One thing that helps for free: `free()` is a no-op over a bump allocator
(`W205`), so there is no allocator-state divergence between runs -- as long as
the arena is not exhausted.

---

## 9. Build order

Ordered by value delivered per unit of work, not by architectural layering.

**Phase 1 -- ground truth**
1. `pak link --emit-map rom.map`
2. `symbols.json` from the same symbol table
3. Reserved `__monitor_*` / `__patch_arena_*` linker symbols + overlap check

**Phase 2 -- crash visibility over ISViewer (no USB work)**
4. Save general registers in `boot.S` `.Lfault` into a fixed static buffer
5. Monitor exception handler: capture EPC, Cause, Status, BadVAddr, HI/LO, regs
6. Emit the snapshot over ISViewer; symbolize host-side against `rom.map`

*At this point real-hardware crashes report as `UPDATE_PLAYER+0x34` instead of
a red screen, with zero cartridge-specific code written.*

**Phase 3 -- tether**
7. SC64 transport backend in Pak
8. Framed protocol + checksum, `PING`
9. `READ_MEMORY`, `WRITE_MEMORY`, `LOOKUP_SYMBOL`
10. `CAPTURE_FRAME` -- cheap, fixed addresses, and the single capability that
    turns "the agent is guessing" into "the agent can see". Do not defer it.

**Phase 4 -- patching**
11. `pak link --base` and `--defsyms`
12. Dispatch slots in game source
13. `UPLOAD_BLOB`, verification, cache maintenance, `INSTALL_PATCH`
14. `ROLLBACK_PATCH`

**Phase 5 -- the loop**
15. `INJECT_INPUT`, `PAUSE` / `STEP_FRAME`
16. `PROFILE_FUNCTION` (needs a small asm helper -- CP0 `Count` cannot be
    expressed in Pak)
17. Host tool API for agent use

**Deliberately deferred**: capability tiers, multi-client locking, audit logs,
region permission tags, session recording, RSP diagnostics, display-list
decode, and any resident interactive language. None of them are needed to close
the develop-test-fix loop, and several solve problems a single developer at a
single desk does not have.

---

## 10. First milestone

```
host: PING          -> N64: PONG
host: READ_MEMORY   -> known value at a known symbol
host: WRITE_MEMORY  -> a visible change on the CRT
host: CAPTURE_FRAME -> a PNG on the workstation
```

That is the whole development loop in four commands. Everything after it is
leverage.
