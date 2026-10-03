# Experimental in-game GBA nearby trading

This implements the gpSP Gen3 serial protocol in Manic's existing libretro game
session. It targets FireRed, LeafGreen, Ruby, Sapphire and Emerald (game-code
prefixes BPR, BPG, AXV, AXP and BPE). Original Game Boy Red/Blue are a different
protocol; the earlier GB experiment is archived under `GBLink`.

The implementation and automated checks are working. A complete Pokemon trade
on two physical iPhones and the repackaged app's device launch are **not yet
verified**. Treat this IPA as an experimental test build.

## Use with existing progress

1. Before changing cores, save using Pokemon's own in-game Save command, close
   the game normally, and keep an export of the existing battery `.sav`.
   Progress held only in an mGBA save state must first be loaded and saved in-game
   with mGBA. A save state is not a battery save.
2. Select **gpSP** once through Manic's existing per-game core option, then start
   the game normally. This preserves Manic's selected-core save-state metadata.
   The implementation does not swap a running mGBA session or silently change a
   stored core preference. No additional configurable link settings are added.
3. Both players use this build, allow Local Network access, and enter the game's
   cable club/trade flow. Use the cable option rather than the wireless adapter.
   The first Gen3 serial handshake automatically opens **Nearby players**.
4. Tap the friend; the other phone accepts. Both keep their own running game,
   normal Manic screen, controls and audio. There are no Host/Join roles, ROM/save
   selectors, six-digit codes, home overlay, or standalone emulator screen.
5. Complete the game's trade and in-game save on both phones; leave the cable
   club normally. Keep both apps alive during trading. Use normal speed; avoid
   slow motion. The core inhibits fast-forward when the frontend supports the
   libretro override and rejects one-sided rewind/state loading during a link.

All GBA cores in upstream Manic use the same `sdmc/saves/gba/<game-name>.sav`
location and `.sav` extension. Pokemon's 128KiB raw Flash battery data needs no
format conversion between mGBA and gpSP. An automated check exports a synthetic
128KiB battery from actual official mGBA, imports it into the actual gpSP core,
runs 120 frames, and verifies every byte and the unchanged input file. It also
checks that an mGBA state is rejected without changing battery memory. This
does not establish correctness of any particular user's existing game save.

Before discovery or serial data exchange, the plugin atomically writes the
current game's battery and full gpSP checkpoint to a unique
`Documents/ManicTradeBackups/<UUID>/` folder. If either write fails, pairing stops.
The plugin does not import, transfer or overwrite another game's save. Normal
Manic battery saving still updates the current game's save through its existing
frontend. Neither the user-supplied IPA nor files on connected devices are edited
by the packaging/build scripts.

Disconnect/backgrounding suspends the cable; a 1.5-second receive timeout occurs
before gpSP's normal four-second peer timeout. Reconnect uses the same peer,
session identity and retained sequence queues. Duplicate retransmissions are
acknowledged without being executed twice. A lost/overflowed core packet requires
**Restore before trade**, which restores that phone's checkpoint and battery on
the core thread. Both phones must choose recovery consistently after an
interrupted trade. The disk backups remain. There is no distributed atomic save
commit, and a completed trade still needs the physical-device check.

## Source and timing

Manic lineage: official [Manic-EMU/ManicEMU](https://github.com/Manic-EMU/ManicEMU),
base `fbaeab79c214d5920bb51afa6f2d786fb2b12a58`. The original IPA identifies its
gpSP core as `v1.1.0-fc4afeb`. This fork vendors the corresponding official
[libretro/gpSP source](https://github.com/libretro/gpsp/tree/fc4afebb09d1b2d0fa66f5bf4d54783043d5dfe8)
with notices and the GPL replacement BIOS and its source. This is an interpreter
build and does not require JIT for its added GBA core. Other original IPA resources
remain intact.

gpSP's original Gen3 implementation is a protocol approximation: it exchanges
checksum plus eight halfwords and simulates some idle/interrupt events. It is not
cycle-exact general GBA multiplayer. Tests verify the 115200-baud two-player
master schedule (5242 emulated cycles), busy-bit/IRQ behavior and both directions
of actual serial words across isolated engines. Network packets carry those
24-byte serial frames inside a sequenced 56-byte envelope. Encrypted
MultipeerConnectivity handles discovery and reliable local transport. ROM and
battery bytes are never sent to the other player. Protocol version, peer/session
identity, game-code family and language code must match the compatibility checks.
The game itself still determines inter-title trade eligibility.

mGBA has native GB and GBA serial infrastructure, but its libretro wrapper does
not expose a usable two-phone GB cable interface. GBA multiplayer does not solve
original GB Pokemon Red. The current GBA implementation uses gpSP's actual Gen3
netpacket/serial interface; it does not pretend an unsupported mGBA connection
exists. See the vendored patch and `UPSTREAM` for exact provenance.

## Builds and checks

The **In-game GBA Trade** workflow runs ASan/UBSan core/transport tests, isolated
two-core Gen3 exchange over delayed and fragmented loopback TCP, partial-drop and
reconnect/replay tests, checkpoint rollback and buffer-loss guards, cross-core
battery migration, IPA preservation tests, physical-arm64 iOS compilation, and a
native UIKit simulator smoke test. The simulator uses a small test frontend;
it does not launch the full original Manic app or run Pokemon game logic.

Download `ManicGBA-Trade-unsigned` from a successful workflow run. Keep both
framework directory names and contents. On Windows/macOS/Linux with Python 3:

```text
python GBLink/scripts/ipa_link.py original.ipa --inspect
python GBLink/scripts/ipa_link.py original.ipa --framework ManicGBLink.framework --gpsp-framework gpsp.libretro.framework --output Manic-GBA-Trade-Unsigned.ipa
```

The packager embeds the plugin, replaces only the original gpSP framework, opts
in with `MGLInjectTrade`, and adds `_manic-trade._tcp`. It preserves other resources
byte-for-byte, including `System.core`; removes invalid signature resources; and
refuses encryption, unsafe ZIP paths, incompatible architectures/platforms,
insufficient header padding and existing output paths. No source/repacked IPA is
uploaded to the fork. The old `ManicGBLink` framework name is retained only as a
packaging identifier; this build contains the in-game GBA plugin.

The output is unsigned. Re-sign the app and every embedded framework using the
existing sideload tool/account. No signing credentials are accessed or changed,
and no device installation is performed by this workflow. Windows cannot perform
a local Xcode build; GitHub's macOS runner compiles the added frameworks. A full
Manic source build and physical two-iPhone trading remain separate checks.

For a source app build, embed/sign `ManicGBLink.framework`, replace/embed/sign
`gpsp.libretro.framework`, and set the app's Info.plist `MGLInjectTrade` to true.
The framework uses the public Objective-C `LibretroCore` ABI. Use this fork's
Bonjour declaration. Existing Manic settings and core-selection controls remain
in their original locations; no configurable home-screen link controls are added.
