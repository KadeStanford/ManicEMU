# Experimental in-game GBA nearby trades and battles

This implements the gpSP Gen3 serial protocol in Manic's existing libretro game
session. It targets FireRed, LeafGreen, Ruby, Sapphire and Emerald (game-code
prefixes BPR, BPG, AXV, AXP and BPE). Original Game Boy Red/Blue are a different
protocol; the earlier GB experiment is archived under `GBLink`.

The user confirmed a FireRed trade/save and quiet room exit in v0.5, plus a
battle when it was the first link after loading. Battle after trade did not
rediscover, and ordinary battle-result/save pauses showed recovery prompts.
v0.6 fixes completed-session bootstrap interrupts and adds cooperative frontend
HOLD/RELEASE controls. It also extends the shared cable-room lifecycle to all
five titles. See [the compatibility and evidence matrix](COMPATIBILITY.md).
**v0.6 still needs physical two-phone testing.** Synthetic traces exercise real
gpSP, not Pokemon game logic; they do not establish actual game compatibility.

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
   Keep both games open until the normal room exit finishes and current-save
   writes complete. Supported room exits use explicit bilateral game intent.

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
game's final bilateral idle close, the core thread stops the serial scheduler, records
current SRAM and a post-link state in a separate `completed-<UUID>` backup folder,
and atomically writes and verifies current SRAM at the frontend's **actual active
save path**, obtained from the pinned `savefile_ptr_get` export. It does not guess
a path from a display name. Pre-link backups remain untouched. A failed write
shows a save warning and retains current memory rather than rolling it back.
Neither the user-supplied IPA nor files on connected devices are edited by the
packaging/build scripts.

Disconnect/backgrounding suspends the cable and requires explicit recovery.
Manic's ordinary public pause/resume instead sends ordered HOLD/RELEASE, freezes
both cores while either frontend is held, and resumes without a recovery alert.
The local core waits for its RELEASE acknowledgment before advancing. Ordinary
resume cannot clear a genuine transport suspension. Reconnect resumes the
existing frontend through its public bridge. A 1.5-second receive timeout occurs
before gpSP's normal four-second peer timeout. Reconnect uses the same peer,
session identity and retained sequence queues. Duplicate retransmissions are
acknowledged without being executed twice. A lost/overflowed core packet requires
**Restore before link**, which restores that phone's checkpoint and battery on
the core thread. Both phones must choose recovery consistently after an
interrupted trade. The disk backups remain. There is no distributed atomic save
commit, and interrupted-trade recovery still needs the physical-device check. Restoration
is never automatic and is rejected after final session shutdown. Temporary
hardware shutdown retains both the current game and its pre-link checkpoint. Reconnect uses
ordered PAUSE/READY rounds and requires both players' readiness; stale rounds,
duplicates, or a late HELLO cannot restart an ended session.

Normal Gen3 `DisableSerial` writes `SIOCNT=0x2000`, retaining multiplayer mode
while clearing the IRQ bit. FireRed uses it for room -> party list, party list ->
trade animation, animation -> party list, and battle entry/return. These paths
also send `LINKCMD_READY_CLOSE_LINK` (`5FFF`), so neither an IRQ toggle nor that
command alone identifies a final exit. v0.3 incorrectly treated the first toggle
as final. The source-derived reproduction failed at `CLOSING` with one premature
save flush while its prior transport tests all passed.

v0.4 and later send ordered hardware OFF/ON notifications while preserving the session,
roles and automatic pre-link checkpoint. It stops fake serial IRQs while hardware
is disabled and resets the game-side handshake engine when it reopens. A final
exit requires both games' `5FFF` commands, both hardware OFF notifications, all
prior packet acknowledgments, 180 quiet core frames on **each** phone, and both
ordered QUIET readiness barriers. Reopening, new serial traffic or suspension
cancels readiness. A faster phone cannot end the slower game's transition.
Only then does the core send CLOSE fences, persist the current save and announce
completion. The quiet window is an explicitly bounded protocol heuristic, not
cycle-exact detection of game intent. A ROM hack that delays reopening beyond
both quiet deadlines remains outside the verified trace.

All five supported titles' terminal room exit is a separate path. In the cable-club
room (`1111`, `2233` or `2244`), both players send `CAFE/17`
(`LINK_KEY_CODE_EXIT_ROOM`), then the exit script calls CloseLink directly,
without sending `5FFF`. v0.4 missed this and stayed paired forever, blocking the
next discovery request. v0.6 applies the shared exit rule to all five titles and finishes once those commands and earlier DATA are
acknowledged, both hardware OFF controls are accepted, and the inbox is drained.
It uses ordered CLOSE fences and the same core-owned save persistence; there is
no quiet timer on this explicit path. Once acknowledged bilateral exit intent
and local hardware closure are known, a missing peer OFF/CLOSE control from a
transport disconnect can be treated as expected. Unacknowledged DATA still
requires recovery. Reopening hardware clears all room-exit intent. A single exit
key, EXIT_SEAT (`1D`) or a non-room link type cannot claim a successful ending.
The bounded quiet fallback remains for other endings. Known menu/animation/
battle-return link types (1122/1133/1144/2211) cannot trigger it even when they
remain hardware-off beyond that window. Final IDLE permits the game's initial
zero-word bootstrap IRQ again, so the next handshake can request fresh discovery.

Recovery UI has one alert per interruption. Repeated timeout, pause and
disconnect notifications reuse it; queued alerts are checked again before
presentation and discarded after terminal exit. Successful reconnect clears
that alert so a later interruption can recover. Fatal protocol errors still
escalate to checkpoint recovery. No configurable link settings or home buttons
were added.

A final close ACK lost to an expected peer
disconnect may be waived; unacknowledged serial DATA may not. Late duplicates are
ACKed against the ended session's tombstone, and queued frontend callbacks carry
a core epoch. Neither an expected disconnect nor normal close opens recovery UI.

Diagnostics keep only the last 128 metadata events (hardware states, link types,
close reason numbers, frame counters, phases and sequence counts). The plugin
atomically writes `Documents/ManicTradeDiagnostics/latest.txt` and rotates the
previous session to `previous.txt`; each file is bounded below 24KiB. These files
contain no party/block payload, ROM bytes, save bytes, player names or addresses.
They allow a physical failure to be compared with the tested register trace.

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
version 5 carries DATA, ACK, CLOSE, PAUSE, READY, SERIAL, QUIET, HOLD and RELEASE
in one sequence. Both phones must use v0.6; older wire versions cannot pair with it. ROM and
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
parent/child/simultaneous bilateral idle exits, missing final close ACK versus DATA,
SRAM persistence across new processes, a 140-frame reconnect burst with engine
backpressure, failed save handling, and interrupted
battle checkpoint recovery. The FireRed transition trace additionally exercises
room -> party list, three complete synthetic 200-byte party blocks, selection ->
animation, save standby, return to menu/room, Single/Double battle handoffs, mode
resets without close intent, reopen at the quiet deadline, unequal frame rates,
same-session epochs and absence of intermediate save flushing. The room-exit
suite covers simultaneous/asymmetric/delayed exits, missing DATA ACKs versus
final controls, negative intent checks, save/restart, and trade exit -> fresh
Single/Double Colosseum handshake -> pairing -> battle turns/return -> exit.
Fresh discovery uses the game's real B9A0 token, with no fabricated alternate
battle token. Disabled IRQs and non-handshake writes cannot start discovery.
The UIKit test checks one recovery presentation for repeated interruption
callbacks, cancellation of queued stale alerts, fresh Colosseum discovery,
fatal-error escalation, and normal ending without a
reconnect/restore dialog, the active frontend save path, and separate pre/post
backups. The simulator uses a small test frontend;
it does not launch the full original Manic app or run Pokemon game logic.
See [the trace provenance and limits](Tests/TRANSITION_TRACE.md).

v0.6 adds same-core sequential trade/battle/result/save/room/reentry checks,
release-ACK and real-drop-during-hold recovery checks, and a 25 ordered English
header-pair matrix through Trade/Single/Double (75 activity traces). The UIKit
stub verifies all five titles in discovery and normal result pauses without
recovery UI. Neither the simulator stub nor protocol fixtures run the full
original Manic app or establish real two-device game combinations.

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
