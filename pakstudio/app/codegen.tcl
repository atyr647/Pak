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

# Write generated source files (.pk64 + pak.toml) into outdir. No assets — safe
# for validation, which only needs the Pak source.
proc codegen::write_sources {doc outdir} {
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

# Full build write: sources + bound asset files. Used by the build pipeline.
proc codegen::write_to_dir {doc outdir} {
    set keys [write_sources $doc $outdir]
    copy_assets $doc $outdir
    return $keys
}

# Copy bound asset source files into the build tree at the paths the generated
# `asset ... from "..."` declarations expect:
#   sprites/<role>.png   audio/<role>.wav (sfx)   audio/music.xm (music)
# Returns a list of human-readable copy descriptions. Missing sources raise.
proc codegen::copy_assets {doc outdir} {
    if {![dict exists $doc assets]} { return {} }
    set copied {}
    if {[dict exists $doc assets sprites]} {
        dict for {role src} [dict get $doc assets sprites] {
            if {$src eq ""} continue
            if {![file exists $src]} {
                error "Sprite asset for '$role' not found: $src"
            }
            set dst [file join $outdir sprites ${role}.png]
            file mkdir [file dirname $dst]
            file copy -force $src $dst
            lappend copied "sprites/${role}.png <- $src"
        }
    }
    if {[dict exists $doc assets audio]} {
        dict for {role src} [dict get $doc assets audio] {
            if {$src eq ""} continue
            if {![file exists $src]} {
                error "Audio asset for '$role' not found: $src"
            }
            if {$role eq "music"} {
                set dst [file join $outdir audio music.xm]
                set rel "audio/music.xm"
            } else {
                set dst [file join $outdir audio ${role}.wav]
                set rel "audio/${role}.wav"
            }
            file mkdir [file dirname $dst]
            file copy -force $src $dst
            lappend copied "$rel <- $src"
        }
    }
    return $copied
}
