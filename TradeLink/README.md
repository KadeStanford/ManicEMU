# Experimental in-game GBA nearby trades and battles

This implements the gpSP Gen3 serial protocol in Manic's existing libretro game
session. It targets FireRed, LeafGreen, Ruby, Sapphire and Emerald (game-code
prefixes BPR, BPG, AXV, AXP and BPE). Original Game Boy Red/Blue are a different
protocol; the earlier GB experiment is archived under `GBLink`.

The user reported that the previous build paired two physical phones and reached
the end of a trade, then displayed recovery prompts and failed to keep the result.
This revision fixes the ending path. Automated checks use legal synthetic
programs and protocol fixtures. **The revised IPA still needs a physical two-phone
trade, battle, and app-restart save check.** Treat it as an experimental test build.

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
   cable club trade, Single Battle or Double Battle flow. Use the cable option
   rather than the wireless adapter. Four-player Multi Battle is unsupported.
   The first Gen3 serial handshake automatically opens **Nearby players**.
4. Tap the friend; the other phone accepts. Both keep their own running game,
   normal Manic screen, controls and audio. There are no Host/Join roles, ROM/save
   selectors, six-digit codes, home overlay, or standalone emulator screen.
5. Complete the game's trade or battle and in-game save on both phones; leave the
   cable club normally. This ends quietly and returns to ordinary play, keeping
   the current result. Keep both apps alive during the link. Use normal speed; avoid
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
The plugin does not import, transfer or overwrite another game's save. On the
game's local hardware close, the core thread stops the serial scheduler, records
current SRAM and a post-link state in a separate `completed-<UUID>` backup folder,
and atomically writes and verifies current SRAM at the frontend's **actual active
save path**, obtained from the pinned `savefile_ptr_get` export. It does not guess
a path from a display name. Pre-link backups remain untouched. A failed write
shows a save warning and retains current memory rather than rolling it back.
Neither the user-supplied IPA nor files on connected devices are edited by the
packaging/build scripts.

Disconnect/backgrounding or Manic's public pause action suspends the cable;
reconnect resumes the existing frontend through its public bridge. A 1.5-second receive timeout occurs
before gpSP's normal four-second peer timeout. Reconnect uses the same peer,
session identity and retained sequence queues. Duplicate retransmissions are
acknowledged without being executed twice. A lost/overflowed core packet requires
**Restore before link**, which restores that phone's checkpoint and battery on
the core thread. Both phones must choose recovery consistently after an
interrupted trade. The disk backups remain. There is no distributed atomic save
commit, and a completed trade still needs the physical-device check. Restoration
is never automatic and is rejected after local hardware shutdown. Reconnect uses
ordered PAUSE/READY rounds and requires both players' readiness; stale rounds,
duplicates, or a late HELLO cannot restart an ended session.

Normal Gen3 `DisableSerial` writes `SIOCNT=0x2000`, retaining multiplayer mode
while clearing the IRQ bit. The old detector checked only the mode change and
missed this. The old UI also disconnected before the next core frame applied
cleanup. This revision detects IRQ shutdown, sends ordered CLOSE fences after
all queued serial packets, drains/acknowledges both fences, and announces
completion only on the core thread. A final close ACK lost to an expected peer
disconnect may be waived; unacknowledged serial DATA may not. Late duplicates are
ACKed against the ended session's tombstone, and queued frontend callbacks carry
a core epoch. Neither an expected disconnect nor normal close opens recovery UI.

Single and Double Battles use the same Gen3 frame/block transport and closing
lifecycle as trades. The game's `LINKCMD_SEND_LINK_TYPE` identifies the activity;
the game chooses battle rules, parties and moves. The plugin forwards blocks
unchanged and does not implement Pokemon game logic or force a trade mode. Battle
finish and forfeit ultimately use the same cable close path. Their actual in-game
flows remain physical-device checks, not claims made by the protocol fixtures.

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
MultipeerConnectivity handles discovery and reliable local transport. MTR1 wire
version 2 carries DATA, ACK, CLOSE, PAUSE and READY in one serial sequence. Both
phones must use this revision; the old MTR1 version 1 build cannot pair with it. ROM and
battery bytes are never sent to the other player. Protocol version, peer/session
identity, game-code family and language code must match the compatibility checks.
The game itself still determines inter-title trade eligibility.

mGBA has native GB and GBA serial infrastructure, but its libretro wrapper does
not expose a usable two-phone GB cable interface. GBA multiplayer does not solve
original GB Pokemon Red. The current GBA implementation uses gpSP's actual Gen3
netpacket/serial interface; it does not pretend an unsupported mGBA connection
exists. See the vendored patch and `UPSTREAM` for exact provenance.

## Builds and checks

The **In-game GBA Link** workflow runs ASan/UBSan core/transport tests, isolated
two-core Gen3 exchange over delayed and fragmented loopback TCP, partial-drop and
reconnect/replay tests, checkpoint rollback and buffer-loss guards, cross-core
battery migration, IPA preservation tests, physical-arm64 iOS compilation, and a
native UIKit simulator smoke test. The expanded fixtures test Trade/Single/Double
commands, 24 bidirectional block/turn frames, three bilateral reconnect rounds,
parent/child/simultaneous IRQ-disable exits, missing final close ACK versus DATA,
SRAM persistence across new processes, failed save handling, and interrupted
battle checkpoint recovery. The UIKit test checks normal ending without a
reconnect/restore dialog, the active frontend save path, and separate pre/post
backups. The simulator uses a small test frontend;
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
Manic source build and revised physical two-iPhone trading/battling remain
separate checks. Closing the game normally and reopening from an in-game battery
save must be checked independently of loading an older Manic save state.

For a source app build, embed/sign `ManicGBLink.framework`, replace/embed/sign
`gpsp.libretro.framework`, and set the app's Info.plist `MGLInjectTrade` to true.
The framework uses the public Objective-C `LibretroCore` ABI. Use this fork's
Bonjour declaration. Existing Manic settings and core-selection controls remain
in their original locations; no configurable home-screen link controls are added.
