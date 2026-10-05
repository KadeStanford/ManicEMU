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

Both v0.10 R1 and R2 retained severe physical interaction slowdown with direct
DTLS active. R2 requests responsive-data service on outgoing connections and
listeners. That request did not resolve the observed phone failure. A separate
125ms reply-recovery experiment accepted late replies but ran slower in a
controlled native comparison; it is excluded from the production branch.

R3 adds bounded receive/send timing without changing packets, transport policy,
native reply validation or the original 25ms deadline. A fixed 512-record ring
retains SHA256 fingerprints and CLOCK_MONOTONIC_RAW times for RF send entry,
receive callback entry and send completion. It stores no additional payloads,
addresses or keys. Exact fingerprints allow retained bilateral exchanges to be
matched when the smaller native payload ring did not retain both endpoints.
Snapshot clock anchors bracket the mapping to native recorder wall times.
Send completion measures content processing/callback latency, not remote receipt.

An independent dispatch timer samples RF callback queue latency every 50ms,
with at most one probe queued and no network messages. A delayed probe identifies
queue/dispatch contention at that sample. Responsive probes cannot exclude a
short unsampled stall or distinguish physical radio delay from processing
inside Network.framework before a callback is dispatched. Eight-bin histograms use
microsecond boundaries 1000, 5000, 10000, 25000, 50000, 100000 and 250000; the
last bin includes all larger values. Outstanding sends remain capped at 32.

Public IP receive-time options are requested when available. A bounded public
API reproduction verified IP options were present, selected IPv4 and enabled
receive time, yet ordinary UDP and DTLS loopback omitted IP metadata on both
macOS and iOS simulator. IP timestamps are therefore opportunistic diagnostics;
missing/invalid clocks are explicit and never treated as zero delay or proof
of phone support. The useful queue/completion/fingerprint route is independent
of IP metadata. No custom-IP entitlement or private API is used.

Recorder format 6 uses existing SDK direct-receive event 100 fields: timestamp
is IP receive time, reference_timestamp is callback entry time, aidmask is 1
only for a valid ordered IP/callback clock pair, payloadmask is room-lock wait
in microseconds and answeredmask is callback-to-room-lock acquisition time in
microseconds. The latter two saturate at 65535; aggregate maxima are also
retained without that saturation. This interpretation applies only to direct
SDK receive events (reason 2 for admitted RF, reason 0 if rejected); native
events 1-8 and MCSession fallback events retain their previous meaning. No
additional payload records reduce the existing retention window.

Simulator tests exercise real bilateral DTLS, valid callback/completion clocks,
explicit IP availability, a controlled 75ms callback-queue blockage and ring
wrapping under encrypted bursts. They cannot establish iPhone Wi-Fi performance
or completed physical trades. R3 is a diagnostic candidate, not a proven fix.

R4 keeps a bounded, LAN-only `_manic-ds-lan._tcp` presence announcement while
native wireless is enabled. It contains the existing public console metadata;
no game bytes, save, transport key, address or credential is advertised. The
record is discovery-only and opens no new socket. Both publication and browsing
explicitly exclude peer-to-peer Wi-Fi. Add this type to the app's existing
Bonjour service declarations; the bundle identity and local-network permission
remain the same.

Once every admitted console has matching LAN presence and a ready direct DTLS
path, continuous MC nearby advertising/browsing stops. A new compatible LAN
participant automatically reopens it for the existing encrypted admission
process. There is no pairing chooser, one-peer limit or game invitation change.
Missing/failed LAN discovery, older connected peers, incomplete direct paths
and pending admission retain the existing discovery behavior. Connected
encrypted MC sessions and ordered room controls remain untouched. Native radio
exit stops LAN presence and reentry republishes it. The recorder additionally
retains bounded quiet/wake transition counters.

This targets redundant nearby discovery during latency-sensitive LAN exchanges.
It does not disable the system's peer-to-peer interface or other nearby services;
an idle connected MC session may still participate in peer-to-peer networking.
Phone latency benefit and completed physical trades require verification. All
participants should use R4 for automatic arrival into an already quiet room.
Simulator coverage includes real bilateral Bonjour discovery, exclusion of
peer-to-peer participation, bounded/invalid metadata and automatic third-peer
wake/fallback/exit. Native packet bytes, 25ms deadlines and stale/AID checks are
unchanged.

R6 lets the guest CPU and audio continue while a genuine local radio transaction
is pending. The existing WiFi transaction cursor pauses instead of blocking the
entire console. Reply polling never waits; a500us gate limits empty polls and a
125ms wall deadline bounds recovery. Source, native AID, timestamp, payload and
empty-reply validation remain in the same ReplyCollector. Reaching the256-packet
drain limit leaves subsequent packets queued. Cancellation covers native stop,
reset, unload and restore; ordinary titles keep the legacy receiver.

The shim explicitly enables this capability after loading one of the nine
supported Pokemon titles, disables it for unloading and subsystem loads, and
checks the engine capability before enabling local multiplayer. The recorder
keeps genuine request/result timing; pending-transaction duration must not be
interpreted as CPU-blocking wait time. Its frontend wait counters still measure
actual blocked waits.

An isolated Black/White native run with modeled3.35ms per carrier leg completed
a trade near60FPS, verified swapped party identities and checksums, and cold
loaded both copied saves. A25ms async prototype failed that same interaction
and was rejected. These local tests do not model physical iPhone networking;
the corrected physical trade and sustained phone performance remain to verify.
