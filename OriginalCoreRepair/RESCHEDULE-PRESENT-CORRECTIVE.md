The reviewed FB2 core still contains two old control-flow defects. This isolated
correction keeps its startup framebuffer fix, forced Vapecord loader, interpreter,
JIT and existing Vulkan renderer, while changing only scheduling and the duplicate
presentation shortcut. It is a concrete correction, not another diagnostic recorder.

Changes

1. Backport the behavior of official Azahar #2370:
   https://github.com/azahar-emu/azahar/pull/2370
   Consume a pending request after each executing core's slice, and reschedule only
   that core's ThreadManager. The bundled binary formerly waited until RunLoop's
   tail and rescheduled every manager. Upstream demonstrated an inter-core freeze
   in the New 3DS browser; that is not a reproduction of New Leaf's Nookling freeze.
   Existing ready-queue and context-switch routines are reused. The bounded native
   helper preserves all 31 GP and 32 SIMD registers, SP and NZCV. No allocation,
   logging or guest/options memory mutation is added. The pending path uses 784
   bytes of additional stack plus the 16-byte wrapper. No-request loop overhead is
   nine extra native instructions; physical performance has not been measured.

2. Remove the single duplicate-marker early-return instruction at 0x9fc404.
   It can suppress RenderToWindow's submit, frontend delivery and event polling.
   Preserve the existing draw, resize wait, callback, second-window flags and return.
   Official upstream #2530 also disables duplicate skipping by default because of
   game regressions: https://github.com/azahar-emu/azahar/pull/2530
   This correction forces delivery independent of an old saved skip setting.
   It may increase GPU work when identical frames were previously skipped.

Reproducibility and scope

Start from exact FB2 SHA256
3995bab1659c74979fa81226e4961fc7634d30a324ba9b97eb0eb50b5dc892e4.
Run make_fb2_present_control.py, then repair_core_reschedule.py on its output.
Final SHA256:
15d9b1e984155a72d1f1ef5f2dadc014b3664b5c4d74b71ea8603503f491009a.
The second script accepts only the two reviewed FB2 hashes, original-site words,
and unused executable padding. Output is exclusive-create. Original input is checked
unchanged. No source/core upgrade: the bundled dirty commit cannot be reproduced
from currently available upstream source. Reviewable generation and native tests
are supplied instead of substituting an incompatible broad rebuild.

Tests on the final combined bytes

- 133 ARM64 ABI/scope/pending/null/reentrant executions. Old negative control
  reschedules [0,1,2,3] for core 2; correction reschedules [2].
- 98 actual four-core RunLoop executions, covering Run, Step, idle and each core's
  requests. Native down-counter budget and idle accounting remain correct. The
  request is consumed before the next core runs instead of at the frame tail.
- 7,680 complete native RenderToWindow calls in 64 repeated synthetic sessions.
  Old duplicate-marker control delivers zero of 120 frames; correction delivers
  all 120. Normal delivery, resizing/full wait, copied image layout, direct/global
  settings, second-window flags and callee-saved returns pass.

These execute actual ARM64 instructions under Unicorn with controlled CPU/kernel
and GPU/frontend helpers. They do not execute a real GPU, guest scheduler, game
saves or UIKit. Prior macOS ARM64/MoltenVK game evidence reproduced the original
duplicate-on stall at 129 run calls/128 frames; duplicate-off/R6 controls completed
3,600 calls and clean unload. Preserved images show the New Leaf title screen,
Vapecord menu open, closed and reopened. This was title/menu testing, not town
gameplay, Nookling entry, normal saving, long play or a test of this new scheduler.
The old summary's five nonblack frames are five readback checkpoints, not proof
the other frames were black. Simulator/macOS findings do not prove iPhone behavior.

Frozen-run evidence and remaining limitations

Phone captures during fast-forward and Nookling entry show active interpreter and
Vulkan paths with continuing audio; turning fast-forward off does not recover the
image. A persistent full native-thread deadlock or fence wait was not established.
Plugin-off fast-forward also reproduced the symptom. Stable Nookling footprint
and transient fast-forward growth do not establish a leak. The corrections remove
verified defective mechanisms, but no causal proof ties either to every phone freeze.
No phone FPS gain, repeat cold boot, normal save/reload, suspend/resume, long session,
or Nookling success is claimed for this new core.

The bundled Vulkan texture GC also uses frame age rather than completed GPU work.
Official #2407 addresses this class with resource ticks:
https://github.com/azahar-emu/azahar/pull/2407
A safe exact backport needs retirement-timestamp changes at every enqueue site
and validated semaphore semantics. Adding blanket GPU waits or disabling deletion
would trade speed or memory for speculation, so this candidate leaves GC unchanged.
This remains a specific follow-up rather than a claim that resource corruption was
observed in the secured phone captures.

Integration

Only the sole DS/frontend packaging owner may replace the Azahar framework entry
in the latest primary IPA, audit every other entry, then re-sign framework and app.
Keep the existing bundle identity and retained working IPA. No app installation,
live settings/save changes, shared frontend edits, private evidence upload or new
public source publication occurred. Windows has no Xcode/iPhoneOS simulator SDK;
this deliverable is a guarded patch of the existing iOS ARM64 binary, not a claimed
fresh Xcode build. The owner can package it without rebuilding the entire core.
