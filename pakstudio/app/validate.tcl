# app/validate.tcl — run pak check on generated code
# Generates into a temp dir, runs pak check, returns {ok bool, errors string}

namespace eval validate {}

proc validate::check_doc {doc} {
    set tmpdir [file join /tmp "pakstudio_validate_[pid]"]
    file mkdir $tmpdir
    codegen::write_sources $doc $tmpdir
    set result [_run_pak_check $tmpdir]
    file delete -force $tmpdir
    return $result
}

# The compiler that ships in this tree, not whatever `pak` a developer happens
# to have on PATH -- validating generated code against a different compiler
# than the one PakStudio is part of is the surprising answer, and in a fresh
# clone (or CI) there is no `pak` on PATH at all and every check reported
# "couldn't execute pak" as if the generated code were broken.
proc validate::pak_driver {} {
    set here [file dirname [file normalize [info script]]]
    set repo [file dirname [file dirname $here]]
    set driver [file join $repo bin pak]
    if {[file executable $driver]} { return $driver }
    return "pak"
}

proc validate::_run_pak_check {projdir} {
    # Collect .pk64 files
    set pkfiles [glob -nocomplain [file join $projdir src *.pk64]]
    if {[llength $pkfiles] == 0} {
        return [list ok false errors "No .pk64 files generated"]
    }
    set cmd [list [validate::pak_driver] check {*}$pkfiles]
    set rc [catch {exec {*}$cmd 2>@1} output]
    if {$rc == 0} {
        return [list ok true errors ""]
    } else {
        return [list ok false errors $output]
    }
}
