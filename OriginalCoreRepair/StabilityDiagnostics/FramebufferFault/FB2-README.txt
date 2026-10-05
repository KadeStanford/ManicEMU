FB2 experimental corrective handoff:uninitialized framebuffer presentation

Root cause identified with fresh physical FB1 evidence at17:21:09UTC Oct5:
core+0xd4c350, framebuffer address0,pixel stride0,width240,height400,format0.
Expected core UUID, process2155 and recorder image base0x1326cc000 match.
This is presentation of an uninitialized framebuffer, not a proven GPU cache
resource failure. The phone was reported running New Leaf with JIT OFF.
The packaged FB1 core independently matched the generated diagnostic hash.
Full Apple reports/native stacks remain private and are not in this handoff.

Correction
When the selected framebuffer address is zero,call the existing R5 FillScreen
with RGB black. It initializes a missing owned texture using its existing R5
guard,records a black clear,sets full texture coordinates and the owned image
view,and returns through the original stack guard/epilogue. The emulation
continues and the next initialized framebuffer uses normal Vulkan display.
This avoids presenting stale/uninitialized pixels or simply removing ASSERT.
Nonzero addresses keep original AccelerateDisplay/cache behavior. Original
stride assertions and nonzero cache-failure assertion remain. The FB1 bounded
register diagnostic is retained for a later nonzero cache failure.
No CPU mode,plugin flags,Vulkan options,frame skipping,guest memory,save,
settings,driver,frontend,shared rendering,DS,GBA,AirPlay or app identity change.

Exact corrective R5 binary:
SHA2563995bab1659c74979fa81226e4961fc7634d30a324ba9b97eb0eb50b5dc892e4
Direct accepted current FB1 input:
SHA25666df36d8d88e0c67c9cf1a3694cb6b4fc24473a751fa4caa3dd7cef7f179a6d7
The script also accepts exact preserved R5/R6 baselines or R6-FB1. Unknown and
already corrected inputs are rejected. New output paths are mandatory.
Relative to FB1,only4 bytes at0x9fc318 and48 bytes at0xd4c400 change.
The cave is verified unused existing executable padding. No new load commands,
code dependencies,stack frame,heap allocation or per-frame disk/logging added.
The normal path adds2 native instructions relative to FB1;physical FPS and
sampling overhead are not quantified by that count.

Tests passed
976 actual ARM64 routine executions:360 paired FB1/FB2 cases (720 executions)
plus256 same-instance zero/valid transitions across exact R5/R6 variants.
Top/right/bottom screens,new/existing owned images,all five valid pixel formats,
normal display,invalid cache,nonzero zero stride and both original malformed
stride assertion controls.60 clear commands verified their actual image and
RGBA(0,0,0,1) payload. Preserved R5 FillScreen wrapper and clear-recording bytes
execute;one image allocation is reused across each128-call transition run.
GP and FP callee-saved registers,stack and framebuffer configurations match
their contracts. Image allocation,nonzero cache acquisition and EndRendering
helpers are controlled stubs;actual GPU execution/phone pixels are untested.
The corrected FB1 harness also passes440 native executions and4 decoder tests.
The earlier harness incorrectly stopped before the replacement trap branch;
that hook is corrected here and classifier metadata now actually executes.
The physical FB1 crash independently validates the same classifier/metadata.

Packaging owner instructions
The user explicitly requested a new phone-test IPA after the finding. ONLY the
existing DS/combined packaging owner assembles it;this task creates no IPA and
does not install over the user's app. Use the exact current DS-R6/FB1 candidate:
ManicEMU.v2.0.1.GBA-v0.7-Vapecord-Vulkan-AirPlay-R10-DS-v0.10-R6-Azahar-FB1-FaultDiagnostic-Experimental-Unsigned.ipa
SHA2563dfae7fbbecd004ffaa7a47af465d3bb752ced71f2c3af92aa282cd460db69d2
Replace ONLY:
Payload/ManicEmuSideload.app/Frameworks/azahar.libretro.framework/azahar.libretro
with the above R5-FB2 binary. Preserve the input,write a new candidate,verify
archive integrity and audit all888 other entries byte-identical before normal
framework/app sideload re-signing. Keep app bundle identity unchanged. Keep the
working candidate for rollback. New Xcode/macOS build or public push is not
needed:the guarded native instructions are generated locally. Publish/upload
no private game,firmware,plugin,save or phone data.

Physical acceptance still needed
First reproduce a no-JIT New Leaf launch on the user's phone with existing
Vulkan/Vapecord configuration. Require progression beyond initial blank screen
into updated gameplay/audio,then plugin menu open/close with game continuing.
If the screen stays black,capture native CPU/threads while it remains running:
avoiding exit alone is not rendering success. Analyze a new different crash
separately;the nonzero FB1 classifier remains available. Check plugin control,
JIT/interpreter,normal save/reload,suspend/resume,repeated load/cleanup and a
longer session as relevant,using authorized copies and preserving real saves.
Do not claim elimination of random gameplay freezes,crashes or slowdowns.
