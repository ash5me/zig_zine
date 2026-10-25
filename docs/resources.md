# Resources: CPU-side Asset Caches

**Status:** Partial. Texture decoding is implemented and tested. GPU upload, shader loading, and font loading are not implemented. `FontCache` and `ShaderCache` are stubs.

`src/resources.zig` is the single place that turns asset files into memory the engine can use. This document records why it is built the way it is, so changes to it can be checked against the reasons.

## Why zstbi

PNG decoding is done by `zig-gamedev/zstbi`, a Zig wrapper over stb_image. It replaced an earlier libpng dependency.

- One dependency covers PNG and the other formats stb_image supports, so the project does not link a separate PNG library.
- The stb C sources are compiled by the package's own root module, so the build needs no system image library. It does require `link_libc`, which `build.zig` sets.
- The trade-off: edge-case behavior (16-bit data, palette images, grayscale) is whatever stb_image does. The code relies on zstbi's conversions and does not reimplement them.

## Decode boundary

The cache stops at pixels in system memory. Uploading to a `VkImage` needs command buffers, staging buffers, and layout transitions, and none of that exists yet. Keeping decoding free of the GPU means it can be unit-tested without a device.

## Pixel format

Every texture is decoded to four channels (RGBA). stb_image expands grayscale, grayscale-with-alpha, RGB, and palette PNGs, and fills alpha with 255 when the file has none. The future GPU upload path then needs to handle only one pixel layout.

`Texture.pixels()` returns tightly packed rows, top row first.

16-bit PNGs: `Texture` carries a note that `image.bytes_per_component` may be 2 and that callers should check it before assuming 8-bit data. **To verify:** whether zstbi's loaders ever return 16-bit data for a 16-bit PNG when `texture_channels` is 4. If they always convert to 8-bit, the note and any check for it can go.

## Ownership and caching

- `TextureCache` owns every `zstbi.Image` and every key string it stores. Callers pass keys and paths; the cache copies them.
- `getOrLoadFile` and `getOrLoadMemory` return a `*Texture` that the cache owns. Callers must not free it. The pointer stays valid until `TextureCache.deinit`.
- `insert` takes ownership of an `Image` and frees it on every error path. The `errdefer` chain ensures each allocation is freed exactly once.
- Each `Texture` is heap-allocated, so its address is stable as the hash map grows.

**Identity.** Today, callers refer to textures by pointer. ARCHITECTURE §5.16 calls for handles. A handle type should be decided before GPU upload begins, because the renderer will need a stable way to refer to textures.

**zstbi is process-wide.** `TextureCache.init` calls `zstbi.init`, and `deinit` calls `zstbi.deinit`. zstbi keeps its allocator in a global, so only one `TextureCache` should be alive at a time. The current tests run one at a time and satisfy this.

**File paths.** `getOrLoadFile` takes a path relative to the working directory. There is no asset root yet. Introduce one with the asset-loading work in roadmap step 4.

## Stubs

`FontCache` and `ShaderCache` return `error.FontLoadingNotImplemented` and `error.ShaderLoadingNotImplemented`. They fail loudly instead of returning blank data. Their `Font` and `Shader` types contain only a placeholder field.

Shader loading needs SPIR-V and a Vulkan device, so it belongs with the renderer. Fonts have no consumer yet.

## Built-in placeholder

`placeholder_png` is a 2×2 RGBA image: red and green on top, blue and white on the bottom, with the white pixel at alpha 128. It is embedded in the binary and used for two things: as a test fixture, and as a smoke test that the zstbi path is linked and working on every run of `main`.

## Tests

The tests use embedded PNG bytes, so they need no files on disk and no GPU. They cover:

- an RGBA PNG decodes to the exact expected pixel bytes;
- an RGB PNG expands to RGBA with opaque alpha;
- a repeated key returns the same cached pointer and does not add an entry;
- invalid bytes fail to decode and leave the cache empty;
- the font and shader stubs return their "not implemented" errors.

## Open items

- Verify the 16-bit behavior described above, then keep or remove the `bytes_per_component` note.
- Decide the texture reference style (pointer or handle) before GPU upload.
- Define the asset root for `getOrLoadFile`.
- Hot reload is not planned until roadmap step 15.
