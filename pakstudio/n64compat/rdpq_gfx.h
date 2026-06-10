/* rdpq_gfx.h — compatibility shim.
 *
 * pak 0.1.0 emits `#include <rdpq_gfx.h>`, a header that older libdragon
 * shipped but current libdragon split into rdpq_rect.h / rdpq_mode.h (both
 * already pulled in by <libdragon.h>). This shim just satisfies the include;
 * the symbols (rdpq_fill_rectangle, rdpq_set_fill_color, ...) come from
 * libdragon.h, which the generated code includes first.
 */
#ifndef PAK_COMPAT_RDPQ_GFX_H
#define PAK_COMPAT_RDPQ_GFX_H
#include <rdpq.h>
#include <rdpq_mode.h>
#include <rdpq_rect.h>
#endif
