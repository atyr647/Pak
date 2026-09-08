# CHROMA nave on the Pak standalone RDP

`church.pk64` draws the nave with textured, Z-buffered triangles on the
standalone backend: **no libdragon, no RSP**. The CPU builds an RDP display
list in uncached RDRAM and hands it to the DP. That is the same boot path FZ
already runs, which is why Parallel/Angrylion should eat it.

## Why it streams

The linker puts `.text/.rodata/.data/.bss` at `0x80000400` and errors if they
reach FB0 at `0x80200000` — about **2 MB** of room.

Eighteen 256×256 RGBA16 sheets are **2.25 MB**. Embed them and you are not
"slightly over budget", you are writing texels over the framebuffers. Same
crash class as the old 2.9 MB ROM, just quieter.

So nothing in this scene is a texture. The cart holds the pages; one 2 KB page
at a time lands in RDRAM. The nave costs **~48 KB** of code and data, leaving
1.95 MB free — `tcl/tools/church_test.tcl` asserts both numbers.

## Cart layout contract

| | |
|---|---|
| Page format | 32×32 RGBA5551, **2048 bytes**, no header |
| Page *n* at | `PAGE_BASE + n * 2048` |
| `PAGE_BASE` | `0x10200000` (cart address, i.e. ROM offset `0x200000`) |

The linked payload starts at ROM `0x1000` and is far smaller than `0x200000`,
so the packer appends the atlas past it without touching the program. A 4 MiB
ROM leaves ~2 MB of atlas space — enough for ~1000 unique pages.

Reading unwritten padding yields black pages. That is deliberate: a scene that
renders black is legible, a scene that faults is not.

## Per-page pipeline

    cache.writeback -> dma.read -> dma.wait -> cache.invalidate   (E201/E202)
    set_texture_image(KSEG1 alias)                                (E203 if KSEG0)
    set_tile_mask(clamp/clamp, mask 5)                            (5 = log2 32)
    load_tile -> set_tile_size -> sync_tile
    set_tri_z -> triangle_tex_z x2

The texture image is the **KSEG1 alias** of the scratch buffer. The DP reads
RDRAM, not the d-cache; handing it a KSEG0 pointer is `E203`.

`mask 5` matters more than it looks. Without it S and T wrap past the page
edge into whatever texels the *next* page left in TMEM, and the seams between
bays smear.

## Known limits

- **Affine ST.** `1/w` is stubbed in the runtime, so ST is affine. One page per
  quad keeps every triangle small enough that it does not show. Widen the bays
  and the texture will swim.
- **`triangle_tex` does not draw correctly yet.** This is the blocker for the
  nave, found by `tcl/tools/pixel_test.tcl` rendering on angrylion. A filled
  `rdpq.triangle` covers exactly its geometry, and a `texture_rectangle`
  samples exactly the texels it was handed (verified: a half-red/half-blue page
  comes back 12800 red and 12800 blue pixels). But `triangle_tex` with the same
  vertices as a working filled triangle emits **byte-identical edge words** and
  still rasterises a different, smaller shape in white — so the fault is in the
  eight double-words of texture coefficients, not in the geometry or in TMEM.
  Reordering them to int(S)/int(DsDx)/int(DsDe)/int(DsDy) then the four
  fractions did not change the output, so the layout is not the whole story and
  that change was not kept. Until this is fixed the nave draws untextured.

- **The pixel gate does not cover the church itself.** The simulator does not
  perform PI transfers -- `dma_read` writes the PI registers and returns -- so
  the scratch page stays zero and the nave would render black even once
  `triangle_tex` works. Making the sim honour PI DMA is the prerequisite for a
  church screenshot.
- **Page residency is naive.** Bays beyond the third reuse one far set of
  pages, so walking forward does not thrash the PI. There is no cache and no
  eviction policy; every visible face re-DMAs its page every frame.

## Building

    pak asmobj runtime/standalone/boot.S       -o boot.pakobj
    pak objgen runtime/standalone/runtime.pk64 -o runtime.pakobj
    pak objgen examples/chroma/church.pk64     -o church.pakobj
    pak link boot.pakobj runtime.pakobj church.pakobj -o church.z64 --name "CHROMA CHURCH"

Then append the page atlas at ROM offset `0x200000`.

## Naming

Pak's `rdpq.set_key_r` / `set_key_gb` are the RDP's **chroma-key** registers —
a transparent colour. That is unrelated to **CHROMA64**, the reconstruct. Same
word, different hardware.
