This is an optional diagnostic component, not a freeze or performance fix.

Problem: the latest DS-v0.7 / AirPlay-R8 IPA contains no fault or hang recorder.
The old startup snapshots stop after 50 seconds and cannot identify a later
intermittent freeze. The phone currently closes the live-log service. The
working core's exact private source revision is unavailable in the public fork.

The new component records own-process CPU time, native PC/LR, bounded thread
stacks, memory footprint, peak resident memory, thermal state, image add/remove
events, and sampling cost. It samples only while the Azahar image is loaded,
every 15 seconds, for at most four hours. Eight rolling files retain about two
minutes of history per app launch. Stack content remains private diagnostic
evidence. It must never be uploaded publicly or bundled into a source commit.

The sampler does not call core functions, flush GPU memory, suspend threads,
read guest RAM/saves, change core options, or install signal handlers. Apple
crash reporting stays in its existing state. Thread snapshots are best-effort
observations, not coherent snapshots or proof of a deadlock. Resident/footprint
growth suggests a retention problem; it does not independently prove a leak.

This framework must remain loaded for the process lifetime. The single IPA
packaging owner can integrate it as an optional APP dependency, after owner
coordination, preserving the app bundle identifier and signing all frameworks.
Do not add it as an unloadable core dependency: dyld image callbacks and timer
callbacks must not outlive their code. This task has changed no app/frontend
load commands or combined IPA. Native compilation and the included self-test
must pass before integration. Do not install over the user's app from this task.

The separate workflow uses no credentials, ROMs, firmware, plugins or saves.
It compiles iPhoneOS arm64 and runs real own-task sampling on native macOS ARM64,
verifying a known waiting thread, memory footprint and 24 captures in eight
rolling slots. macOS sampling cost does not establish iPhone overhead or GPU
behavior. New Leaf gameplay, JIT/non-JIT launch, Vulkan/plugin control cases,
normal save/reload, suspend/resume, repeated loads, and long sessions remain
physical integration checks. Preserve real saves and use copies for harnesses.

Baseline core SHA-256:
834eeec376d261f6f10ebe753bfafcb98bf3b67c2127330c95ae963f51c3801e
The baseline core is kept unchanged. Frame skipping OFF is still the physically
confirmed Vulkan/Vapecord setting. Existing R6 gate mechanics are revalidated
separately, but are not asserted to fix the currently reported random freeze.

After a diagnostic build is integrated by its owner, read only the new
Documents/ManicAzaharStabilityDiagnostics folder through the existing trusted
connection. Leave a freeze in place briefly so the rolling snapshots can cover
it. Run decode.py DIRECTORY --output NEW_PRIVATE_SUMMARY.json locally. The
decoder accounts for loaded/unloaded images, bounds its stack walk, and emits
native offsets and per-thread CPU deltas instead of stack memory. Keep the
capture and decoded summary private. iPhone sampling overhead still needs to
be measured from capture_duration_ms; host self-test timings are not a substitute.

Windows lacks Xcode/iPhoneOS SDK. Build access exists on KadeStanford/ManicEMU,
but that repository is public. The user authorized publication of this sanitized
diagnostic source branch and its build on October 4, 2026. This authorization
does not publish private inputs or phone evidence, or authorize an app install.
