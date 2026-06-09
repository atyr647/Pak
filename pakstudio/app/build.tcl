# app/build.tcl — pak build + make pipeline
# All procs take a callback: proc {line} that receives streaming log lines.

namespace eval build {}

# Full pipeline: codegen → write files → pak build → make
# callback receives each log line as it arrives.
proc build::run {doc outdir callback} {
    # Step 1: write generated files
    {*}$callback "--- Generating Pak sources ---"
    if {[catch {codegen::write_to_dir $doc $outdir} err]} {
        {*}$callback "ERROR: $err"
        return [list ok false]
    }
    {*}$callback "  Sources written to $outdir"

    # Step 2: pak build
    {*}$callback "--- Running pak build ---"
    set r [_stream_cmd [list pak build] $outdir $callback]
    if {!$r} { return [list ok false] }

    # Step 3: make
    {*}$callback "--- Running make ---"
    set r [_stream_cmd [list make -j4] $outdir $callback]
    if {!$r} { return [list ok false] }

    # Find the .z64
    set roms [glob -nocomplain [file join $outdir build *.z64]]
    if {[llength $roms] == 0} {
        set roms [glob -nocomplain [file join $outdir *.z64]]
    }
    if {[llength $roms] > 0} {
        {*}$callback "--- Built: [lindex $roms 0] ---"
        return [list ok true rom [lindex $roms 0]]
    }
    {*}$callback "--- Build complete ---"
    return [list ok true]
}

# Run ROM in emulator (pak run)
proc build::run_rom {outdir callback} {
    {*}$callback "--- Launching emulator ---"
    _stream_cmd [list pak run] $outdir $callback
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
