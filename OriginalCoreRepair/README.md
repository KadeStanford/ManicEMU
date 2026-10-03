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
