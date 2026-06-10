# app/build.tcl — pak build + make pipeline
# All procs take a callback: proc {line} that receives streaming log lines.

namespace eval build {
    # Captured at source time so it resolves regardless of the caller's context.
    variable scriptdir [file dirname [file normalize [info script]]]
}

# Full pipeline: codegen → write files → build .z64.
# Prefers the bundled compat build (current libdragon + pak_compat.h shim),
# which works against the installed /opt/n64 libdragon. Falls back to the
# stock `pak build` + `make` path when the compat script/toolchain is absent.
proc build::run {doc outdir callback} {
    # Step 1: write generated files (+ copy bound assets)
    {*}$callback "--- Generating Pak sources ---"
    if {[catch {codegen::write_to_dir $doc $outdir} err]} {
        {*}$callback "ERROR: $err"
        return [list ok false]
    }
    {*}$callback "  Sources written to $outdir"

    variable scriptdir
    set script [file normalize [file join $scriptdir .. n64compat build_rom.sh]]
    set n64inst [expr {[info exists ::env(N64_INST)] && $::env(N64_INST) ne ""
                       ? $::env(N64_INST) : "/opt/n64"}]

    if {[file exists $script] && [file isdirectory $n64inst]} {
        set title [string toupper [string range [dict get $doc meta rom_title] 0 19]]
        set rom   [file join $outdir [_rom_basename $doc].z64]
        {*}$callback "--- Building ROM (libdragon: $n64inst) ---"
        set ::env(N64_INST) $n64inst
        set r [_stream_cmd [list bash $script $outdir $title $rom] $outdir $callback]
        if {$r && [file exists $rom]} {
            {*}$callback "--- Built: $rom ---"
            return [list ok true rom $rom]
        }
        {*}$callback "--- Compat build failed; trying stock pak build + make ---"
    }

    # Fallback: stock libdragon Makefile path (needs a matching libdragon).
    {*}$callback "--- Running pak build ---"
    if {![_stream_cmd [list pak build] $outdir $callback]} { return [list ok false] }
    {*}$callback "--- Running make ---"
    if {![_stream_cmd [list make -j4] $outdir $callback]} { return [list ok false] }
    set roms [glob -nocomplain [file join $outdir *.z64] [file join $outdir build *.z64]]
    if {[llength $roms] > 0} {
        {*}$callback "--- Built: [lindex $roms 0] ---"
        return [list ok true rom [lindex $roms 0]]
    }
    {*}$callback "--- Build complete ---"
    return [list ok true]
}

proc build::_rom_basename {doc} {
    set name [string tolower [dict get $doc meta name]]
    regsub -all {[^a-z0-9]+} $name "_" name
    set name [string trim $name "_"]
    if {$name eq ""} { set name "game" }
    return $name
}

# Run a built ROM in the ares emulator (falls back to `pak run`).
proc build::run_rom {outdir callback} {
    set roms [glob -nocomplain [file join $outdir *.z64] [file join $outdir build *.z64]]
    if {[llength $roms] == 0} {
        {*}$callback "ERROR: no .z64 found in $outdir — build first"
        return
    }
    set rom [lindex $roms 0]
    {*}$callback "--- Launching ares: $rom ---"
    if {[catch {exec ares $rom &} err]} {
        {*}$callback "  ares unavailable ($err); trying pak run"
        _stream_cmd [list pak run] $outdir $callback
    } else {
        {*}$callback "  ares launched"
    }
}

# Stream a command's output line-by-line into callback
proc build::_stream_cmd {cmd workdir callback} {
    set prev [pwd]
    cd $workdir
    set pipe [open "|$cmd 2>@1" r]
    fconfigure $pipe -blocking 1
    while {[gets $pipe line] >= 0} {
        {*}$callback $line
    }
    set rc [catch {close $pipe} err]
    cd $prev
    if {$rc != 0 && $err ne ""} {
        {*}$callback "ERROR: $err"
        return 0
    }
    return 1
}
