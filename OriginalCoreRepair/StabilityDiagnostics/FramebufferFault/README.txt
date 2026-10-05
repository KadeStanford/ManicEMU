This is a narrowly targeted framebuffer failure diagnostic, NOT a repair.

Fresh Oct5 Apple reports twice identify the preserved R5 Vulkan
LoadFBToScreenInfo ASSERT(false), PC+0xa80118, after AccelerateDisplay returns
false. Exact preserved instructions show two return reasons:zero address, or
invalid GetSurfaceSubRect result. GetSurfaceSubRect itself rejects zero width
or height. Public source independently agrees, but is not the exact working
core's private revision. Current logs cannot distinguish these conditions.

The experiment leaves the fatal assertion/log shutdown and valid rendering
path intact. It captures selected framebuffer ADDRESS and CONFIG metadata,
not guest framebuffer pixels, plugin contents, firmware or saves. It adds no
allocations, files, signals, callbacks, core option changes or per-frame logs.
Two instructions are redirected;48 bytes are added in unused executable
padding. The exact R5/R6 hashes, original instructions and Mach-O mapping are
guarded. Unknown, already modified and occupied-padding binaries are refused.
Originals are read only; outputs must be new files. No combined IPA is produced.

On failure,the original ASSERT log and Stop execute. The breakpoint becomes:
  core+0xd4c350, BRK#0x4d01:ZERO selected framebuffer address.
  core+0xd4c34c, BRK#0x4d02:NONZERO address, invalid cache surface.
ARM64 fault registers then carry:
  x8:selected physical framebuffer address (32bits).
  x9:width low16 bits; height high16 bits.
  x10:pixel stride low32 bits; GPU pixel format high32 bits (0..4).
Original UUID remains77f4a4b3-3a4c-35a8-8b2d-8be6268bb763. The output hash in
the manifest identifies the experiment; UUID alone cannot attest core bytes.
Stack/framepointer and logging ABI are retained. The diagnostic adds seven
native instructions per successful display call; no physical FPS/overhead
claim follows from that instruction count.

Local creation (Python standard library; no Xcode/macOS build required):
  python instrument_framebuffer_fault.py --input PRESERVED_CORE --output NEW_DIAGNOSTIC_CORE
ARM64 verification (existing capstone/unicorn dependencies):
  python test_framebuffer_fault.py --r5 R5_CORE --r6 R6_CORE --deps DEPENDENCY_DIRECTORY --output NEW_REPORT
Apple report decoding, locally only:
  python decode_framebuffer_fault.py --report NEW_REPORT.ips --output NEW_PRIVATE_SUMMARY.json
The decoder requires the new PC, expected UUID and bounded registers; it
rejects old reports rather than reinterpreting arbitrary volatile registers.

Integration handoff:only the sole combined-IPA packaging owner may replace
the Azahar entry in its next isolated experimental candidate. Use the R5
diagnostic for the current R5 baseline. R6 support preserves its existing
extra guard if separately chosen; this is unrelated to the working DS R6 fix.
Verify the input/output hashes, changed-byte whitelist and existing payload
preservation. Re-sign the embedded framework and app; preserve the app bundle
identity and all DS/GBA/AirPlay/MoltenVK/plugin/settings/assets. Never install
from this task. The user/owner coordinates installation and a controlled
launch. Keep a working candidate for rollback. No private input or report may
be uploaded in a public workflow. New public publication is not needed to
generate this diagnostic locally and has not been performed.

Physical experiment needed:repeat ONE previously failing New Leaf/Vulkan/JIT
OFF launch with existing plugin support, then read the new Apple .ips through
the existing authorized trusted connection. Check core+0xd4c350 vs0xd4c34c and
decode only its bounded metadata. A different crash PC must be analyzed
separately. If the issue reproduces,compare a plugin-enabled launch and an
authorized plugin-disabled control; preserve copies and normal settings.
This diagnostic deliberately does not prevent the observed crash. Do not
present crash avoidance or game success as its outcome.

If ZERO address or ZERO geometry is confirmed,next repair should safely
defer/clear display of an uninitialized framebuffer and resume normal display
when registers become valid. If NONZERO valid geometry fails,the cache/upload
path needs investigation and an actual framebuffer upload fallback where
appropriate. Do not remove ASSERT(false) and sample stale/uninitialized pixels.
Any corrective candidate needs Vulkan/plugin enabled/control,JIT/interpreter,
normal save/reload,suspend/resume,repeated load/cleanup and longer physical
sessions. These tests are not completed by the bounded instruction harness.
This startup experiment does not prove a fix for the older random freeze.

Verification completed locally:220 paired cases /440 actual ARM64 routine
executions across exact R5 and R6;40 normal-path register/stack preservation
cases;120 real zero-geometry guard cases. All pass. The four decoder fixtures
pass and old assertion-PC reports are rejected. These are bounded native
instruction tests with controlled nonzero cache/logging helpers, not a
simulator game run or MoltenVK/physical GPU regression.
