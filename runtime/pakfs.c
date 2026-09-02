/**
 * pakfs.c - PakFS runtime implementation for Nintendo 64 (libdragon)
 *
 * Archive layout (produced by pak build):
 *
 *   Offset  Size   Field
 *   0       4      Magic: "PKFS"
 *   4       2      Version: 0x0001 (little-endian)
 *   6       2      num_files (little-endian)
 *   8       4      index_offset (little-endian, from start of archive)
 *
 *   --- index (num_files entries, packed) ---
 *   +0      2      name_len
 *   +2      name_len  name (UTF-8, no null terminator)
 *   +?      4      data_offset (from start of archive)
 *   +?      4      data_size (actual bytes, before 16-byte alignment pad)
 *   +?      2      flags (reserved, 0)
 *
 *   --- file data (16-byte aligned) ---
 *
 * The entire archive is DMA-read into a 16-byte-aligned heap buffer once
 * at startup.  All pak:/ opens are zero-copy reads from that buffer.
 *
 * libdragon filesystem integration:
 *   pakfs_init() calls attach_filesystem() to register "pak" as a scheme.
 *   The filesystem vtable maps open/close/read/seek/fstat onto the
 *   in-memory archive index.  Standard C fopen("pak:/hero.sprite", "rb")
 *   and libdragon's dfs_open / sprite_load("pak:/...") all work normally.
 */

#include "pakfs.h"

#include <libdragon.h>
#include <system.h>     /* filesystem_t, attach_filesystem, detach_filesystem */
#include <sys/stat.h>   /* struct stat, S_IFREG */
#include <malloc.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>

/* ── Archive format constants ─────────────────────────────────────────── */

#define PAKFS_MAGIC     "PKFS"
#define PAKFS_VERSION   1

/* Header is always 12 bytes. */
#define PAKFS_HEADER_SIZE 12

/* ── Internal state ───────────────────────────────────────────────────── */

typedef struct {
    const char  *name;       /* points into archive_buf */
    uint16_t     name_len;
    uint32_t     offset;     /* byte offset from start of archive_buf */
    uint32_t     size;       /* actual file size */
} PakEntry;

static uint8_t  *archive_buf  = NULL;
static uint32_t  archive_size = 0;
static PakEntry *entries      = NULL;
static uint16_t  num_entries  = 0;
static bool      initialized  = false;

/* ── Endian helpers (N64 is big-endian; archive is little-endian) ─────── */

static inline uint16_t le16(const uint8_t *p) {
    return (uint16_t)(p[0] | ((uint16_t)p[1] << 8));
}

static inline uint32_t le32(const uint8_t *p) {
    return (uint32_t)(p[0] | ((uint32_t)p[1] << 8) |
                     ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

/* ── Archive parsing ──────────────────────────────────────────────────── */

static bool parse_archive(void) {
    if (archive_size < PAKFS_HEADER_SIZE) return false;

    /* Check magic */
    if (memcmp(archive_buf, PAKFS_MAGIC, 4) != 0) {
        debugf("[pakfs] bad magic\n");
        return false;
    }

    uint16_t version      = le16(archive_buf + 4);
    uint16_t file_count   = le16(archive_buf + 6);
    uint32_t index_offset = le32(archive_buf + 8);

    if (version != PAKFS_VERSION) {
        debugf("[pakfs] unsupported version %d\n", version);
        return false;
    }
    if (index_offset >= archive_size) return false;

    entries = malloc(file_count * sizeof(PakEntry));
    if (!entries) return false;

    const uint8_t *p = archive_buf + index_offset;
    const uint8_t *end = archive_buf + archive_size;

    for (uint16_t i = 0; i < file_count; i++) {
        if (p + 2 > end) goto fail;
        uint16_t name_len = le16(p);
        p += 2;

        if (p + name_len + 10 > end) goto fail;

        entries[i].name     = (const char *)p;
        entries[i].name_len = name_len;
        p += name_len;

        entries[i].offset = le32(p);     p += 4;
        entries[i].size   = le32(p);     p += 4;
        /* flags */                       p += 2;

        if (entries[i].offset + entries[i].size > archive_size) goto fail;
    }

    num_entries = file_count;
    return true;

fail:
    free(entries);
    entries = NULL;
    return false;
}

/* ── Index lookup ─────────────────────────────────────────────────────── */

static const PakEntry *find_entry(const char *name) {
    /* Strip leading "pak:/" prefix if present */
    if (name[0] == 'p' && name[1] == 'a' && name[2] == 'k' &&
        name[3] == ':' && name[4] == '/') {
        name += 5;
    }
    for (uint16_t i = 0; i < num_entries; i++) {
        if ((uint16_t)strlen(name) == entries[i].name_len &&
            memcmp(name, entries[i].name, entries[i].name_len) == 0) {
            return &entries[i];
        }
    }
    return NULL;
}

/* ── libdragon filesystem vtable ──────────────────────────────────────── */

typedef struct {
    const PakEntry *entry;
    uint32_t        pos;
} PakFD;

static void *pakfs_open(char *name, int flags) {
    (void)flags;
    const PakEntry *e = find_entry(name);
    if (!e) { errno = ENOENT; return NULL; }
    PakFD *fd = malloc(sizeof(PakFD));
    if (!fd) { errno = ENOMEM; return NULL; }
    fd->entry = e;
    fd->pos   = 0;
    return fd;
}

static int pakfs_fclose(void *file) {
    free(file);
    return 0;
}

static int pakfs_read(void *file, uint8_t *ptr, int len) {
    PakFD *fd = file;
    uint32_t remaining = fd->entry->size - fd->pos;
    if ((uint32_t)len > remaining) len = (int)remaining;
    if (len <= 0) return 0;
    memcpy(ptr, archive_buf + fd->entry->offset + fd->pos, (size_t)len);
    fd->pos += (uint32_t)len;
    return len;
}

static int pakfs_write(void *file, uint8_t *ptr, int len) {
    (void)file; (void)ptr; (void)len;
    errno = EROFS;
    return -1;
}

static int pakfs_seek(void *file, int offset, int whence) {
    PakFD *fd = file;
    int new_pos;
    switch (whence) {
        case SEEK_SET: new_pos = offset; break;
        case SEEK_CUR: new_pos = (int)fd->pos + offset; break;
        case SEEK_END: new_pos = (int)fd->entry->size + offset; break;
        default: errno = EINVAL; return -1;
    }
    if (new_pos < 0 || (uint32_t)new_pos > fd->entry->size) {
        errno = EINVAL; return -1;
    }
    fd->pos = (uint32_t)new_pos;
    return 0;
}

static int pakfs_fstat(void *file, struct stat *st) {
    PakFD *fd = file;
    memset(st, 0, sizeof(*st));
    st->st_size = (off_t)fd->entry->size;
    st->st_mode = S_IFREG | 0444;
    return 0;
}

static filesystem_t pakfs_vtable = {
    .open  = pakfs_open,
    .close = pakfs_fclose,
    .read  = pakfs_read,
    .write = pakfs_write,
    .lseek = pakfs_seek,
    .fstat = pakfs_fstat,
};

/* ── Public API ───────────────────────────────────────────────────────── */

bool pakfs_init(const char *rom_path) {
    if (initialized) return true;

    /* Open archive via newlib/DFS — accepts "rom:/file.pakfs" or "/file.pakfs" */
    FILE *f = fopen(rom_path, "rb");
    if (!f) {
        debugf("[pakfs] failed to open archive: %s\n", rom_path);
        return false;
    }

    fseek(f, 0, SEEK_END);
    archive_size = (uint32_t)ftell(f);
    fseek(f, 0, SEEK_SET);

    /* Allocate 16-byte aligned buffer for DMA safety */
    archive_buf = memalign(16, archive_size);
    if (!archive_buf) {
        fclose(f);
        debugf("[pakfs] out of memory (%lu bytes)\n", (unsigned long)archive_size);
        return false;
    }

    fread(archive_buf, 1, archive_size, f);
    fclose(f);

    if (!parse_archive()) {
        free(archive_buf);
        archive_buf = NULL;
        return false;
    }

    /* Register "pak" scheme with libdragon */
    attach_filesystem("pak:/", &pakfs_vtable);
    initialized = true;
    debugf("[pakfs] mounted %d file(s) from %s\n", num_entries, rom_path);
    return true;
}

void pakfs_close(void) {
    if (!initialized) return;
    detach_filesystem("pak:/");
    free(entries);
    free(archive_buf);
    entries     = NULL;
    archive_buf = NULL;
    num_entries = 0;
    initialized = false;
}

const void *pakfs_get(const char *name, uint32_t *size) {
    const PakEntry *e = find_entry(name);
    if (!e) { if (size) *size = 0; return NULL; }
    if (size) *size = e->size;
    return archive_buf + e->offset;
}
