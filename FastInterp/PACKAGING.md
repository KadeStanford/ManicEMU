# Combined IPA packaging

Use the exact Downloads FB3 IPA (SHA256 6a2e3c999bd26c0529f5d04c512caa32c938cd243ed68474c1cb50d0d20ea860) as the baseline. Do not rebuild or replace its DS R6, DSOriginal, gpSP v0.7, Libretro FB3, AirPlay R10, GBA shim, Vapecord assets or existing Azahar FB3 framework.

The new source-built ManicEmuSideload executable must come from the independent app build, not a staged source app containing a compiler-fixture core. The distinct azahar-fastinterp.libretro binary must come from the corrected official-source iPhoneOS build. Its install identity is @rpath/azahar-fastinterp.libretro.framework/azahar-fastinterp.libretro. Reject simulator or Mac binaries.

Run FastInterp/Tests/package_preserved_baseline.py with:
- positional exact baseline IPA path
- --executable source-built app executable
- --core actual iPhoneOS azahar-fastinterp.libretro binary
- --framework-plist Cores/azahar-fastinterp.libretro.framework/Info.plist
- --output new, non-existing IPA path
- --report new, non-existing JSON path

The packager changes one old entry (main executable), adds only the new framework executable and metadata, retains all other original entries byte-for-byte, restores all three original direct injections in order and verifies new imports against preserved embedded framework exports. It reopens the output for entry-set, CRC, bundle metadata, core exports/platform/install-name and injection checks. No signing or installation occurs.

Before delivery also confirm native loaded-image tests distinguish Azahar from Azahar FastInterp and that the final app compiled. The real Swift registry/model contract checks indices, separate framework paths, JSON index persistence and switch-back; it does not cover Realm or physical UI.

Coverage must explicitly state that Isabelle's first-house freeze, actual-game speedup and new phone feature acceptance are unverified. Baseline physical acceptance belongs to preserved components; static activation/ABI checks cannot guarantee the rebuilt app's physical behavior. The original Azahar choice remains index 1, FastInterp is index 2, normal saves use existing locations and cross-core serialized states are guarded.

