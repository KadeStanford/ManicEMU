# Original Manic Azahar 3GX repair

The user confirmed Welcome amiibo boots after restoring only the original Azahar
executable in R1. The April public source replacement does not boot it. The
original identifies itself as `4523838e2-dirty`, branch `manic`, built September
8, 2026; that commit is unavailable in the public fork.

The original already contains `Plugin3GXLoader::Load`, `Map`, the `plg:ldr`
service, `.3gx` validation, and the Luma title-folder scan. Its
`Core::System::Init` and `ApplySettings` copy the disabled loader flag into the service.
This repair replaces only their four flag reads with `MOV W9,#1`; the existing null
guard, stores, game loader, Vulkan/JIT implementation, symbols and ABI remain.

| Original instruction | Replacement | Effect |
| --- | --- | --- |
| `0x524954: LDRB W9,[X25,#0x650]` | `MOV W9,#1` | Enables the loader before process start |
| `0x52495C: LDRB W9,[X25,#0x678]` | `MOV W9,#1` | Allows the game to change loader state |
| `0x5281AC: LDRB W9,[X21,#0x650]` | `MOV W9,#1` | Next existing store enables `PLG_LDR::is_enabled` |
| `0x5281B4: LDRB W9,[X21,#0x678]` | `MOV W9,#1` | Next existing store enables `allow_game_change` |

`enable_3gx.py` requires the exact original core SHA-256 and exact instruction
bytes, rejects other versions, keeps the input untouched, and verifies every
byte outside the four instructions remains identical. Re-sign the modified core.
The source branch contains no core, IPA, game, or plugin binary.

The existing original scan uses uppercase 16-digit title folders. For USA Welcome
amiibo, use `3DS/sdmc/luma/plugins/0004000000198E00/` and a filename ending `.3gx`.
This repair preserves that existing lookup behavior. The April source patch's
lowercase fallback is not present in this original executable. A `.3gz` or
`.3dsx` filename does not match its `.3gx` scan.

Machine-code verification and packaging checks cannot establish physical plugin
execution. That requires launching the existing game and opening Vapecord's menu
on the user's device. Original-core boot is already confirmed independently.

The private integrated simulator comparison at run `37158036864` executed the
matching original core with Software rendering. The enabled-loader job completed
2,373 `retro_run` calls with 2,272 nonblack frames and no native fatal signal.
After A acknowledged the plugin's notice, the encrypted frame at call 1,800
showed New Leaf's title screen with the plugin-ready overlay. After Select at
call 2,000, the encrypted frame at call 2,050 visibly shows the Vapecord USAWA
5.4.0 menu with code categories and touch controls. This establishes plugin
initialization and Select-menu operation in that simulator configuration;
it does not establish physical Vulkan compatibility. The phone
uses Vulkan and previously exited with SIGSEGV after the uppercase plugin copy
was introduced. The added diagnostic copy is disabled pending a controlled test.

Private inputs and detailed runtime evidence are absent from the source branch.
Public diagnostic artifacts contain a sanitized summary and encrypted evidence.

The October 4 Vulkan investigation identified two separate presentation defects.
Phone Trace2 passed an uninitialized image to an early `FillScreen` clear. R4
allocates that texture through the existing framebuffer initializer; R5 also
refreshes the sampled view that `SwapBuffers` cached before allocation.

With R5, native ARM64 Vulkan run `37170555912` stalled with duplicate-frame
skipping enabled, while disabling only that option completed 3,600 calls and
visibly opened the supplied Vapecord menu. The user independently confirmed the
same workaround on the phone: Vulkan runs, Select opens and closes the menu, and
the game continues. CPU-drawn plugin frames can change while the original GPU
frame-change marker stays clear, starving the frontend frame/input cycle.

`repair_vulkan_plugin_present.py` retains the original duplicate-frame policy
when no plugin framebuffer is mapped. When the original loader's framebuffer
address is nonzero, its 40-byte wrapper resumes the existing presentation path.
The address comes from the original `Plugin3GXLoader::Map` store and is cleared
by the original teardown. The wrapper initializes the original frame-marker
pointer, changes no user setting, and makes no function calls. Exact original/R5
hash and instruction guards reject unknown binaries. The ARM64 execution test
covers mapped/unmapped state, both setting types, and register/flag preservation.
R6's native game/menu comparison and physical phone verification are separate
from the confirmed R5 workaround; a passing build alone does not establish them.
