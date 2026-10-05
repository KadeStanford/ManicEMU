// Diagnostic only; addresses refer to the hash-verified R5/R6 ARM64 core.
// Replace BL at 0x9fc318 with B 0xd4c300; existing arguments remain unchanged.
// The existing routine saves x20 and never otherwise uses it before restoring.
// Its sp+0..7 bytes are unused on this path; sp+8 is the stack guard.
// No new stack frame, guest pixel reads, heap objects, files, or logging calls.
// Capture stub at 0xd4c300:
    ldr w8, [x1, #0x5c]
    stp w2, w8, [sp]
    ldr w8, [x1, #0x70]
    and w8, w8, #7
    orr x20, x3, x8, lsl #32
    bl 0xa20cb8 // original AccelerateDisplay
    b 0x9fc31c  // original return-bit test and rendering path

// Replace original BRK at 0xa80118 with B 0xd4c340. Original ASSERT log,
// logging shutdown, and lambda stack frame have all executed unchanged.
// Classifier at 0xd4c340:
    ldp w8, w9, [sp, #16] // caller sp+0, because lambda subtracts16
    mov x10, x20         // pixel stride | (format <<32)
    cbz w8, zero_address
    brk #0x4d02          // 0xd4c34c:nonzero address, invalid surface
zero_address:
    brk #0x4d01          // 0xd4c350:zero address; outcome remains fatal
