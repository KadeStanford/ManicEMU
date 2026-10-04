# Live DS / Azahar AirPlay split

This optional injected framework uses the original Manic `LibretroCore` and Metal
`Context` renderer. It does not replace the app or any existing emulator framework.
When Manic moves its game view to an external screen, the core renders both DS or
3DS screens into one canonical frame. A shared GPU snapshot feeds independent
phone and TV crop queues. Each queue keeps only the newest completed frame, so a
waiting TV drawable cannot stall the phone crop. The phone's **Swap
screens** button reverses the outputs; when the bottom screen is on TV, the phone
surface acts as its touchpad.

The phone crop occupies the original skin's touchscreen area. Disconnecting the
display removes both overlays and restores the phone layout. Swapping and display
changes do not load a ROM, recreate an emulator, or access save files. Single-screen
systems, including GBA, use the existing rendering path. The component requires
the original libretro Metal renderer ABI and declines installation if it is absent.
The separate Citra/MTKView 3DS backend is not handled by this component; choose
Azahar for the replacement 3GX core and split display support.

`scripts/build-ios.sh` creates an unsigned arm64 iOS framework.
`scripts/simulator-smoke.sh` checks UIKit lifecycle and touch mapping in a synthetic
frontend and checks real Metal crop output pixels. These tests do not establish
physical AirPlay behavior, a game's touchscreen behavior, or Vapecord execution.
Physical device testing is required before calling the resulting IPA verified.

Run `37157254569` passed 54 simulator checks, including 120 matched producer
frames with casting disabled versus a blocked display queue, for DS and 3DS at
1x, 2x and 4x. Each blocked case held three snapshots and dropped the following
117 captures while producer command buffers completed. `performance.json`
records measured timings; these synthetic comparisons do not measure physical
AirPlay source-drawable pacing.

The optional `MASAirPlayDiagnostics` app plist flag emits public numeric counters
once per second: source drawable wait, copy encoding/completion time, sink
drawable wait, captures/drops, allocations, in-flight snapshots and presentations.
It contains no game paths, save contents or plugin payloads. The R3 pacing repair
keeps the original producer view on the phone screen while the independent crop
sink remains external. The source is clipped without changing its bounds;
disconnect/reset restore ownership only if the source is still in our host.
The shipped source passed 58 checks, including producer screen assignment,
render-dimension preservation and disconnect/reconnect ownership. Physical
AirPlay speed and quality still require testing. The private R3 IPA also retains
all working GBA v0.7 framework entries and app hooks, verified against the
baseline; the existing GBA regression workflow passed both jobs.

The sender investigation verified the shipped Vulkan viewport code against the
pinned RetroArch source: its output size comes from the producer view bounds
multiplied by the cached native screen scale. Increasing the core's internal
resolution alone does not guarantee that its final drawable retains those pixels.
The new producer geometry follows the canonical composite pixel dimensions
before rendering; disconnect restores the original view dimensions. DeSmuME's
running resolution option also updates the composite factor.
Startup configuration dictionaries are observed after the original app handles
them, so a previously selected resolution reaches the producer immediately.
The observer does not query the environment callback (which clears the original
core's option-update flag) or flush configuration files.
Crop filtering remains nearest, and this does not create additional detail in native-resolution
sprites, text, or CPU-drawn plugin graphics.

When `MASAirPlayDiagnostics` is enabled, bounded numeric evidence is written once
per second to `Documents/ManicAirPlayDiagnostics/metrics.json`. It reports actual
source and viewport pixels, requested composite pixels, each crop's pixels,
phone/TV drawable pixels, the external screen mode, superseded frames, separate
drawable waits and capture-to-sink-submit frame ages. These ages measure the
sender pipeline, not AirPlay encoding, network or receiver latency. No screenshots,
game paths, input history, keys or save contents are recorded. Physical source
dimensions, quality and latency still require a coordinated device test.
