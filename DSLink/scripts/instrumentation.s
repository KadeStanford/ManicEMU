// Review source for patch_core.py's exact arm64 words; no runtime code patches.
// Custom environment command 0x4D445301 carries event + optional Packet pointer.
on:
    mov w0, #1
    mov x1, xzr
    b signal
off:
    mov w0, #2
    mov x1, xzr
    b signal
send:
    cbz x0, activity
    mov x21, x0
    b 0x3aaa4 // Original ready path, engine packet sending unchanged
activity:
    mov w0, #3
    mov x1, x19 // Existing Packet&, inspected synchronously only
    bl signal
    mov x0, xzr // Preserve original false return when not yet connected
    b 0x3aab4 // Existing caller-owned epilogue
signal:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
    str w0, [sp, #16]
    str wzr, [sp, #20]
    str x1, [sp, #24]
    mov w0, #0x5301
    movk w0, #0x4D44, lsl #16
    add x1, sp, #16
    adrp x8, 0x2b5000
    ldr x8, [x8, #0x740] // Original core's environment callback
    cbz x8, return
    blr x8
return:
    ldp x29, x30, [sp], #48
    ret
