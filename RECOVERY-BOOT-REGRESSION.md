# Candidate boot regression investigation

The first combined candidate built Azahar with `ENABLE_VULKAN=OFF`. The user's
original bundled core contains `Vulkan::RendererVulkan` and Vulkan frontend
device negotiation; the candidate did not. Checking only Mach-O dependencies and
exported entry points missed this runtime capability difference. The frontend
owns the Vulkan/MoltenVK device, so the core does not need a direct MoltenVK
load command.

The user reported a responsive Manic app with a black Welcome amiibo screen
before trying AirPlay. This does not establish the exact cause of the game
failure, but the Vulkan capability mismatch is a concrete compatibility defect.
The user requested restoring Vulkan rendering. The iOS build now enables it.
The packager rejects a core without the Vulkan renderer's type information.

The GBA components and AirPlay framework remain the previously tested bytes.
All original Azahar exports, keyboard configuration fields, SDMC location, and
plugin loader patches are retained. Plugin startup is still a possible separate
failure source until a physical game test establishes otherwise.

Build/ABI checks and the synthetic UIKit/Metal AirPlay checks do not establish
that Welcome amiibo boots or that Vapecord runs. Device validation must be
reported separately. No game or save files belong in CI artifacts.
