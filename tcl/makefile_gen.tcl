# tcl/makefile_gen.tcl — generate a libdragon-compatible Makefile.
# Pure string templating; no AST involved.

namespace eval pak {}
if {[info exists ::pak::_makefile_gen_loaded]} { return }
set ::pak::_makefile_gen_loaded 1

# Mirror CPython repr() of a str for the common ROM-title cases: single quotes
# unless the string has a ' and no ", with \\ \' \" \n \r \t escaping.
proc pak::py_repr_str {s} {
    set has_single [expr {[string first ' $s] >= 0}]
    set has_double [expr {[string first "\"" $s] >= 0}]
    if {$has_single && !$has_double} { set q "\"" } else { set q "'" }
    set out $q
    foreach ch [split $s ""] {
        if {$ch eq "\\"} { append out "\\\\" } \
        elseif {$ch eq $q} { append out "\\$ch" } \
        elseif {$ch eq "\n"} { append out "\\n" } \
        elseif {$ch eq "\r"} { append out "\\r" } \
        elseif {$ch eq "\t"} { append out "\\t" } \
        else { append out $ch }
    }
    append out $q
    return $out
}

proc pak::_mf_objs_block {is_mips} {
    if {$is_mips} {
        return "C_SRCS  = \$(filter %.c,\$(SRCS))
S_SRCS  = \$(filter %.s,\$(SRCS))
C_OBJS  = \$(C_SRCS:%.c=\$(BUILD_DIR)/%.o)
S_OBJS  = \$(S_SRCS:%.s=\$(BUILD_DIR)/%.o)
OBJS    = \$(C_OBJS) \$(S_OBJS)
DEPS    = \$(C_OBJS:.o=.d)"
    }
    return "OBJS = \$(SRCS:%.c=\$(BUILD_DIR)/%.o)
DEPS = \$(OBJS:.o=.d)"
}

proc pak::_mf_compile_rules {is_mips} {
    if {$is_mips} {
        return "# Assemble MIPS sources (.s)
\$(BUILD_DIR)/%.o: %.s
\t@mkdir -p \$(dir \$@)
\t\$(CC) \$(N64_CFLAGS) -c \$< -o \$@

# Compile C sources (runtime)
\$(BUILD_DIR)/%.o: %.c
\t@mkdir -p \$(dir \$@)
\t\$(CC) \$(CFLAGS) \$(N64_CFLAGS) -MMD -c \$< -o \$@

-include \$(DEPS)"
    }
    return "# Compile C sources
\$(BUILD_DIR)/%.o: %.c
\t@mkdir -p \$(dir \$@)
\t\$(CC) \$(CFLAGS) \$(N64_CFLAGS) -MMD -c \$< -o \$@

-include \$(DEPS)"
}

proc pak::_mf_asset_rules {use_tiny3d} {
    set rules {}
    lappend rules "# ── Asset conversion rules ────────────────────────────────────────"
    lappend rules "\$(BUILD_DIR)/%.sprite: %.png
\t@mkdir -p \$(dir \$@)
\t\$(MKSPRITE) --format RGBA16 --output \$@ \$<"
    lappend rules "\$(BUILD_DIR)/%.wav64: %.wav
\t@mkdir -p \$(dir \$@)
\t\$(AUDIOCONV64) \$< \$@

\$(BUILD_DIR)/%.xm64: %.xm
\t@mkdir -p \$(dir \$@)
\t\$(AUDIOCONV64) \$< \$@

\$(BUILD_DIR)/%.ym64: %.ym
\t@mkdir -p \$(dir \$@)
\t\$(AUDIOCONV64) \$< \$@"
    if {$use_tiny3d} {
        lappend rules "\$(BUILD_DIR)/%.t3dm: %.gltf
\t@mkdir -p \$(dir \$@)
\t\$(T3D_GLTF) \$< \$@

\$(BUILD_DIR)/%.t3dm: %.glb
\t@mkdir -p \$(dir \$@)
\t\$(T3D_GLTF) \$< \$@"
    }
    return [join $rules "\n\n"]
}

proc pak::_mf_pakfs_rule {project_name} {
    return "# ── PakFS archive (packed from converted assets in BUILD_DIR) ──────────────
_RAW_ASSETS      := \$(shell find assets -type f 2>/dev/null)
_SPRITE_SRCS     := \$(filter %.png,\$(_RAW_ASSETS))
_WAV_SRCS        := \$(filter %.wav,\$(_RAW_ASSETS))
_XM_SRCS         := \$(filter %.xm,\$(_RAW_ASSETS))
_YM_SRCS         := \$(filter %.ym,\$(_RAW_ASSETS))
_T3DM_SRCS       := \$(filter %.gltf %.glb,\$(_RAW_ASSETS))
_SPRITE_OUTS     := \$(patsubst %.png,\$(BUILD_DIR)/%.sprite,\$(_SPRITE_SRCS))
_WAV_OUTS        := \$(patsubst %.wav,\$(BUILD_DIR)/%.wav64,\$(_WAV_SRCS))
_XM_OUTS         := \$(patsubst %.xm,\$(BUILD_DIR)/%.xm64,\$(_XM_SRCS))
_YM_OUTS         := \$(patsubst %.ym,\$(BUILD_DIR)/%.ym64,\$(_YM_SRCS))
_T3DM_OUTS       := \$(patsubst %.gltf,\$(BUILD_DIR)/%.t3dm,\$(filter %.gltf,\$(_T3DM_SRCS))) \\
                    \$(patsubst %.glb,\$(BUILD_DIR)/%.t3dm,\$(filter %.glb,\$(_T3DM_SRCS)))
_CONVERTED_ASSETS := \$(_SPRITE_OUTS) \$(_WAV_OUTS) \$(_XM_OUTS) \$(_YM_OUTS) \$(_T3DM_OUTS)

filesystem/${project_name}.pakfs: \$(_CONVERTED_ASSETS)
\t@mkdir -p filesystem
\tpak pack --output \$@ --base \$(BUILD_DIR) \$(_CONVERTED_ASSETS)"
}

proc pak::generate_makefile {project_name rom_title c_files pakfs_archive \
        {save_type none} {bit_depth 16} {resolution 320x240} {framebuffers 3} \
        {optimization debug} {use_tiny3d 0} {project_root .} {backend c}} {

    set src_list [join $c_files " \\\n        "]
    append src_list " \\\n        runtime/pakfs.c"

    set is_mips [expr {$backend eq "mips"}]
    set opt_flag [expr {$optimization eq "release" ? "-O2" : "-g -O0"}]

    lassign [split $resolution x] res_w res_h
    set res_define "RESOLUTION_${res_w}x${res_h}"
    set depth_define "DEPTH_${bit_depth}_BPP"

    set save_map [dict create none EEPROM_4K eeprom4k EEPROM_4K eeprom16k EEPROM_16K \
        sram256k SRAM_256K sram768k SRAM_768K flashram FLASHRAM]
    set st [string tolower $save_type]
    set save_str [expr {[dict exists $save_map $st] ? [dict get $save_map $st] : "EEPROM_4K"}]

    set asset_rules [pak::_mf_asset_rules $use_tiny3d]
    set pakfs_rule [expr {$pakfs_archive ne "" ? [pak::_mf_pakfs_rule $project_name] : ""}]

    set tiny3d_ldflags [expr {$use_tiny3d ? "\$(TINY3D_LDFLAGS)" : ""}]
    set tiny3d_include [expr {$use_tiny3d ? "\$(TINY3D_CFLAGS)" : ""}]
    set tiny3d_check ""
    if {$use_tiny3d} {
        set tiny3d_check "
ifndef TINY3D_INST
\$(error TINY3D_INST is not set. Set it to your Tiny3D installation path.)
endif
# runtime/pak_math.h is entirely T3DVec/T3DMat wrappers, so it compiles its
# body only when Tiny3D is actually present.
TINY3D_CFLAGS  := -I\$(TINY3D_INST)/include -DPAK_HAS_TINY3D=1
TINY3D_LDFLAGS := -L\$(TINY3D_INST)/lib -lt3d
"
    }

    set dfs_file [expr {$pakfs_archive ne "" ? "filesystem/${project_name}.pakfs" : ""}]
    set dfs_include [expr {$dfs_file ne "" ? "\nDFS_FILE        = $dfs_file" : ""}]
    set dfs_dep [expr {$dfs_file ne "" ? " \$(DFS_FILE)" : ""}]
    set clean_fs [expr {$dfs_file ne "" ? " filesystem/" : ""}]

    set rom_title_repr [pak::py_repr_str [string range $rom_title 0 19]]
    set objs_block [pak::_mf_objs_block $is_mips]
    set compile_rules [pak::_mf_compile_rules $is_mips]

    return "# Makefile for $project_name — generated by Pak compiler
# Requires: libdragon toolchain (https://github.com/DragonMinded/libdragon)
# Usage:
#   make          — build ${project_name}.z64
#   make run      — build and launch in ares emulator
#   make clean    — remove build artifacts

include \$(N64_INST)/include/n64.mk
$tiny3d_check
PROJECT_NAME    = $project_name
ROM_TITLE       = $rom_title_repr
SAVE_TYPE       = $save_str

RESOLUTION      = $res_define
BIT_DEPTH       = $depth_define
FRAMEBUFFERS    = $framebuffers

BUILD_DIR       = build
RUNTIME_DIR     = \$(shell pak --runtime-dir 2>/dev/null || echo runtime)
$dfs_include

SRCS = $src_list

$objs_block

CFLAGS  += $opt_flag -Wall -Wextra
CFLAGS  += -DRESOLUTION=\$(RESOLUTION) -DBIT_DEPTH=\$(BIT_DEPTH)
CFLAGS  += -DFRAMEBUFFERS=\$(FRAMEBUFFERS)
CFLAGS  += -I\$(RUNTIME_DIR)
CFLAGS  += -I\$(BUILD_DIR)
CFLAGS  += $tiny3d_include

LDFLAGS += $tiny3d_ldflags

.PHONY: all clean run

all: \$(PROJECT_NAME).z64

# Link
\$(PROJECT_NAME).elf: \$(OBJS)
\t\$(CC) \$(OBJS) \$(LDFLAGS) \$(N64_LDFLAGS) -o \$@

# ROM
\$(PROJECT_NAME).z64: \$(PROJECT_NAME).elf$dfs_dep
\t\$(N64TOOL) \\
\t    --title \$(ROM_TITLE) \\
\t    --savetype \$(SAVE_TYPE) \\
\t    --output \$@ \\
\t    --header \$(N64_INST)/mips64-elf/lib/header \\
\t    \$<$dfs_dep

$compile_rules

$asset_rules
$pakfs_rule

run: \$(PROJECT_NAME).z64
\tares --system Nintendo64 \$<

clean:
\trm -rf \$(BUILD_DIR) \$(PROJECT_NAME).elf \$(PROJECT_NAME).z64$clean_fs
"
}
