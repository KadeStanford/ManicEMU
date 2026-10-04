// Review source for the 40-byte original-core wrapper at 0xD4C200.
// RenderToWindow has saved x24 and initialized x20=this before this gate.
// The wrapper uses scratch x8; it makes no calls and changes no stack or flags.
ldr x8,[x20,#0xb8]       // RendererVulkan::memory, original constructor +0x9F6E40
ldr x8,[x8]             // MemorySystem::Impl
add x8,x8,#0x18,lsl #12
ldr w8,[x8,#0x740]      // original plugin framebuffer address
cbz w8,normal
adrp x24,0xFC2000
add x24,x24,#0xE38      // initialize original frame-change pointer before present
b 0x9FC408
normal:
ldrb w8,[x25,#0xBE8]    // relocated original instruction
b 0x9FC3B4
