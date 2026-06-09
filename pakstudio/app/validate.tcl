# app/validate.tcl — run pak check on generated code
# Generates into a temp dir, runs pak check, returns {ok bool, errors string}

namespace eval validate {}

proc validate::check_doc {doc} {
    set tmpdir [file join /tmp "pakstudio_validate_[pid]"]
    file mkdir $tmpdir
    codegen::write_to_dir $doc $tmpdir
    set result [_run_pak_check $tmpdir]
    file delete -force $tmpdir
    return $result
}

proc validate::_run_pak_check {projdir} {
    # Collect .pk64 files
    set pkfiles [glob -nocomplain [file join $projdir src *.pk64]]
    if {[llength $pkfiles] == 0} {
        return [list ok false errors "No .pk64 files generated"]
    }
    set cmd [list pak check {*}$pkfiles]
    set rc [catch {exec {*}$cmd 2>@1} output]
    if {$rc == 0} {
        return [list ok true errors ""]
    } else {
        return [list ok false errors $output]
    }
}
