# Nintendo DS local wireless candidate

v0.5 introduced automatic shared DS discovery for all nine detected titles:
Diamond, Pearl, Platinum, HeartGold, SoulSilver, Black, White, Black 2 and
White 2. There is no emulator player picker, Accept prompt or main-home link
button. Enter the game's legitimate local room on each independent console.
The native game selects activities, opponents and player limits. Supported
transport admission is not proof of playable compatibility for every pairing.
GBA's existing connection behavior is unchanged.

v0.6 addresses the physically reported Black/White v0.5 missing avatar. Gen 5
uses console addresses inside Nintendo application messages as well as wireless
headers. Header translation alone produced welcome messages but no avatar;
partial advertisement translation produced avatars but failed association.
Gen 5 now receives a stable, randomly generated local console MAC at boot only
when using generated firmware without an explicit configured MAC. No device
hardware identifier is read. Native firmware files and explicit MAC settings
are preserved. Gen 5 wireless frames then pass byte-for-byte in both directions.
Gen 4 retains its existing header identity handling and the SAME automatic
shared discovery flow. The per-install generated Gen 5 identity is stored in
local app preferences. No game, state or save payload is rewritten to fake it.

A legacy Gen 5 state can contain older wireless registers and cached game
identities. It remains usable for ordinary emulation; if registers disagree
with the boot firmware identity, nearby play stops once with instructions to
save in-game and restart from the normal game save. Files are retained. The
bridge does not silently replace the state or discard unsaved progress.
Two externally configured consoles with the same native Gen 5 MAC cannot form
an independent native wireless session; a distinct valid identity is required.

The shared carrier supports up to eight independent consoles and separates
reliable per-peer sequencing and Ready fences. This does not increase a game's
native room, battle or trade limits. Nintendo WFC, cartridge infrared and
Download Play transfer are not claimed. Each instance keeps its own cartridge,
inputs, battery and state. No serialized state or save enters the transport.

The receive loop uses a 25ms wall-clock deadline and packet-notified waits.
Already queued frames batch without a collection delay; cumulative ACKs are
coalesced. Core callbacks run only on the emulator thread. Before advertising,
the bridge verifies a local battery/state checkpoint and current save path.
Changed battery data is persisted independently. Radio shutdown resets native
packet queues; reentry retains the carrier without a new app pairing prompt.
Manic's existing nickname is preferred, with the iOS device name as fallback.

Desktop gameplay, synthetic protocol tests and simulator tests are recorded
separately from phone verification in COMPATIBILITY.md and local evidence.
The two-instance distinct-identity Black/White experiment reached visible
trainers, the activity menu and a completed native trade. Final source-built
engine regression, bilateral cold reload, battles and physical iPhone testing
remain required; compilation alone is not an all-game fix.

Packaging preserves R7 app identity, executable, assets, gpSP v0.7 GBA link,
Azahar R5 Vulkan/Vapecord, MoltenVK and existing AirPlay bytes. Candidates are
unsigned and separately named; original IPAs and real user saves are retained.
