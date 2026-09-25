#!/usr/bin/env tclsh
# tcl/tools/enc_exec_test.tcl — week-3 goldens: optimizer on instruction
# records, then encode + execute.
#
# 1. peephole / delay-slot / store-never-move on synthetic records
# 2. f(a) | g(b)  == 31  on the encoded+optimized stream (caller-saved spill)
# 3. fact(5)      == 120 on the encoded+optimized stream (recursion)
# 4. sw to DPC_END (0xA4100004) is not reordered past later memory ops
# 5. encode(records) .text bytes match encode(parse_asm(records_to_asm))
#
# Run: tclsh tcl/tools/enc_exec_test.tcl

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $HERE .. parser.tcl]
source [file join $HERE .. mips_codegen.tcl]
source [file join $HERE .. optimize.tcl]
source [file join $HERE .. n64enc.tcl]
source [file join $HERE .. mips_sim.tcl]

set ::pass 0
set ::fail 0

proc ok {name cond {detail ""}} {
    if {$cond} {
        incr ::pass
        puts "ok    $name"
    } else {
        incr ::fail
        if {$detail ne ""} {
            puts "FAIL  $name\n        $detail"
        } else {
            puts "FAIL  $name"
        }
    }
}

proc check_eq {name got want} {
    if {$got eq $want} {
        incr ::pass
        puts "ok    $name = $got"
    } else {
        incr ::fail
        puts "FAIL  $name\n        got:  $got\n        want: $want"
    }
}

proc compile_records {src} {
    set lx [pak::Lexer new $src]
    set toks [$lx tokenize]
    set ast [pak::parse_tokens $toks]
    return [pak::mips_generate_records $ast]
}

proc count_nops {recs} {
    set n 0
    foreach r $recs {
        if {[lindex $r 0] eq "i" && [lindex $r 1] eq "nop"} { incr n }
    }
    return $n
}

proc filled_jal_delay {recs} {
    set n [llength $recs]
    for {set i 0} {$i < $n - 1} {incr i} {
        set a [lindex $recs $i]
        set b [lindex $recs [expr {$i + 1}]]
        if {[lindex $a 0] eq "i" && [lindex $a 1] eq "jal" \
                && [lindex $b 0] eq "i" && [lindex $b 1] ne "nop"} {
            return 1
        }
    }
    return 0
}

# Walk {i} records in .text and collect the words encode produced, skipping
# directives/labels. Used to prove the encoder consumed the optimized stream.
proc text_words {ctx} {
    set bytes [dict get $ctx secdata .text bytes]
    set words {}
    set n [llength $bytes]
    for {set i 0} {$i < $n} {incr i 4} {
        set w 0
        for {set j 0} {$j < 4} {incr j} {
            set b [expr {($i + $j) < $n ? [lindex $bytes [expr {$i + $j}]] : 0}]
            set w [expr {($w << 8) | ($b & 0xff)}]
        }
        lappend words $w
    }
    return $words
}

# ── 1. synthetic record passes ───────────────────────────────────────────────
puts "== record peephole =="

set recs {
    {d section .text}
    {label t}
    {i li {$t0} 0}
    {i move {$t1} {$t1}}
    {i li {$t2} 4}
    {i addu {$t3} {$t0} {$t2}}
    {i sw {$t3} 16($sp)}
    {i lw {$t3} 16($sp)}
}
set opt [pak::optimize_records $recs 1 0 0 0 0 0]
# li 0 -> move $t0, $zero; move $t1,$t1 dropped; li+addu -> addiu; sw+lw -> sw
set mnems {}
foreach r $opt {
    if {[lindex $r 0] eq "i"} { lappend mnems [lindex $r 1] }
}
check_eq "peephole mnemonics" $mnems {move addiu sw}

set recs {
    {d section .text}
    {label t}
    {i li {$t0} 2}
    {i li {$t1} 3}
    {i addu {$t2} {$t0} {$t1}}
}
set opt [pak::optimize_records $recs 0 0 0 0 1 0]
set found 0
foreach r $opt {
    if {$r eq {i li {$t2} 5}} { set found 1 }
}
ok "const_fold 2+3 -> li \$t2, 5" $found

puts ""
puts "== delay-slot fill =="
set recs {
    {d section .text}
    {label t}
    {i addiu {$t0} {$t0} 1}
    {i jal foo}
    {i nop}
    {i jr {$ra}}
    {i nop}
}
set opt [pak::optimize_records $recs 0 0 1 0 0 0]
set seq {}
foreach r $opt {
    if {[lindex $r 0] eq "i"} { lappend seq [lindex $r 1] }
}
check_eq "jal delay filled from prev addiu" $seq {jal addiu jr nop}

# jal writes $ra before its delay slot runs. A function's `sw $ra` right
# before its first call must stay put: moved into the slot, it saved the
# call's own return address and the function returned into itself.
set recs {
    {d section .text}
    {label t}
    {i addiu {$sp} {$sp} -32}
    {i sw {$ra} {28($sp)}}
    {i jal foo}
    {i nop}
    {i lw {$ra} {28($sp)}}
    {i addiu {$sp} {$sp} 32}
    {i jr {$ra}}
    {i nop}
}
set opt [pak::optimize_records $recs 0 0 1 0 0 0]
set seq {}
foreach r $opt {
    if {[lindex $r 0] eq "i"} { lappend seq [lindex $r 1] }
}
check_eq "sw \$ra never fills a jal delay slot" [lrange $seq 0 3] {addiu sw jal nop}

puts ""
puts "== store never moves (DPC_END) =="
# sw to DPC_END, then a load-use pair, then an independent li that the
# scheduler would like to pull into the load-use gap. The store must stay
# before the load.
set recs {
    {d section .text}
    {d globl main}
    {label main}
    {i lui {$t0} 0xA410}
    {i ori {$t0} {$t0} 4}
    {i li {$t1} 0xDEAD}
    {i sw {$t1} 0($t0)}
    {i lw {$t2} 16($sp)}
    {i addu {$t3} {$t2} {$t2}}
    {i li {$t4} 1}
    {i jr {$ra}}
    {i nop}
}
set opt [pak::optimize_records $recs]
set sw_i -1
set lw_i -1
set i 0
foreach r $opt {
    if {[lindex $r 0] eq "i" && [lindex $r 1] eq "sw"} { set sw_i $i }
    if {[lindex $r 0] eq "i" && [lindex $r 1] eq "lw"} { set lw_i $i }
    incr i
}
ok "sw still present after opt" [expr {$sw_i >= 0}]
ok "lw still present after opt" [expr {$lw_i >= 0}]
ok "sw to DPC_END stays before lw" [expr {$sw_i >= 0 && $lw_i >= 0 && $sw_i < $lw_i}]

# Encoded bytes: the sw encoding is in .text, and the lui/ori that form
# 0xA4100004 still precede it.
set ctx [pak::enc::encode $opt]
set words [text_words $ctx]
set sw_word [pak::enc::word_of {i sw {$t1} 0($t0)}]
set lui_word [pak::enc::word_of {i lui {$t0} 0xA410}]
set sw_at [lsearch -exact $words $sw_word]
set lui_at [lsearch -exact $words $lui_word]
ok "encoded sw word present" [expr {$sw_at >= 0}] "word=[format 0x%08X $sw_word]"
ok "encoded lui precedes encoded sw" [expr {$lui_at >= 0 && $sw_at > $lui_at}]

# Round-trip: encode(records) == encode(parse_asm(records_to_asm))
set asm [pak::records_to_asm $opt]
set ctx2 [pak::enc::encode [pak::enc::parse_asm $asm]]
ok "round-trip .text bytes (MMIO fixture)" \
    [expr {[dict get $ctx secdata .text bytes] eq [dict get $ctx2 secdata .text bytes]}]

# Execute: the sw must land at 0xA4100004.
set r [pak::mips_sim_run $asm main 20000]
set mw [dict get $r mem_w]
set dpc_end [expr {0xA4100004}]
set got "<unwritten>"
if {[dict exists $mw $dpc_end]} { set got [format %08X [dict get $mw $dpc_end]] }
check_eq "sim sw DPC_END" $got [format %08X 0xDEAD]

# ── 2. f(a) | g(b) == 31 ─────────────────────────────────────────────────────
puts ""
puts "== f(a) | g(b) on encoded+opt =="

set src {
fn f(x: i32) -> i32 {
    return x + 1
}
fn g(x: i32) -> i32 {
    let mut t: i32 = x
    t = t + 1
    t = t + 1
    return t
}
static sink: i32 = 0
entry {
    sink = f(10) | g(20)
}
}

set recs [compile_records $src]
set nops_before [count_nops $recs]
set opt [pak::optimize_records $recs]
set nops_after [count_nops $opt]
ok "optimizer ran (nop count did not grow)" [expr {$nops_after <= $nops_before}] \
    "before=$nops_before after=$nops_after"
ok "at least one jal delay slot filled" [filled_jal_delay $opt] \
    "nops $nops_before -> $nops_after"

# Caller-saved spill: a live temp is parked at CALL_SAVE_BASE (96) across a jal.
set spilled 0
foreach r $opt {
    if {[lindex $r 0] eq "i" && [lindex $r 1] eq "sw"} {
        set mem [lindex $r 3]
        if {[string match {96($sp)} $mem] || [string match {100($sp)} $mem] \
                || [string match {104($sp)} $mem]} {
            set spilled 1
        }
    }
}
ok "caller-saved spill around call (sw N(\$sp) at CALL_SAVE_BASE)" $spilled

set ctx [pak::enc::encode $opt]
ok "encode produces .text" [expr {[llength [dict get $ctx secdata .text bytes]] > 0}]
set asm [pak::records_to_asm $opt]
set ctx2 [pak::enc::encode [pak::enc::parse_asm $asm]]
ok "round-trip .text bytes (or-calls)" \
    [expr {[dict get $ctx secdata .text bytes] eq [dict get $ctx2 secdata .text bytes]}]

set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
# Data lives at DATA_BASE (0x80300000) in the simulator. sink is the first
# .data word of a program whose only static is sink.
set sink_got "<unwritten>"
dict for {addr val} $mw {
    # Skip stack / MMIO; take the first store into the data window.
    if {$addr >= 0x80300000 && $addr < 0x80301000} {
        set sink_got [expr {$val}]
        break
    }
}
check_eq "f(10)|g(20) == 31" $sink_got 31

# ── 3. fact(5) == 120 ────────────────────────────────────────────────────────
puts ""
puts "== n * fact(n-1) on encoded+opt =="

set src {
fn fact(n: i32) -> i32 {
    if n <= 1 {
        return 1
    }
    return n * fact(n - 1)
}
static sink: i32 = 0
entry {
    sink = fact(5)
}
}

set recs [compile_records $src]
set opt [pak::optimize_records $recs]
ok "fact: jal delay filled" [filled_jal_delay $opt]

set ctx [pak::enc::encode $opt]
set asm [pak::records_to_asm $opt]
set ctx2 [pak::enc::encode [pak::enc::parse_asm $asm]]
ok "round-trip .text bytes (fact)" \
    [expr {[dict get $ctx secdata .text bytes] eq [dict get $ctx2 secdata .text bytes]}]

set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set sink_got "<unwritten>"
dict for {addr val} $mw {
    if {$addr >= 0x80300000 && $addr < 0x80301000} {
        set sink_got [expr {$val}]
        break
    }
}
check_eq "fact(5) == 120" $sink_got 120

# ── 4. `and` / `or` short-circuit ───────────────────────────────────────────
# The right side must not run once the left side decides the result -- in a
# condition and as a value. Both sides used to be evaluated unconditionally,
# so `p? and p.x > 0` read through a null pointer.
puts ""
puts "== and/or short-circuit =="

set src {
static calls: i32 = 0
static out: i32 = 0
fn bump() -> i32 {
    calls += 1
    return 1
}
entry {
    let zero: i32 = 0
    let one: i32 = 1
    if zero == 1 and bump() == 1 { out = out + 1 }
    if one == 1 or bump() == 1 { out = out + 10 }
    let v: bool = zero == 1 and bump() == 1
    if v { out = out + 100 }
    let w: bool = one == 1 or bump() == 1
    if w { out = out + 1000 }
    if one == 1 and bump() == 1 { out = out + 10000 }
}
}
set run [pak::mips_sim_run [pak::records_to_asm [pak::optimize_records [compile_records $src]]] main 200000]
set syms [dict get $run data_syms]
set mw [dict get $run mem_w]
proc word_at {mw addr} { if {[dict exists $mw $addr]} { return [dict get $mw $addr] }; return 0 }
check_eq "short-circuit: branches taken" [word_at $mw [dict get $syms out]] 11010
check_eq "short-circuit: bump() ran only where it decides" [word_at $mw [dict get $syms calls]] 1

# ── 5. a call with more than 16 argument slots widens its own frame ────────
# marshal_args spills argument N (N>=4) to $sp+(N-4)*4+16 -- the O32
# outgoing-argument area. That area used to stop at a hardcoded 64 bytes
# (12 extra args, 16 total) regardless of how many a call actually had, so
# argument 16's write (offset 64) landed on the same address as the
# register allocator's own first spill slot. A 20-argument call is 22 slots
# once the +2 safety margin for an implicit self/sret is added, so it must
# widen spill_base (and everything stacked above it) instead of leaving the
# two aliased.
puts ""
puts "== wide call (>16 argument slots) widens its own frame =="
set wide_src {
fn wide20(a0: i32, a1: i32, a2: i32, a3: i32, a4: i32, a5: i32, a6: i32, a7: i32,
          a8: i32, a9: i32, a10: i32, a11: i32, a12: i32, a13: i32, a14: i32,
          a15: i32, a16: i32, a17: i32, a18: i32, a19: i32) -> i32 {
    return a16 + a17 + a18 + a19
}
static out: i32 = 0
entry {
    out = wide20(0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19)
}
}
set wide_recs [compile_records $wide_src]
set wide_max_store_off -1
set wide_frame_size -1
set in_main 0
foreach r $wide_recs {
    if {[lindex $r 0] eq "label" && ![string match .L* [lindex $r 1]]} {
        set in_main [expr {[lindex $r 1] eq "main"}]
    }
    if {!$in_main || [lindex $r 0] ne "i"} continue
    if {[lindex $r 1] eq "addiu" && [lindex $r 2] eq {$sp} && [lindex $r 3] eq {$sp} \
            && [lindex $r 4] < 0} {
        set wide_frame_size [expr {-[lindex $r 4]}]
    }
    # Only the outgoing-argument writes: `sw $tN, off($sp)` for a temp/arg
    # register, not $ra/$fp/a callee-saved register's own prologue slot.
    if {[lindex $r 1] eq "sw" && [lindex $r 2] in $::pak::CALLER_SAVED_GPRS \
            && [regexp {^(\d+)\(\$sp\)$} [lindex $r 3] -> off]} {
        if {$off > $wide_max_store_off} { set wide_max_store_off $off }
    }
}
ok "wide call: frame widened past the hardcoded 144" [expr {$wide_frame_size > 144}] \
    "  frame_size=$wide_frame_size"
# The widest outgoing-argument write (argument 19, offset 76) must not reach
# into whatever this function's own frame stacks above the outgoing-arg
# area (the old hardcoded scheme put a register-allocator spill slot at
# exactly offset 64, colliding with argument 16's write).
ok "wide call: outgoing-arg store stays inside its own area" \
    [expr {$wide_max_store_off <= 76}] "  max_store_off=$wide_max_store_off"

set run [pak::mips_sim_run [pak::records_to_asm [pak::optimize_records $wide_recs]] main 200000]
set syms [dict get $run data_syms]
set mw [dict get $run mem_w]
check_eq "wide call: callee sums its last 4 of 20 args (16+17+18+19)" \
    [word_at $mw [dict get $syms out]] 70

# ── 6. a user `goto`/`label` doesn't fool the dataflow pass's per-function
# chunking ───────────────────────────────────────────────────────────────
# opt_dataflow.tcl used to split the record stream into one chunk per
# function by looking for "a label not prefixed with .L" -- every label
# MipsCodegen generates for its own control flow IS .L-prefixed, so that
# stood in for "a real function's own name label" as long as nothing else
# used a bare label. A user's own `goto`/`label` (LANGUAGE.md,
# "[IMPLEMENTED]") is exactly such a bare label sitting INSIDE a function,
# not a new one, and used to split liveness analysis right there --
# corrupting any value assigned before the `goto` and read only after its
# target. tcl/opt_inline.tcl's leaf-function inliner produces exactly this
# shape (every `return` becomes `<result> = <value>; goto <end>`), which is
# how this was actually found: two inlined calls to the same tiny function,
# back to back, silently dropped the second call's result to 0 under full
# optimization even though the unoptimized build and the simulator-checked
# AST were both correct.
puts ""
puts "== user goto/label survives dataflow's per-function chunking =="
set goto_src {
fn rdp_ch(c: u32, sh: u32) -> i32 {
    return (((c >> sh) & 0xFF) as i32) << 16
}
static out_ra: i32 = 0
static out_ga: i32 = 0
entry {
    let ca: u32 = 0xAABBCCDD
    let ra: i32 = rdp_ch(ca, 24)
    let ga: i32 = rdp_ch(ca, 16)
    out_ra = ra
    out_ga = ga
}
}
set goto_recs [compile_records $goto_src]
set goto_run [pak::mips_sim_run [pak::records_to_asm [pak::optimize_records $goto_recs]] main 200000]
set goto_syms [dict get $goto_run data_syms]
set goto_mw [dict get $goto_run mem_w]
check_eq "goto/label: first inlined call's result (0xAA0000)" \
    [word_at $goto_mw [dict get $goto_syms out_ra]] 11141120
check_eq "goto/label: second inlined call's result doesn't get dropped to 0 (0xBB0000)" \
    [word_at $goto_mw [dict get $goto_syms out_ga]] 12255232

# ── 7. inlining a call whose callee's own body is spliced into a struct
# literal's argument doesn't corrupt the struct literal's OWN fields ──────
# tcl/opt_inline.tcl's AST rename pass used to flatten any nested seq whose
# rewritten result "looked like" a seq -- meant only for a `return` turning
# into two sibling statements (`<result> = <value>; goto <end>`), which is
# the only case that ever needs to splice more than one sibling in. But
# StructLit.fields is ALSO a seq of nested {name, value} pairs, and the same
# over-eager flattening spread each pair's two elements directly into the
# outer fields list, corrupting the struct's shape and silently dropping
# both field values (they end up zero-initialized and never written).
# Found via a real case (t3d_look_at's `Vec3 { x: 0.0, y: 1.0, z: 0.0 }`
# inside an inlined wrapper), reduced to this.
puts ""
puts "== inlining doesn't corrupt a struct literal's own field values =="
set structlit_src {
struct Pair { a: i32, b: i32 }
fn sum_pair(p: *Pair) -> i32 {
    let x: i32 = p.a
    let y: i32 = p.b
    let z: i32 = x + y
    let w: i32 = z + x
    let v: i32 = w + y
    let u: i32 = v + z
    let t: i32 = u + w
    return t
}
fn wrapper(out: *i32) {
    let pair: Pair = Pair { a: 3, b: 4 }
    let r: i32 = sum_pair(&pair)
    *out = r
}
static result: i32 = 0
entry {
    wrapper(&result)
}
}
set structlit_recs [compile_records $structlit_src]
set structlit_run [pak::mips_sim_run [pak::records_to_asm [pak::optimize_records $structlit_recs]] main 200000]
set structlit_syms [dict get $structlit_run data_syms]
set structlit_mw [dict get $structlit_run mem_w]
check_eq "struct literal fields survive an inlined wrapper (3+4+... = 31)" \
    [word_at $structlit_mw [dict get $structlit_syms result]] 31

# ── 8. opt_dataflow.tcl's copy/constant propagation runs real forward
# dataflow over the function's basic-block CFG instead of resetting
# everything at every label ─────────────────────────────────────────────
# The single linear pass this replaced forgot every known copy/constant at
# ANY label, including a plain join point after an if/else -- so a value
# both arms left at the same known constant was still read back through
# a register the join point had no idea was constant. Real per-block
# dataflow (propagate's own in-state is now the meet of every predecessor
# block's out-state, exactly like dce's liveness already was) sees that
# join point as knowing the constant, same as it should.
puts ""
puts "== copy/constant propagation crosses a real block join =="
set join_src {
static out: i32 = 0
entry {
    let n: i32 = 5
    let mut x: i32 = 0
    if n > 3 {
        x = 7
    } else {
        x = 7
    }
    out = x + 2
}
}
set join_recs [compile_records $join_src]
set join_opt [pak::optimize_records $join_recs]
set join_run [pak::mips_sim_run [pak::records_to_asm $join_opt] main 200000]
set join_syms [dict get $join_run data_syms]
set join_mw [dict get $join_run mem_w]
check_eq "both if/else arms agreeing on a constant: out = 7+2" \
    [word_at $join_mw [dict get $join_syms out]] 9
# The two arms' own `x = 7` assignments become fully dead (the join reads
# the constant directly) only once the join point actually knows it --
# proof this exercised the cross-block path, not just gotten the right
# answer some other way.
set join_li7 0
foreach r $join_opt {
    if {[lindex $r 0] eq "i" && [lindex $r 1] eq "li" && [lindex $r 3] == 7} { incr join_li7 }
}
check_eq "the constant survives as exactly one shared li, not one per arm" $join_li7 1

# ── 9. ...and the meet across predecessors is a real intersection: two
# arms that do NOT agree must not let one arm's fact leak into the other's
# ───────────────────────────────────────────────────────────────────────
# A block reached from two predecessors takes the state of the LAST one
# processed unless the merge is a genuine intersection. Tcl doesn't help:
# an empty dict and "" print identically, so a naive "have I seen the
# first predecessor yet" check written as `$state eq ""` cannot tell "no
# predecessor visited yet" apart from "the first predecessor legitimately
# knew nothing" -- and silently lets every later predecessor overwrite
# instead of merge. Two if/else pairs with DIFFERENT constants on each
# arm, one exercised each direction, catch exactly that: get it wrong and
# at least one of these reads back the other arm's value instead of its
# own.
puts ""
puts "== the block-join meet is a real intersection, not last-writer-wins =="
set nomerge_src {
static out_then: i32 = 0
static out_else: i32 = 0
entry {
    let n: i32 = 5
    let mut x: i32 = 0
    if n > 3 {
        x = 7
    } else {
        x = 99
    }
    out_then = x + 2

    let m: i32 = 1
    let mut y: i32 = 0
    if m > 3 {
        y = 7
    } else {
        y = 99
    }
    out_else = y + 2
}
}
set nomerge_recs [compile_records $nomerge_src]
set nomerge_run [pak::mips_sim_run [pak::records_to_asm [pak::optimize_records $nomerge_recs]] main 200000]
set nomerge_syms [dict get $nomerge_run data_syms]
set nomerge_mw [dict get $nomerge_run mem_w]
check_eq "the taken-then-arm's own value survives (7+2)" \
    [word_at $nomerge_mw [dict get $nomerge_syms out_then]] 9
check_eq "the taken-else-arm's own value survives (99+2), not the other arm's" \
    [word_at $nomerge_mw [dict get $nomerge_syms out_else]] 101

# ── 10. a loop's back-edge can't leave the pre-loop constant standing ────
# A value known constant only going INTO a loop, and redefined by the loop
# body itself every iteration, must not still read as that pre-loop
# constant after the back edge -- the fixpoint has to actually reach the
# loop header's real (non-constant) in-state, not stop after the first,
# not-yet-looped-back pass.
puts ""
puts "== a loop back-edge invalidates a pre-loop constant, doesn't keep it =="
set loop_src {
static total: i32 = 0
entry {
    let mut sum: i32 = 5
    let mut i: i32 = 0
    loop {
        i += 1
        sum = sum + i
        if i >= 5 { break }
    }
    total = sum
}
}
set loop_recs [compile_records $loop_src]
set loop_run [pak::mips_sim_run [pak::records_to_asm [pak::optimize_records $loop_recs]] main 200000]
set loop_syms [dict get $loop_run data_syms]
set loop_mw [dict get $loop_run mem_w]
check_eq "5 + (1+2+3+4+5) over the loop's back edge" \
    [word_at $loop_mw [dict get $loop_syms total]] 20

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
