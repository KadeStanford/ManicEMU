The bundled interpreter preserves its exclusive reservation across guest thread switches. Its `ARM_DynCom::ClearExclusiveState` is a no-op, and the kernel switch does not call the CPU monitor-clear method. In an actual ARM64 instruction harness, this lets a resumed thread's STREX overwrite a competing write and report success. This is a reproduced atomic correctness defect. Its relationship to the repeated Isabelle home-introduction freeze remains unproven.

The correction calls the existing CPU monitor-clear virtual method before the switch saves the departing guest context, and implements the missing DynCom clear. Existing JIT monitor clearing is reused. The upstream kernel change is independently visible in [Azahar #2376](https://github.com/azahar-emu/azahar/pull/2376); this backport does not replace the interpreter with FastInterp.

`repair_context_exclusive.py` accepts only exact FB2 or FB3 input hashes, verifies the kernel/vtable/clear ABI instructions, and rejects occupied executable padding. It changes two instruction sites and adds 84 bytes in existing padding. No heap allocation, GPU wait, guest code, plugin file, save, frontend option or bundle identity changes. Framework and app signatures must be renewed by the sole packaging owner.

Native regression evidence executes the actual kernel switch prefix, DynCom and JIT clear routines, SaveContext/LoadContext and LDREX/STREX handlers. MemoryRead/MemoryWrite are controlled shared-memory callbacks. The old core spuriously succeeds after a competing write; the correction fails that STREX and a subsequent retry progresses. Uninterrupted atomics and all GP/SIMD registers, SP and NZCV at the prefix boundary are preserved. Counts: 168 switch-prefix executions, 20 exclusive-handler executions, 12 context-save/load executions. These tests do not execute the full game, Vulkan, a physical phone or the remainder of the kernel switch.

Two local candidates distinguish this correction from the unsuccessful FB3 candidate:

| Candidate | SHA256 | Composition |
|---|---|---|
| FB2 + monitor correction | 3e7f1f1fedcc5bbbc19a9d42123934f132f43600a31cc927f6eca29ba73b5df3 | Preserved R5 plugin/Vulkan and FB2 startup repair; monitor correction only |
| FB3 + monitor correction | 7de82460deb3da6aeda143e8ddf0fe8e2bd36646808cf4ec0de9ca3d333dcb9a | Also retains FB3 per-core scheduling and duplicate-present changes |

FB3 failed the user's actual acceptance scene. It must not be treated as a known-good gameplay baseline. The first-house introduction halting at “Oh, and if you press the swi…” remains the acceptance target; the date/time introduction is intermittent. Neither new candidate has passed that scene, normal saving/reload, suspend/resume, repeated loading, long play or fast-forward on iPhone. No physical FPS improvement is claimed.

Reproduce locally on Windows with Python, Unicorn and Capstone available: `python Tests/test_context_exclusive.py --output <new-report.json>`. On other hosts set the dependency import path appropriately. Outputs are exclusive new files; originals remain intact.

This is a local review and replay handoff, not authorization to publish inputs or install another diagnostic IPA. Compare FB2, FB3 and monitor-corrected candidates in the private Apple runtime before selecting an integration candidate. Keep any game, save, plugin, screenshots and raw phone logs out of the public source tree and artifact archive.
