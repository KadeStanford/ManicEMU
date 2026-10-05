# Nintendo DS local wireless candidate

DS v0.10 adds an encrypted local RF path to the v0.9 diagnostic baseline.
Admitted peers exchange fresh, per-peer DTLS keys and local IPv4 listener
addresses only over the existing encrypted MCSession. Direct RF is restricted
to connected local subnets, keeps the same native fragments and epoch gates,
and has at most 32 outstanding sends per peer. Unavailable LAN routes fall back
to the existing encrypted MCSession; datagrams admitted to DTLS are never sent
again over MPC on completion failure. Discovery, names, compatibility boundaries,
room controls and native 25ms reply validation are preserved. No credentials,
keys or addresses are stored in diagnostics. The native core is unchanged.
Simulator DTLS tests are loopback-only; they cannot prove physical Wi-Fi latency.

The earlier phone feedback reports HeartGold/SoulSilver trading and
battling are reported working with slowdown; Black/White show trainers but
interaction/trade fail with communication errors. Native receive waits consumed
68% of measured active Black/White stalls on one trusted USB phone. Two proven
receive-boundary defects are corrected; physical performance/completion remains
pending. Compilation and historical desktop success do not prove a final fix.

All nine supported title identifiers use automatic nearby discovery inside the
native local room. No emulator player picker, Accept popup or home button is
added. Native games select opponents, activities and player limits. Manic's
nickname is preferred, with the device name available from iOS as fallback.

Every recognized Pokemon title receives the same stable per-install virtual DS
identity before boot, including generated/imported firmware and configured MAC
paths. This intentionally owns the emulated console's in-memory identity for
these titles; firmware files and saves are not rewritten by this initialization.
Gen 4 and Gen 5 radio/application frames pass unchanged. v0.6's generated-only
Gen 5 initialization and Gen 4 header-only translation were insufficient paths.
No physical hardware identifier is read or transmitted. The existing v0.6 local
identity preference is retained, so updating does not rotate that identity.

Legacy states can retain an older console identity in registers and game caches.
They remain retained and usable for ordinary play. Nearby play checks both boot
firmware and local identity; a mismatch produces one instruction to save in-game
and restart through normal Continue. The bridge does not patch arbitrary RAM,
replace states or discard unsaved progress. Native battery files remain separate.

melonDS emits a zero-payload reply when a client has no payload ready. The former
bridge rejected it and the libretro receive loop lacked safe arrival handling.
The new collector counts a blank only for a source with a previously learned,
address-filtered native AID in the current association. Actual payload bits and
arrival bits are separate. Unknown/stale/duplicate/bystander blanks cannot fake
an answer. Reassociation and radio stop erase source learning. The receive loop
also bounds unrelated traffic and avoids unsigned timestamp underflow. Native
AIDs and game payloads are never fabricated or rewritten.

Discovery first advertises a ready native console identity after the local
checkpoint. An early ready remote candidate is retained during preparation;
one deterministic side invites automatically. This avoids caching an initial
unready Bonjour record or dropping a peer solely because local preparation is
incomplete. Reentry retains the same console identity.

Native RF now honors the core's unsequenced/unreliable send request. Reliable
Ready/radio/hold controls stay separate; native RF has no extra app ACK stream.
Datagrams carry pair and bilateral radio-epoch fences and bounded <=1000-byte
fragments. Reassembly is bounded and expires incomplete packets; a lost packet
cannot block later packets. Nintendo's own retries remain authoritative, and
RF payload bytes are unchanged. The datagram ceiling is a conservative chosen
bound, not a physically validated MultipeerConnectivity capacity guarantee.

Native reply collection propagates its remaining 25ms wall budget through
every nested packet wait instead of opening another full timeout. Notification
waits avoid CPU-clock spinning; OS scheduling can still overshoot. The send
path now polls available frontend data once after the last wait, before a
timeout. Reply collection additionally drains at most 256 already-available
packets without opening another wait. Timestamps, payload masks and reply
acceptance rules stay native.
The send
queue retains interactive priority and flush handling. Numeric diagnostics
distinguish native RF/control counts, reassembly drops, SDK send failures,
identity initialization, peer count,
CMD/reply/other input, address-filter drops, native timeouts and send-queue delay.
Core callbacks stay on the emulator thread; SDK delegates enqueue only. Local
pre-link checkpoints, independent periodic battery writes and graceful radio
exit behavior are retained. Save/state data never enters the transport.

The reliable neighborhood can contain eight independent consoles; this does
not increase native battle/trade limits. Gen4-to-Gen5 direct trade/battle is not
admitted. Nintendo WFC is separate. Cartridge infrared, Download Play/Poke
Transfer and four-player game completion are not implemented or established.
See COMPATIBILITY.md for title/version, historical evidence and explicit gaps.

Combined packaging preserves app identity/assets, gpSP v0.7 GBA behavior and
R5-derived Azahar Vulkan/Vapecord. The concurrent AirPlay R10 correction replaces
only its injected component. Previous IPAs and real user saves remain untouched.
Candidates are unsigned; compilation and Simulator checks do not prove iPhone
local networking or native presentation success.

The consolidated diagnostic recorder retains scoped host/reply wait times and
timeouts, accepted/empty/stale/unknown/unexpected/duplicate/malformed replies,
native request/arrival/payload masks, timestamps, source slots, actual sender
AID register, queue depth and byte-exact bounded wireless packet contents.
The frontend also records SDK RF envelopes/send outcomes, delayed wake-ups,
frame time, AV callback counts, selected JIT/render options, CPU time, thermal
and low-power state, and recorder overhead. It adds no network messages.
Packet callbacks copy at most 2048 bytes into a fixed 128-record ring; disk and
JSON work run on a serial utility queue with at most two pending jobs. Snapshots
are limited to 512KiB each. Sixteen rotating game sessions each retain eight
periodic snapshots plus the last incomplete exchange and slow frame; normal
game unload requests a final snapshot. Private captures stay local, separate
from generic code and synthetic CI evidence. The optional Azahar recorder is
a separate packaging variant; its trace does not establish DS protocol behavior.
