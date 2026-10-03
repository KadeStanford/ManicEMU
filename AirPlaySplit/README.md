# Live DS / Azahar AirPlay split

This optional injected framework uses the original Manic `LibretroCore` and Metal
`Context` renderer. It does not replace the app or any existing emulator framework.
When Manic moves its game view to an external screen, the core renders both DS or
3DS screens into one canonical frame. Two crop passes on that same command buffer
present the top screen on TV and the touchscreen on the phone. The phone's **Swap
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
