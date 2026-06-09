# app/codegen.tcl — genre dispatcher: .pakstudio doc → {path content} dict
# Writes nothing itself; caller writes the returned files.

namespace eval codegen {}

proc codegen::generate {doc} {
    set genre [dict get $doc meta genre]
    switch $genre {
        platformer { return [codegen::platformer::generate $doc] }
        topdown    { error "Genre 'topdown' not yet implemented" }
        shmup      { error "Genre 'shmup' not yet implemented" }
        default    { error "Unknown genre: $genre" }
    }
}

# Write all generated files into outdir, creating subdirs as needed.
proc codegen::write_to_dir {doc outdir} {
    set files [generate $doc]
    dict for {relpath content} $files {
        set abspath [file join $outdir $relpath]
        file mkdir [file dirname $abspath]
        set f [open $abspath w]
        puts -nonewline $f $content
        close $f
    }
    return [dict keys $files]
}
