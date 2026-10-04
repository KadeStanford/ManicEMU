# Nintendo DS local wireless candidate

DS v0.8 addresses the latest v0.7 phone findings: Black/White and
HeartGold/SoulSilver can display remote trainers, but entry order affects
discovery and native interaction causes severe slowdown/instability. No
completed physical trade, battle or save/reload is established on v0.7/v0.8.
On one trusted USB phone, native receive waits consumed 50.7% of the measured
interaction-to-exit interval; that measurement does not establish every cause.

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
R5-derived Azahar Vulkan/Vapecord. The concurrent AirPlay R9 correction replaces
only its injected component. Previous IPAs and real user saves remain untouched.
Candidates are unsigned; compilation and Simulator checks do not prove iPhone
local networking or native presentation success.
