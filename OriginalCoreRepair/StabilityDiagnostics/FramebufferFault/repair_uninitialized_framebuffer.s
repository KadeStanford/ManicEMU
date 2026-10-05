// FB2:zero-address guard at0xd4c400; generated from exact R5/R6/FB1 hashes.
// Replace call-site B at0x9fc318 with B0xd4c400.
// Normal path keeps FB1 metadata and original AccelerateDisplay behavior.
    cbz w2, missing_framebuffer
    b 0xd4c300
missing_framebuffer:
    mov w8, #0x2150
    sub x0, x0, x8 // recover renderer from its rasterizer member pointer
    mov w1, #0     // packed RGB black
    mov x2, x19    // owned TextureInfo at ScreenInfo base
    bl 0x9fb28c    // existing R5 FillScreen, including image initialization guard
    ldr x9, [x19, #0x18]
    mov x8, #0x3f8000003f800000
    str xzr, [x19, #0x28]
    stp x8, x9, [x19, #0x30] // full coordinates and owned image_view
    b 0x9fc320 // unchanged stack guard and epilogue
