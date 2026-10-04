# Nintendo DS local wireless candidate work

The v0.3/v0.4 revisions address the user-reported v0.2 HGSS phone slowdown and
communication failure. It replaces CPU-clock receive spinning with a 25ms
wall-clock deadline and bounded, packet-notified waits. The encrypted reliable
transport batches up to 16 already queued frames without collection delay,
coalesces cumulative ACKs, and avoids redundant retransmission on that channel.
Both phones must use the revised candidate (`ds131-mds4`, native marker 3).

Connection setup retains bounded early handshake data, waits for both Ready
fences before advancing the game, resolves crossed invitations, and clears
failed pending invitations. The peer label prefers Manic's existing configured
nickname. v0.4 first reads the already-open main-thread Realm through its
exported cache lookup, without a second database open or configuration change.
If no cache is available, it may read the existing file in read-only dynamic
mode, with format upgrades disabled. It falls back to the device name
available from iOS; no entitlement is added. The exact selectors exist in the
R7 RealmSwift binary. Actual nickname behavior still needs phone verification.
v0.4 also yields during native receive waits before a protocol has been paired,
so waiting for initial discovery cannot fall back to a tight polling loop.

`Documents/ManicDSDiagnostics/current.json` contains local frame/wait/queue
counts, not cartridge, firmware, save contents, usernames or credentials. It is
written off the core thread at most every five seconds for USB diagnosis.
Compilation and synthetic wait benchmarks do not establish a phone speed fix.

This is an experimental implementation for independent running DS consoles through
melonDS DS's real `SET_NETPACKET_INTERFACE`. Each phone runs its own cartridge,
input, audio, battery and save state. It is separate from Nintendo WFC and from
shared-screen/controller netplay. There is no main-home link button.

The source bridge detects local Nintendo wireless packets and advertises games
whose emulated radio is on. A passive scanner can become ready after finding a
compatible local host. Pairing requires a verified local battery/checkpoint
backup and user consent. Serialized state and save bytes never enter transport.

The transport bounds all queues, rejects foreign sessions and malformed raw
packets, acknowledges duplicates without executing them again, and carries
radio/pause controls in order with game traffic. Pausing chains the existing
frontend methods; a release must be acknowledged before the core advances.
The games choose their own trade/battle modes and enforce their own restrictions.

Generated firmware uses the same default MAC on independent cores. The bridge
assigns distinct addresses only on the local peer transport when those MACs
collide, restoring each receiver's destination before its native WiFi handles
the frame. It changes only the three management/data 802.11 header addresses.
It never changes firmware, WiFi registers, WFC identity or game/save payload.
Distinct native MACs pass through unchanged. Same-MAC Platinum discovery, trading,
bilateral native save checks and fresh-process cold reload passed with the exact
production C++ map on desktop. A separate fresh native session passed normal
Union Room pad exits on both consoles. The actual iPhone path remains unverified.

The authorized Diamond ADAE revision 5 / Pearl APAE revision 5 pair also passed
native same-MAC trade, bilateral save checks and battery-only cold reload. The
same running consoles transitioned into Colosseum Single Battle / No Restrictions,
exchanged a turn with matching damage, completed two normal forfeit battles and
left both rooms normally. This desktop TCP harness does not establish physical
iPhone discovery, frontend save-path integration or fenced Multipeer rejoin.

HeartGold IPKE / SoulSilver IPGE, both header revision 0, passed standard Union
Room trade, bilateral newer native save checks, fresh-process battery-only cold
reload and both normal Union exits with the final v0.2 protocol and unchanged
default MACs. The same cores transitioned to Colosseum Single Battle / No
Restrictions, exchanged matching damage, passed a faint/replacement flow and
completed two forfeit battles. Both final Colosseum exits passed, and both final
native saves retained the traded party with valid checksums. HGSS Spin Trade,
full-party knockout and fresh transport rejoin remain under test.

Radio shutdown parks a session temporarily. After five seconds with both radios
off and all game traffic acknowledged, CLOSE fences end the transport. The next
session uses new room nonces and discovery. Consent to the same peer runtime can
be reused; closing a game clears that consent. This bridge lifecycle passes
synthetic iOS simulator checks; physical games and Multipeer Connectivity still
require validation.

The existing engine's stop callback leaves old packets and its host ID queued.
`scripts/patch_source.py` clears those in the v1.3.1 source and adds radio/activity
events plus an exported reset-capability marker. The shim will not enable the
feature on a core without that marker. The exact-hash ARM64 instrumentation in
`scripts/patch_core.py` is a diagnostic prototype and must not be substituted
for the reset-capable engine in an IPA.

Interrupted transport stops wireless callbacks and allows the game's own error
and exit flow. No save state or battery is automatically rolled back. Radio-off
after an interruption abandons the failed transport without claiming a successful
trade. Current battery data is written atomically and verified at the frontend's
actual `.srm` path, with local pre-link and completed backup copies retained.
Actual desktop CPUE revision 1 / CPUE revision 1 trading and bilateral battery
save/cold reload persistence passed. The iOS frontend save-path and backup
semantics still require actual phone verification.

`scripts/build-ios.sh` uses the established GitHub Actions macOS/Xcode pipeline.
It builds a DS shim and a reset-capable v1.3.1 engine with Manic's optional iOS
JIT support, retaining the frontend's existing runtime JIT controls, using public
source dependencies only. The Windows test engine uses the interpreter. Builds
contain no user cartridges, saves, firmware or plugins. The combined IPA
packager must preserve all other R7 entries and label
the candidate's remaining validation gaps.

The core's original receive loop busy-polls for 25ms of CPU time. This transport
does not remove the documented DS LAN latency limitation. Successful synthetic
process tests do not establish successful Pokemon trading over phone Wi-Fi.
Actual cartridge infrared communication is absent from the audited upstream
engine; Gen 5 infrared trade/battle is not implemented by this wireless path.

See [compatibility and evidence](COMPATIBILITY.md). Do not describe all-game,
all-mode support as complete until the exact games and physical sessions pass.

The experimental combined IPA preserves every R7 archive entry except the DS
framework executable and the Bonjour service addition in the app Info.plist.
The app executable/assets, gpSP v0.7, Azahar R5 Vulkan/Vapecord and AirPlay R7
remain byte-identical. Packaging does not install the app or change user saves.
