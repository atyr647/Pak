# tcl/tools/gate_corpus.tcl — the single-file programs the C-backend gates
# compile.
#
# Both compile gates (c_compile_test.tcl against stubs, libdragon_api_test.tcl
# against the real headers) used to read examples/canonical and nothing else:
# 32 files. The demos -- ai/dataset/games, examples/games, demos/ -- are the
# programs a person actually reads to learn Pak, and none of them was
# compiled by anything. When they were first compiled, 15 of 24 failed, on
# eleven distinct compiler bugs that had been live for as long as the demos
# had.
#
# Only single-file programs are listed: a multi-file project needs the whole
# `pak build` module graph, which `pak explain` on one file cannot give.
#
# Paths are repo-relative and are the key the known-broken lists use, so two
# files both called main.pk64 stay distinguishable.

namespace eval pak {}

proc pak::gate_corpus {repo} {
    set out {}
    foreach pat {
        {examples canonical *.pk64}
        {examples *.pk64}
        {examples games *.pk64}
        {examples chroma *.pk64}
        {examples baremetal *.pk64}
        {ai dataset games *.pk64}
        {demos *.pk64}
        {examples dungeon_of_types src *.pk64}
    } {
        foreach f [glob -nocomplain [file join $repo {*}$pat]] {
            lappend out [pak::gate_relpath $repo $f]
        }
    }
    # examples/invalid holds programs that must NOT compile.
    set out [lsearch -all -inline -not -glob $out "examples/invalid/*"]
    return [lsort -unique $out]
}

proc pak::gate_relpath {repo path} {
    set n [file normalize $path]
    set r [file normalize $repo]
    if {[string first "$r/" $n] == 0} { return [string range $n [expr {[string length $r]+1}] end] }
    return $n
}
