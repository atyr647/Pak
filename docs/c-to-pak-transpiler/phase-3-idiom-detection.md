# Phase 3: Idiom Detection & PAK-ification

Goal: go beyond mechanical translation and recognize C patterns that map to richer PAK
constructs. This is what makes the transpiler output feel like idiomatic PAK rather than
"C with different syntax."

## 3.1 — Tagged Union → Variant

The highest-value pattern. N64 decomps are full of tagged unions.

### Detection Criteria

1. A struct contains a field of enum type (the **tag**).
2. The struct contains a `union` (the **payload**).
3. The union members are structs (or single fields) corresponding to enum values.
4. `switch` statements on the tag field dispatch to case-specific code.

### Example

```c
// C — tagged union pattern
typedef enum { ACTOR_PLAYER, ACTOR_ENEMY, ACTOR_NPC, ACTOR_NONE } ActorType;
typedef struct {
    ActorType type;
    Vec3 pos;
    union {
        struct { int hp; int mp; Inventory inv; } player;
        struct { int hp; AIState ai; } enemy;
        struct { int dialogue_id; } npc;
    };
} Actor;

void update_actor(Actor *a) {
    switch (a->type) {
        case ACTOR_PLAYER: handle_player(&a->player); break;
        case ACTOR_ENEMY:  handle_enemy(&a->enemy); break;
        case ACTOR_NPC:    handle_npc(&a->npc); break;
        case ACTOR_NONE:   break;
    }
}
```

→

```pak
variant Actor {
    player { pos: Vec3, hp: i32, mp: i32, inv: Inventory }
    enemy { pos: Vec3, hp: i32, ai: AIState }
    npc { pos: Vec3, dialogue_id: i32 }
    none { pos: Vec3 }
}

fn update(self: *mut Actor) {
    match *self {
        .player(p) => { handle_player(&p) }
        .enemy(e) => { handle_enemy(&e) }
        .npc(n) => { handle_npc(&n) }
        .none => {}
    }
}
```

### Shared Fields Handling

When the struct has fields outside the union (like `pos` above), two strategies:

- **Strategy A — Duplicate into each variant case**: Each variant case gets a copy of the
  shared fields. Simplest, works when shared fields are small.
- **Strategy B — Separate struct + variant**: Extract shared fields into a wrapper struct
  that contains the variant. Better for large shared data.

Default to Strategy A for decomp code (matches how decomps think about actors).

### Edge Cases

- Tag field not named `type` — detect by: field is an enum type, and the struct also
  contains a union. Use heuristics: common names (`type`, `kind`, `tag`, `id`).
- Tag enum values don't map 1:1 to union fields — emit raw `union` with a comment.
- Nested tagged unions — handle recursively.

## 3.2 — Method Detection → impl Blocks

### Detection Criteria

1. Function name starts with `structname_` (e.g., `player_init`, `vec2_add`).
2. First parameter is `StructName *` (or `const StructName *`).
3. Multiple functions share the same prefix for the same struct.

### Example

```c
void player_init(Player *p, Vec2 pos, int hp);
void player_take_damage(Player *p, int dmg);
int  player_is_alive(const Player *p);
Vec2 player_get_pos(const Player *p);
```

→

```pak
impl Player {
    fn init(self: *mut Player, pos: Vec2, hp: i32) { ... }
    fn take_damage(self: *mut Player, dmg: i32) { ... }
    fn is_alive(self: *Player) -> bool { ... }
    fn get_pos(self: *Player) -> Vec2 { ... }
}
```

### Rules

- Strip the struct prefix from the function name: `player_take_damage` → `take_damage`.
- `const StructName *` → `self: *Player` (immutable pointer).
- `StructName *` → `self: *mut Player` (mutable pointer).
- Group all methods for the same struct into one `impl` block.
- Functions that take a struct pointer but don't follow the naming convention: leave as
  free functions (don't force into impl).

## 3.3 — Fixed-Point Arithmetic Detection

N64 decomps heavily use fixed-point math represented as plain integer operations with
explicit shifts.

### Detection Criteria

- Integer multiply followed by right-shift: `(a * b) >> 16` → fixed-point multiply.
- Integer left-shift before divide: `(a << 16) / b` → fixed-point divide.
- Constants that are powers of 2 used as fractional scaling: `65536`, `1024`, `32768`.
- Typedef names containing `fix`, `q16`, `fixed`, `frac`.

### Example

```c
typedef int32_t fix16;
#define FIX16_ONE 65536
#define INT_TO_FIX16(x) ((x) << 16)
#define FIX16_MUL(a, b) ((int32_t)(((int64_t)(a) * (b)) >> 16))

fix16 velocity = INT_TO_FIX16(5);
fix16 friction = 62259;  // 0.95 in Q16.16
fix16 new_vel = FIX16_MUL(velocity, friction);
```

→

```pak
let velocity: fix16.16 = 5 as fix16.16
let friction: fix16.16 = 0.95 as fix16.16
let new_vel: fix16.16 = velocity * friction
```

### Detection Levels

1. **Typedef-based** (easy): Recognize `fix16`, `Fixed`, `Q16`, `s16_16` typedefs → map to
   PAK's `fix16.16` / `fix10.5` / `fix1.15`.
2. **Macro-based** (medium): Recognize `FIX_MUL`, `FIX_DIV`, `INT_TO_FIX` macros → replace
   with native PAK fixed-point operations.
3. **Pattern-based** (hard): Recognize raw shift patterns `(a * b) >> 16` without any naming
   hints. Only enable with `--decomp` flag to avoid false positives.

## 3.4 — Error Pattern → Result Type

### Detect Sentinel Return Patterns

```c
int load_file(const char *path, Buffer *out) {
    FILE *f = fopen(path, "rb");
    if (f == NULL) return -1;  // error sentinel
    // ... read into out ...
    fclose(f);
    return 0;  // success
}

// Call site:
int err = load_file("data.bin", &buf);
if (err != 0) { handle_error(); }
```

→

```pak
fn load_file(path: *i8, out: *mut Buffer) -> Result(void, i32) {
    let f = fopen(path, "rb")
    if f == none { return err(-1) }
    // ... read into out ...
    fclose(f)
    return ok(())
}

// Call site:
load_file("data.bin", &mut buf) catch e => { handle_error() }
```

### Detection Criteria

- Function returns `int` and call sites check `!= 0`, `< 0`, or `== -1`.
- Function returns `NULL` for pointers — convert to `?T` (Option type).
- Common patterns: `errno` usage, output-parameter style (`int func(T *out)`).

Only apply when confidence is high. Mark uncertain conversions with `// c2pak: check this`.

## 3.5 — Goto Cleanup → Defer

### Detection Criteria

The classic C cleanup pattern:

```c
int do_work(void) {
    char *buf = malloc(1024);
    if (!buf) return -1;

    FILE *f = fopen("data", "r");
    if (!f) goto cleanup_buf;

    // ... work ...
    fclose(f);
cleanup_buf:
    free(buf);
    return result;
}
```

→

```pak
fn do_work() -> Result(i32, i32) {
    let buf = alloc([1024]u8)
    defer { free(buf) }

    let f = fopen("data", "r")
    if f == none { return err(-1) }
    defer { fclose(f) }

    // ... work ...
    return ok(result)
}
```

### Detection Criteria

1. `goto` targets a label at the end of the function.
2. The label section contains only cleanup code (`free`, `close`, `release`, etc.).
3. Multiple `goto`s point to the same cleanup label (or a chain of labels).

Convert to `defer` statements placed immediately after resource acquisition.

## 3.6 — Array + Length → Slice

```c
void process(int *data, int count) {
    for (int i = 0; i < count; i++) {
        data[i] *= 2;
    }
}
```

→

```pak
fn process(data: []mut i32) {
    for i in 0..data.len {
        data[i] *= 2
    }
}
```

### Detection Criteria

- Adjacent function parameters `(T *arr, int len)` or `(T *arr, int count, ...)` where
  `len`/`count` is used as the loop bound for iterating over `arr`.
- Merge into a single PAK slice parameter `arr: []T`.

## 3.7 — String Patterns

```c
const char *msg = "hello";
char buf[64];
snprintf(buf, sizeof(buf), "score: %d", score);
strlen(s);
strcmp(a, b) == 0;
```

→

```pak
let msg: *i8 = "hello"
// snprintf → keep as extern call (PAK has no format strings natively)
// strlen, strcmp → keep as extern calls
```

String handling is mostly pass-through since PAK uses C-style strings (`*i8`). No special
idiom detection needed beyond recognizing `NULL`-terminated string conventions.

## 3.8 — Milestone Test

A C file containing:
- A tagged union with 3+ variants and a switch dispatching on the tag.
- A set of `structname_method()` functions.
- Fixed-point arithmetic with explicit shifts.
- A `goto cleanup` pattern.
- An array+length parameter pair.

The transpiler should produce a `.pk64` file using `variant`, `impl`, `fix16.16`, `defer`,
and `[]T` slices — not a mechanical line-by-line translation.
