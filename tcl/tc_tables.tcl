# tcl/tc_tables.tcl — lookup tables for the typechecker: module namespaces,
# DMA functions and allocating calls.
# Generated once from a second implementation; now hand-maintained source.
namespace eval pak {}
# Include guard (reachable via multiple consumers; see ast.tcl).
if {[info exists ::pak::_tc_tables_loaded]} { return }
set ::pak::_tc_tables_loaded 1

set ::pak::MODULE_NAMESPACES [dict create \
    {arena} 1 \
    {audio} 1 \
    {backup} 1 \
    {cache} 1 \
    {controller} 1 \
    {cpak} 1 \
    {debug} 1 \
    {disk} 1 \
    {display} 1 \
    {dma} 1 \
    {eeprom} 1 \
    {exception} 1 \
    {flashram} 1 \
    {joypad} 1 \
    {math} 1 \
    {mem} 1 \
    {mixer} 1 \
    {mouse} 1 \
    {n64} 1 \
    {rdpq} 1 \
    {rdpq_font} 1 \
    {rdpq_mode} 1 \
    {rdpq_tex} 1 \
    {rsp} 1 \
    {rtc} 1 \
    {rumble} 1 \
    {sprite} 1 \
    {sram} 1 \
    {str} 1 \
    {surface} 1 \
    {system} 1 \
    {t3d} 1 \
    {timer} 1 \
    {tpak} 1 \
    {vi} 1 \
    {vru} 1 \
    {wav64} 1 \
    {xm64} 1 \
]

set ::pak::DMA_SAFE_ANNS [dict create \
    {@aligned(16)} 1 \
    {@dma_safe} 1 \
]

set ::pak::DMA_FNS [dict create \
    {cache invalidate} 1 \
    {cache writeback} 1 \
    {cache writeback_inv} 1 \
    {dma read} 1 \
    {dma write} 1 \
]

set ::pak::ALLOC_CALLS [dict create \
    {mem alloc} 1 \
    {mem alloc_aligned} 1 \
    {mem realloc} 1 \
    {t3d anim_create} 1 \
    {t3d model_load} 1 \
    {t3d skeleton_create} 1 \
]
