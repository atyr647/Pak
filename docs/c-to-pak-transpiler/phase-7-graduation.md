# Phase 7: Graduation & Real-World Validation

Goal: prove the transpiler works on real-world C codebases, not just hand-crafted test inputs.

## 7.1 — Target Projects

### Tier 1: Libdragon Examples (Clean C, Known APIs)

Convert the official libdragon example programs:

| Example | Key Features Exercised |
|---------|----------------------|
| `spritemap` | Sprite loading, controller input, display loop |
| `rdpqdemo` | RDP drawing, fill rectangles, mode switching |
| `audioplayer` | Audio init, WAV playback, mixer |
| `timer` | Timer init, delta time, ticks |

**Success criteria**: Transpiled PAK compiles and produces identical runtime behavior.

### Tier 2: Small Homebrew Games (Real Game Logic)

Convert small, complete N64 homebrew games:

| Project | Complexity | Key Challenges |
|---------|-----------|----------------|
| Neon64 (NES emulator) | High | Heavy bitwise ops, memory mapping, state machines |
| Controllertest | Low | Clean API usage, good first test |
| N64brew jam entries | Medium | Varied coding styles, game logic |

**Success criteria**: Transpiled PAK compiles. Core game logic runs correctly (some
hardware-specific edge cases may need manual fixup).

### Tier 3: Decompilation Projects (Large Scale, Complex C)

The ultimate goal — converting decomp output to PAK:

| Project | Files | Lines of C | Key Challenges |
|---------|-------|-----------|----------------|
| SM64 decomp | ~400 | ~200k | Actor system, behavior scripts, math lib |
| OoT decomp | ~800 | ~500k | Actor hierarchy, z64 types, overlays |
| MM decomp | ~600 | ~400k | Similar to OoT + transformation system |
| DK64 decomp | ~300 | ~150k | Object system, screen transitions |

**Success criteria for Tier 3**: The transpiler handles 80%+ of files without errors.
Remaining 20% have clear `// c2pak:` annotations marking what needs manual attention.
The converted code compiles after reasonable human intervention (<1 hour per 1000 LOC).

## 7.2 — Validation Strategy

### Automated Pipeline

```
for each .c file in project:
    1. pak convert file.c -o file.pk64 --decomp
    2. pak check file.pk64            # parse + type-check
    3. Record: PASS / PARSE_FAIL / TYPE_FAIL / CONVERT_FAIL
    4. If PASS: pak build file.pk64 --backend mips
    5. Record: BUILD_PASS / BUILD_FAIL
```

### Metrics Dashboard

Track per-project:

| Metric | Target |
|--------|--------|
| **Conversion rate** | % of .c files that produce valid .pk64 | ≥90% |
| **Parse rate** | % of .pk64 files that parse without errors | ≥95% |
| **Type-check rate** | % of .pk64 files that type-check | ≥85% |
| **Build rate** | % of .pk64 files that compile to MIPS | ≥80% |
| **Idiom hit rate** | % of tagged unions correctly detected | ≥70% |
| **Comment preservation** | % of comments retained | ≥80% |
| **Manual fixup ratio** | Lines manually edited / total lines | ≤5% |

### Differential Testing (Behavioral)

For Tier 1 and Tier 2 projects where both C and PAK can be compiled:

1. Compile original C via GCC → N64 ROM.
2. Compile transpiled PAK → N64 ROM.
3. Run both in headless emulator with scripted input.
4. Diff: frame checksums, debug output, memory state.

## 7.3 — Known Hard Problems

Issues that will require ongoing iteration:

### 1. Macro-Heavy Code

Some decomp code is 30%+ macros. The preprocessor (Phase 4) handles simple cases, but
complex multi-level macro expansion with token pasting (`##`) and stringification (`#`) may
require falling back to `gcc -E` expansion.

### 2. Void Pointer Gymnastics

Decomp code frequently casts `void *` to specific types:
```c
Actor *actor = (Actor *)((u8 *)node + 0x14C);
```
The transpiler can't always infer the correct PAK type. Emit with a `// c2pak: verify cast`
annotation.

### 3. Computed Gotos / Switch on Function Pointer Tables

Some decomps use computed gotos or function pointer tables for behavior dispatch:
```c
void (*behaviors[])(Actor *) = { bhv_idle, bhv_walk, bhv_attack };
behaviors[state](actor);
```
Convert to `match` on state with explicit function calls, or preserve as function pointer
array.

### 4. Bitfield-Heavy Structs

Many decomp structs use bit-fields extensively:
```c
struct Flags {
    u32 visible : 1;
    u32 active : 1;
    u32 damage_type : 4;
    u32 hp : 8;
};
```
PAK has no bit-fields. Convert to manual masking with helper functions and clear comments.

### 5. Overlays / Dynamic Loading

N64 games use overlays (code loaded at runtime to a fixed address). This is an OS-level
concept that PAK doesn't directly model. Convert overlay code to regular modules with
`// c2pak: was overlay` annotations.

## 7.4 — Graduation Criteria

The C-to-PAK transpiler can be considered production-ready when ALL of the following hold:

1. **Tier 1 complete**: All libdragon example programs transpile and produce identical
   runtime behavior.
2. **Tier 2 functional**: At least 3 small homebrew games transpile and run with ≤5%
   manual fixup.
3. **Tier 3 viable**: SM64 decomp transpiles with ≥80% file success rate. A complete
   level (Bob-omb Battlefield) runs correctly after manual cleanup.
4. **Output quality**: A survey of 5+ developers rates the transpiled PAK as "readable
   and maintainable" (≥7/10).
5. **Test suite**: ≥200 test cases covering all C construct mappings, with ≥90% code
   coverage of `pak/c2pak/`.
6. **Performance**: Transpilation of 10k LOC C completes in under 30 seconds.
7. **Documentation**: User guide with examples, known limitations, and manual fixup
   patterns.

## 7.5 — Post-Graduation Roadmap

Once graduation criteria are met:

- **C++ subset support**: Handle simple C++ features used in some homebrew (classes →
  struct + impl, namespaces → modules, references → pointers).
- **Interactive mode**: TUI that shows C and PAK side-by-side, letting the user approve
  or modify each conversion.
- **LSP integration**: IDE support for "convert this C file to PAK" as a code action.
- **Bidirectional sync**: Keep C and PAK in sync during incremental migration (convert
  changed functions only).
