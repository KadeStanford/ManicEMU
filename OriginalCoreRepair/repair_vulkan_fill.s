// Wrapper encoded at original __TEXT zero padding 0xd4c100.
// Only exact original Manic cores pass the Python patcher's hash guard.
// Entry 0x9fb28c branches here; existing framebuffer config stays authoritative.
stp x29, x30, [sp, #-64]!
mov x29, sp
stp x19, x20, [sp, #16]
stp x21, x22, [sp, #32]
mov x19, x0
mov x20, x1
mov x21, x2
ldr x8, [x2, #16]
cbnz x8, ready
ldr x8, [x19, #192]
sub x9, x21, x19
mov x10, #15832 // Renderer bottom texture offset 0x3dd8
cmp x9, x10
mov x9, #5120 // GPU top framebuffer config 0x1400
mov x10, #5376 // GPU bottom framebuffer config 0x1500
csel x10, x10, x9, hs
add x2, x8, x10
mov x1, x21
mov x0, x19
bl 0x9fb388 // ConfigureFramebufferTexture
ready:
mov x0, x19
mov x1, x20
mov x2, x21
ldp x21, x22, [sp, #32]
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp], #64
stp d11, d10, [sp, #-64]! // Original first instruction relocated
b 0x9fb290 // Resume the remaining original FillScreen
