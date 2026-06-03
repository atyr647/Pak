# tcl/cli.tcl — Pak command-line interface, Tcl port of pak/cli.py.
# Drives the Tcl compiler stages + headergen/makefile_gen/pakfs to build a
# project, byte-exact with the Python `pak` CLI on the compilation artifacts.

set _clihere [file dirname [file normalize [info script]]]
source [file join $_clihere parser.tcl]
source [file join $_clihere codegen.tcl]
source [file join $_clihere typechecker.tcl]
source [file join $_clihere checker.tcl]
source [file join $_clihere headergen.tcl]
source [file join $_clihere makefile_gen.tcl]
source [file join $_clihere pakfs.tcl]
source [file join $_clihere mips_codegen.tcl]
source [file join $_clihere optimize.tcl]
source [file join $_clihere n64enc.tcl]

namespace eval pak {}
set ::pak::CLI_ROOT [file normalize [file join $_clihere ..]]

# ── Minimal TOML parser (pak.toml subset: [section], key = scalar, # comments) ─
proc pak::toml_parse {text} {
    set result [dict create]
    set section ""
    foreach line [split $text "\n"] {
        set t [string trim $line]
        if {$t eq "" || [string index $t 0] eq "#"} continue
        if {[regexp {^\[([^\]]+)\]$} $t -> sec]} {
            set section $sec
            if {![dict exists $result $section]} { dict set result $section [dict create] }
            continue
        }
        if {[regexp {^([A-Za-z0-9_]+)\s*=\s*(.+)$} $t -> key val]} {
            set val [string trim $val]
            # strip trailing comment outside quotes (simple: only if not quoted)
            if {[string index $val 0] eq "\""} {
                regexp {^"([^"]*)"} $val -> v
            } elseif {$val eq "true"} { set v 1 } \
            elseif {$val eq "false"} { set v 0 } \
            else { set v $val }
            if {$section eq ""} { dict set result $key $v } else {
                dict set result $section $key $v
            }
        }
    }
    return $result
}
proc pak::cfg_get {config section key default} {
    if {[dict exists $config $section $key]} { return [dict get $config $section $key] }
    return $default
}

# ── Project helpers ───────────────────────────────────────────────────────────
proc pak::cli_find_project_root {{start ""}} {
    if {$start eq ""} { set start [pwd] }
    set current [file normalize $start]
    while {$current ne [file dirname $current]} {
        if {[file exists [file join $current pak.toml]]} { return $current }
        set current [file dirname $current]
    }
    return ""
}
proc pak::cli_runtime_dir {} { return [file join $::pak::CLI_ROOT runtime] }

# Recursive *.pk64 glob, excluding any path with a 'build' component, sorted.
proc pak::cli_src_files {root} {
    set out {}
    foreach f [pak::_rglob $root *.pk64] {
        set rel [pak::_relto $f $root]
        if {[lsearch -exact [file split $rel] build] >= 0} continue
        lappend out $f
    }
    return [lsort $out]
}
proc pak::_rglob {dir pattern} {
    set found {}
    foreach item [lsort [glob -nocomplain -directory $dir *]] {
        if {[file isdirectory $item]} {
            foreach sub [pak::_rglob $item $pattern] { lappend found $sub }
        } elseif {[string match $pattern [file tail $item]]} {
            lappend found $item
        }
    }
    return $found
}
proc pak::_relto {path base} {
    set p [file split [file normalize $path]]
    set b [file split [file normalize $base]]
    set i 0
    while {$i < [llength $b] && $i < [llength $p] && [lindex $b $i] eq [lindex $p $i]} { incr i }
    return [file join {*}[lrange $p $i end]]
}

proc pak::cli_read {path} {
    set f [open $path r]; fconfigure $f -encoding utf-8; set s [read $f]; close $f; return $s
}
proc pak::cli_write {path content} {
    # Source files load under the system encoding (iso8859-1 here), which is
    # byte-preserving: on-disk UTF-8 bytes survive as 1 char each. Write them
    # back the same way so output bytes match the Python (UTF-8) oracle exactly,
    # regardless of locale.
    file mkdir [file dirname $path]
    set f [open $path w]; fconfigure $f -encoding [encoding system]; puts -nonewline $f $content; close $f
}

# Parse a .pk64 file → ast, or "" (printing E001/E002 to stderr like Python).
proc pak::cli_parse_file {path} {
    set src [pak::cli_read $path]
    if {[catch {
        set lx [pak::Lexer new $src]
        set ast [pak::parse_tokens [$lx tokenize]]
    } err]} {
        if {[string match "LEXERROR*" $err]} {
            puts stderr "error\[E001\]: [pak::_errmsg $err]"
            puts stderr "  --> $path"
        } else {
            puts stderr "error\[E002\]: [pak::_errmsg $err]"
            puts stderr "  --> $path"
        }
        return ""
    }
    return $ast
}
proc pak::_errmsg {err} {
    set parts [split $err "\t"]
    if {[llength $parts] >= 4} { return "[lindex $parts 1]:[lindex $parts 2]: [lindex $parts 3]" }
    return $err
}

# Format a diagnostic dict exactly like PakError/CheckDiag.__str__.
proc pak::diag_str {d} {
    set fn [expr {[dict exists $d filename] ? [dict get $d filename] : ""}]
    if {$fn ne ""} { set loc "$fn:[dict get $d line]:[dict get $d col]" } \
    else { set loc "[dict get $d line]:[dict get $d col]" }
    set prefix [expr {[dict get $d severity] eq "warning" ? "warning" : "error"}]
    set lines [list "$prefix\[[dict get $d code]\]: [dict get $d message]" "  --> $loc"]
    if {[dict get $d hint] ne ""} { lappend lines "  help: [dict get $d hint]" }
    return [join $lines "\n"]
}

# ── Type + semantic checking (mirrors typecheck_multi / _run_full_check) ───────
proc pak::cli_typecheck_multi {programs {no_style 0}} {
    set env [pak::TypeEnv new]
    foreach pr $programs {
        lassign $pr fn prog
        $env collect [pak::items [pak::nfield $prog decls]]
    }
    set results [dict create]
    foreach pr $programs {
        lassign $pr fn prog
        set tc [pak::TypeChecker new $env $fn $no_style]
        dict set results $fn [$tc check [pak::items [pak::nfield $prog decls]]]
        $tc destroy
    }
    $env destroy
    return $results
}

proc pak::cli_check_entry_blocks {parsed} {
    set entry_files {}; set entry_first ""
    set has_fns 0
    foreach pr $parsed {
        lassign $pr fn prog
        foreach decl [pak::items [pak::nfield $prog decls]] {
            set k [pak::kindof $decl]
            if {$k eq "EntryBlock"} {
                if {$entry_first eq ""} { set entry_first $fn }
                lappend entry_files [list $fn $decl]
            } elseif {$k eq "FnDecl"} { set has_fns 1 }
        }
    }
    set diags {}
    if {[llength $entry_files] == 0} {
        if {$has_fns} {
            lappend diags [dict create code E103 \
                message "No entry block found in any source file" \
                hint "Add `entry { ... }` to your main source file" \
                line 0 col 0 filename "" severity error]
        }
    } elseif {[llength $entry_files] > 1} {
        foreach pair [lrange $entry_files 1 end] {
            lassign $pair fn decl
            lappend diags [dict create code E103 \
                message "Multiple entry blocks found — only one is allowed per project" \
                hint "First entry is in $entry_first" \
                line [pak::_nodeline $decl] col [pak::_nodecol $decl] \
                filename $fn severity error]
        }
    }
    return $diags
}
proc pak::_nodeline {node} { if {[catch {pak::fval $node line} v]} { return 0 }; return $v }
proc pak::_nodecol {node}  { if {[catch {pak::fval $node col} v]} { return 0 }; return $v }

# Verify every project-local `use` path resolves to a declared module. Builtin
# namespaces (n64.*, t3d.*, std) are validated per-file by the semantic checker;
# this cross-file pass catches `use foo.bar` with no matching `module foo.bar`.
proc pak::cli_check_module_imports {parsed} {
    set declared [dict create]
    foreach pr $parsed {
        lassign $pr fn prog
        foreach decl [pak::items [pak::nfield $prog decls]] {
            if {[pak::kindof $decl] eq "ModuleDecl"} {
                dict set declared [pak::fval $decl path] 1
            }
        }
    }
    set builtins {n64 t3d std}
    set diags {}
    foreach pr $parsed {
        lassign $pr fn prog
        foreach decl [pak::items [pak::nfield $prog decls]] {
            if {[pak::kindof $decl] ne "UseDecl"} { continue }
            set path [pak::fval $decl path]
            set prefix [lindex [split $path .] 0]
            if {$prefix in $builtins} { continue }
            if {![dict exists $declared $path]} {
                if {[dict size $declared] > 0} {
                    set hint "Known project modules: [join [lsort [dict keys $declared]] {, }]"
                } else {
                    set hint "No project modules are declared. Add `module $path` to the file that defines it."
                }
                lappend diags [dict create code E105 \
                    message "Unknown module '$path' — no matching `module $path` declaration found" \
                    hint $hint \
                    line [pak::_nodeline $decl] col [pak::_nodecol $decl] \
                    filename $fn severity error]
            }
        }
    }
    return $diags
}

# Returns {hard_errors warnings}. Prints diagnostics to stderr and per-file
# status to stdout, exactly like _run_full_check.
proc pak::cli_run_full_check {parsed root no_style} {
    set tc_results [pak::cli_typecheck_multi $parsed $no_style]
    set hard 0; set warns 0
    set tc_diags [dict create]
    dict for {fn ds} $tc_results {
        dict set tc_diags $fn $ds
        foreach d $ds { if {[dict get $d severity] eq "warning"} { incr warns } else { incr hard } }
    }
    set sem_diags [dict create]
    foreach pr $parsed {
        lassign $pr fn prog
        set all [pak::semantic_check $prog $fn]
        set errs {}; set ws {}
        foreach d $all { if {[dict get $d severity] eq "warning"} { lappend ws $d } else { lappend errs $d } }
        dict set sem_diags $fn [list $errs $ws]
        incr hard [llength $errs]
        if {!$no_style} { incr warns [llength $ws] }
    }
    foreach d [pak::cli_check_entry_blocks $parsed] {
        incr hard
        puts stderr [pak::diag_str $d]
    }
    foreach d [pak::cli_check_module_imports $parsed] {
        incr hard
        puts stderr [pak::diag_str $d]
    }
    foreach pr $parsed {
        lassign $pr fn prog
        set rel [expr {$root ne "" ? [pak::_relto $fn $root] : $fn}]
        set file_errs {}; set file_warns {}
        foreach d [dict get $tc_diags $fn] {
            if {[dict get $d severity] eq "warning"} { lappend file_warns $d } else { lappend file_errs $d }
        }
        lassign [dict get $sem_diags $fn] se sw
        foreach d $se { lappend file_errs $d }
        foreach d $sw { lappend file_warns $d }
        foreach d $file_errs { puts stderr [pak::diag_str $d] }
        if {!$no_style} { foreach d $file_warns { puts stderr [pak::diag_str $d] } }
        if {[llength $file_errs] > 0} {
            puts "  $rel: [llength $file_errs] error(s)"
        } elseif {[llength $file_warns] > 0 && !$no_style} {
            puts "  $rel: ok  ([llength $file_warns] warning(s))"
        } else {
            puts "  $rel: ok"
        }
    }
    return [list $hard $warns]
}

# ── Codegen backends (mirror _build_c / _build_mips) ──────────────────────────
proc pak::cli_build_c {parsed root build_dir verbose} {
    set module_headers [dict create]
    foreach pr $parsed {
        lassign $pr pf prog
        set mod_path [pak::_module_path $prog]
        if {$mod_path ne ""} {
            set header_name [pak::module_to_filename $mod_path]
            dict set module_headers $mod_path $header_name
            pak::cli_write [file join $build_dir $header_name] [pak::generate_header $prog $mod_path]
        }
    }
    set c_rel {}
    foreach pr $parsed {
        lassign $pr pf prog
        set rel [pak::_relto $pf $root]
        set c_file [file join $build_dir [file rootname $rel].c]
        set c_source [pak::generate $prog $pf $module_headers]
        pak::cli_write $c_file $c_source
        set crel [pak::_relto $c_file $root]
        lappend c_rel $crel
        puts "  Compiled $rel -> $crel"
    }
    return $c_rel
}
proc pak::cli_build_mips {parsed root build_dir verbose} {
    set s_rel {}
    foreach pr $parsed {
        lassign $pr pf prog
        set rel [pak::_relto $pf $root]
        set s_file [file join $build_dir [file rootname $rel].s]
        set asm [pak::optimize_asm [pak::mips_generate $prog]]
        pak::cli_write $s_file $asm
        set srel [pak::_relto $s_file $root]
        lappend s_rel $srel
        puts "  Compiled $rel -> $srel"
    }
    return $s_rel
}
proc pak::_module_path {prog} {
    foreach decl [pak::items [pak::nfield $prog decls]] {
        if {[pak::kindof $decl] eq "ModuleDecl"} { return [pak::fval $decl path] }
    }
    return ""
}

# ── Commands ──────────────────────────────────────────────────────────────────
proc pak::cmd_build {opts} {
    set root [pak::cli_find_project_root]
    if {$root eq ""} {
        puts stderr "error: no pak.toml found. Run `pak init <name>` to create a project."
        exit 1
    }
    set config [pak::toml_parse [pak::cli_read [file join $root pak.toml]]]
    set project_name [pak::cfg_get $config project name game]
    set rom_title [pak::cfg_get $config project rom_title [string range [string toupper $project_name] 0 19]]
    set save_type [pak::cfg_get $config project save_type none]
    set resolution [pak::cfg_get $config display resolution 320x240]
    set bit_depth [pak::cfg_get $config display bit_depth 16]
    set framebuffers [pak::cfg_get $config display framebuffers 3]
    set use_tiny3d [pak::cfg_get $config dependencies tiny3d 0]
    set optimization [pak::cfg_get $config build optimization debug]
    set verbose [dict get $opts verbose]
    set no_style [dict get $opts no_style_warnings]
    set backend [dict get $opts backend]

    puts "Building $project_name (backend: $backend)..."
    set build_dir [file join $root build]
    file mkdir $build_dir

    set src_files [pak::cli_src_files $root]
    if {[llength $src_files] == 0} { puts stderr "error: no .pk64 source files found"; exit 1 }
    set parsed {}
    foreach pf $src_files {
        set prog [pak::cli_parse_file $pf]
        if {$prog eq ""} { exit 1 }
        lappend parsed [list $pf $prog]
    }
    lassign [pak::cli_run_full_check $parsed $root $no_style] hard warns
    if {$warns > 0 && !$no_style} {
        puts stderr "\n$warns style warning(s). Use --no-style-warnings to suppress."
    }
    if {$hard > 0} {
        puts stderr "\n$hard error(s). Fix them before building."
        puts stderr "  Tip: run `pak check` for a detailed report."
        exit 1
    }
    if {$backend eq "mips"} {
        set out_rel [pak::cli_build_mips $parsed $root $build_dir $verbose]
    } else {
        set out_rel [pak::cli_build_c $parsed $root $build_dir $verbose]
    }
    # Runtime copy
    set rt_src [pak::cli_runtime_dir]
    set rt_dst [file join $root runtime]
    if {[file exists $rt_src] && [file normalize $rt_src] ne [file normalize $rt_dst]} {
        file mkdir $rt_dst
        foreach f [glob -nocomplain -directory $rt_src *] {
            set dst [file join $rt_dst [file tail $f]]
            if {![file exists $dst]} { file copy $f $dst }
        }
        puts "  Runtime -> runtime/"
    }
    # Assets / pakfs
    set has_assets 0
    set pakfs_name "${project_name}.pakfs"
    set packable {}
    set convert {.png .sprite .wav .wav64 .xm .xm64 .ym .ym64 .gltf .t3dm .glb .t3dm}
    if {[dict exists $config assets]} {
        dict for {kind rel_dir} [dict get $config assets] {
            set asset_path [file join $root $rel_dir]
            if {[file isdirectory $asset_path]} {
                foreach f [lsort [pak::_rglob $asset_path *]] {
                    set ext [file extension $f]
                    set idx [lsearch -exact $convert $ext]
                    if {$idx >= 0} {
                        set out_ext [lindex $convert [expr {$idx+1}]]
                        set rel [pak::_relto $f $asset_path]
                        set conv [file join $build_dir [file rootname $rel]$out_ext]
                        if {[file exists $conv]} {
                            set arch [pak::_relto $conv $build_dir]
                            lappend packable [list $arch [pak::cli_read_bin $conv]]
                            set has_assets 1
                        }
                    }
                }
            }
        }
    }
    if {$has_assets} {
        set fsdir [file join $root filesystem]
        file mkdir $fsdir
        pak::cli_write_bin [file join $fsdir $pakfs_name] [pak::pakfs_pack $packable]
        puts "  Packed [llength $packable] asset(s) -> filesystem/$pakfs_name"
    }
    set pakfs_arg [expr {$has_assets ? $pakfs_name : ""}]
    set makefile [pak::generate_makefile $project_name $rom_title $out_rel $pakfs_arg \
        $save_type $bit_depth $resolution $framebuffers $optimization $use_tiny3d $root $backend]
    pak::cli_write [file join $root Makefile] $makefile
    puts "  Generated Makefile"
    puts ""
    puts "Build complete. Next steps:"
    puts "  1. Set N64_INST to your libdragon installation (export N64_INST=/opt/libdragon)"
    if {$use_tiny3d} {
        puts "  2. Set TINY3D_INST to your Tiny3D installation"
        puts "  3. Run: make"
    } else {
        puts "  2. Run: make"
    }
    puts "  3. Run: make run   (launches in ares emulator)"
}

proc pak::cli_read_bin {path} {
    set f [open $path rb]; set d [read $f]; close $f; return $d
}
proc pak::cli_write_bin {path data} {
    file mkdir [file dirname $path]
    set f [open $path wb]; puts -nonewline $f $data; close $f
}

proc pak::cmd_check {opts} {
    set root [pak::cli_find_project_root]
    set no_style [dict get $opts no_style_warnings]
    if {$root eq ""} {
        set files [dict get $opts files]
        if {[llength $files] == 0} {
            puts stderr "error: no pak.toml found and no files specified"
            puts stderr "  hint: run `pak check file.pk64` or `cd` to a project directory"
            exit 1
        }
        set src_files $files
    } else {
        set src_files [pak::cli_src_files $root]
        if {[llength $src_files] == 0} { puts stderr "error: no .pk64 source files found"; exit 1 }
    }
    set parsed {}; set n_parse_errors 0
    foreach pf $src_files {
        set prog [pak::cli_parse_file $pf]
        if {$prog eq ""} { incr n_parse_errors } else { lappend parsed [list $pf $prog] }
    }
    set hard $n_parse_errors; set warns 0
    if {[llength $parsed] > 0} {
        lassign [pak::cli_run_full_check $parsed $root $no_style] h w
        incr hard $h; set warns $w
    }
    set n [llength $src_files]
    if {$hard > 0} {
        puts stderr "\n$hard error(s) in $n file(s)."
    } elseif {$warns > 0 && !$no_style} {
        puts "\n$n file(s) checked — $warns warning(s). Use --no-style-warnings to suppress."
    } else {
        puts "\n$n file(s) checked — all passed."
    }
    exit [expr {$hard ? 1 : 0}]
}

proc pak::cmd_explain {opts} {
    set pak_file [dict get $opts file]
    if {![file exists $pak_file]} { puts stderr "error: file not found: $pak_file"; exit 1 }
    set backend [dict get $opts backend]
    if {$backend eq "mips"} {
        set prog [pak::cli_parse_file $pak_file]
        if {$prog eq ""} { exit 1 }
        puts [pak::optimize_asm [pak::mips_generate $prog]]
    } else {
        set prog [pak::cli_parse_file $pak_file]
        if {$prog eq ""} { exit 1 }
        puts [pak::generate $prog $pak_file]
    }
}

proc pak::cmd_objgen {opts} {
    set pak_file [dict get $opts file]
    if {![file exists $pak_file]} { puts stderr "error: file not found: $pak_file"; exit 1 }
    set out [dict get $opts output]
    if {$out eq ""} { set out "[file rootname $pak_file].pakobj" }
    set prog [pak::cli_parse_file $pak_file]
    if {$prog eq ""} { exit 1 }
    set recs [pak::mips_generate_records $prog]
    pak::enc::write_object $recs $out
    puts "Wrote $out"
}

proc pak::cmd_asmobj {opts} {
    set asm_file [dict get $opts file]
    if {![file exists $asm_file]} { puts stderr "error: file not found: $asm_file"; exit 1 }
    set out [dict get $opts output]
    if {$out eq ""} { set out "[file rootname $asm_file].pakobj" }
    set fh [open $asm_file r]; set text [read $fh]; close $fh
    pak::enc::write_object_from_asm $text $out
    puts "Wrote $out"
}

proc pak::cmd_run {opts} {
    pak::cmd_build $opts
    set root [pak::cli_find_project_root]
    if {$root ne "" && [file exists [file join $root Makefile]]} {
        puts "Running: make run"
        catch {exec make run >@ stdout 2>@ stderr}
    }
}

proc pak::cmd_pack {opts} {
    set out [dict get $opts output]
    set base [dict get $opts base]
    set files [dict get $opts files]
    set packable {}
    if {[llength $files] > 0} {
        foreach f $files {
            if {[file isfile $f]} {
                if {$base ne ""} {
                    set arch [pak::_relto $f $base]
                    if {[string match "../*" $arch]} { set arch [file tail $f] }
                } else { set arch [file tail $f] }
                lappend packable [list $arch [pak::cli_read_bin $f]]
            }
        }
    } else {
        if {[file isdirectory build]} {
            foreach f [lsort [pak::_rglob build *]] {
                if {[lsearch -exact {.sprite .wav64 .xm64 .ym64 .t3dm} [file extension $f]] >= 0} {
                    lappend packable [list [pak::_relto $f build] [pak::cli_read_bin $f]]
                }
            }
        }
    }
    if {[llength $packable] == 0} { puts stderr "warning: no assets found to pack"; return }
    pak::cli_write_bin $out [pak::pakfs_pack $packable]
    puts "Packed [llength $packable] file(s) into $out"
}

proc pak::cmd_init {opts} {
    set name [dict get $opts name]
    if {[file exists $name]} { puts stderr "error: directory '$name' already exists"; exit 1 }
    file mkdir $name [file join $name src] [file join $name assets sprites] \
        [file join $name assets models] [file join $name assets audio] [file join $name assets fonts]
    set title [string range [string toupper $name] 0 19]
    pak::cli_write [file join $name pak.toml] "\[project\]
name = \"$name\"
rom_title = \"$title\"
save_type = \"none\"

\[display\]
resolution = \"320x240\"
bit_depth = 16
framebuffers = 3

\[assets\]
sprites = \"assets/sprites/\"
models  = \"assets/models/\"
audio   = \"assets/audio/\"
fonts   = \"assets/fonts/\"

\[dependencies\]
tiny3d = false

\[build\]
optimization = \"debug\"
"
    pak::cli_write [file join $name src main.pk64] "-- $name
-- Created with: pak init $name

use n64.display
use n64.controller
use n64.rdpq

entry {
    -- Initialize display: 0=320x240, 2=16bpp, 3=triple-buffer, 0=GAMMA_NONE, 1=FILTERS_RESAMPLE
    display.init(0, 2, 3, 0, 1)

    loop {
        let input = controller.read(0)

        -- Begin frame
        let disp = display.get()
        rdpq.attach_clear(disp, none)

        -- ── Game logic here ─────────────────────────────────────────────

        rdpq.detach_show()
    }
}
"
    set rt_src [pak::cli_runtime_dir]
    if {[file exists $rt_src]} { file copy $rt_src [file join $name runtime] }
    pak::cli_write [file join $name .gitignore] "build/
filesystem/
Makefile
*.z64
*.elf
"
    puts "Created project '$name'"
    puts "  $name/pak.toml"
    puts "  $name/src/main.pk64"
    puts "  $name/assets/sprites/"
    puts "  $name/assets/models/"
    puts "  $name/assets/audio/"
    puts "  $name/assets/fonts/"
    puts "  $name/runtime/       (PakFS C runtime)"
    puts ""
    puts "Next steps:"
    puts "  cd $name"
    puts "  export N64_INST=/opt/libdragon   # or wherever libdragon is installed"
    puts "  pak build && make"
}

proc pak::cmd_clean {opts} {
    set root [pak::cli_find_project_root]
    if {$root eq ""} { puts stderr "error: no pak.toml found"; exit 1 }
    set removed {}
    foreach target {build filesystem} {
        set d [file join $root $target]
        if {[file exists $d]} { file delete -force $d; lappend removed $target }
    }
    set mf [file join $root Makefile]
    if {[file exists $mf]} { file delete $mf; lappend removed Makefile }
    foreach pat {*.z64 *.elf} {
        foreach f [glob -nocomplain -directory $root $pat] { file delete $f; lappend removed [file tail $f] }
    }
    if {[llength $removed] > 0} { puts "Cleaned: [join $removed {, }]" } else { puts "Nothing to clean." }
}

proc pak::cmd_runtime_dir {opts} { puts [pak::cli_runtime_dir] }

# ── argv dispatch ─────────────────────────────────────────────────────────────
proc pak::cli_main {argv} {
    if {[llength $argv] == 0} { pak::cli_help; exit 0 }
    set cmd [lindex $argv 0]
    set rest [lrange $argv 1 end]
    switch -- $cmd {
        build  { pak::cmd_build [pak::_parse_opts $rest {verbose 0 backend c no_style_warnings 0}] }
        check  { pak::cmd_check [pak::_parse_opts $rest {files {} no_style_warnings 0}] }
        explain { pak::cmd_explain [pak::_parse_opts $rest {file "" backend c}] }
        objgen { pak::cmd_objgen [pak::_parse_opts $rest {file "" output ""}] }
        asmobj { pak::cmd_asmobj [pak::_parse_opts $rest {file "" output ""}] }
        run    { pak::cmd_run [pak::_parse_opts $rest {verbose 0 backend c no_style_warnings 0}] }
        init   { pak::cmd_init [pak::_parse_opts $rest {name ""}] }
        clean  { pak::cmd_clean {} }
        pack   { pak::cmd_pack [pak::_parse_opts $rest {files {} output "" base ""}] }
        --runtime-dir { pak::cmd_runtime_dir {} }
        --version { puts "pak 0.1.0" }
        default { puts stderr "unknown command: $cmd"; exit 2 }
    }
}
proc pak::cli_help {} {
    puts "usage: pak \[--version\] COMMAND ..."
    puts "commands: build check explain run init clean pack"
}
# Tiny flag parser: positionals fill 'file'/'name'/'files'; flags set keys.
proc pak::_parse_opts {argv defaults} {
    set o [dict create {*}$defaults]
    set pos {}
    set n [llength $argv]
    for {set i 0} {$i < $n} {incr i} {
        set a [lindex $argv $i]
        switch -glob -- $a {
            -v - --verbose { dict set o verbose 1 }
            --no-style-warnings { dict set o no_style_warnings 1 }
            --backend { incr i; dict set o backend [lindex $argv $i] }
            --output - -o { incr i; dict set o output [lindex $argv $i] }
            --base { incr i; dict set o base [lindex $argv $i] }
            -* { }
            default { lappend pos $a }
        }
    }
    if {[dict exists $o file] && [llength $pos] > 0}  { dict set o file [lindex $pos 0] }
    if {[dict exists $o name] && [llength $pos] > 0}  { dict set o name [lindex $pos 0] }
    if {[dict exists $o files]} { dict set o files $pos }
    return $o
}

if {[info script] eq $::argv0} { pak::cli_main $::argv }
