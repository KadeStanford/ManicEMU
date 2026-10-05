# Bounded elapsed time for frontend fast-forward frame skipping

The bundled frontend narrows the elapsed host-frame interval to uint16_t. An
interval of 65536 microseconds consequently becomes zero. Repeated intervals of
that duration never refill the frame accumulator, suppressing every frame even
while emulation continues. Long intervals now saturate at 65535 microseconds.
The accumulator remains bounded and intervals below the boundary keep their
existing behavior. Normal-speed, menu and first nonduplicate frame gates remain.

The source equivalent targets Daiuno/RetroArch commit
00689c83f4d458e061d5fd7b52a181b8d240fe65, gfx/video_driver.c. The native correction
accepts only the exact shipped Libretro SHA256 recorded in the builder. It edits
the existing frame-time arithmetic and leaves unrelated interleaved instructions,
entry points, load commands, resource callbacks and the rest of the binary intact.
The original source's unsigned timestamp arithmetic is retained across long
pauses and low32/uint64 wrap boundaries; no widening signed-overflow risk is added.

The local native regression reads the actual shipped binary and executes its
unchanged gate and the corrected gate using Unicorn. CI uses a code-only fixture
of those same instructions. The Simulator harness relocates branch labels and
the original global state-page address into callable ARM64 routines, executing
the timing instructions on an iPhone Simulator. Neither test runs New Leaf, a
game plugin, a real MoltenVK swapchain or iPhone networking. No game, firmware,
save, screenshot or phone trace is included or uploaded.

This corrects a demonstrated frontend timing defect. It does not establish the
mechanism of the normal-speed Nookling Junction freeze or prove recovery of
physical fast-forward freezes. Core scheduling, duplicate-presentation and GPU
retirement corrections are a separate owner's scope. No phone test is requested.
