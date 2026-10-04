# Nintendo DS local wireless candidate

The DS v0.7 candidate repairs identified iOS-path defects after the user's v0.6
phone tests failed: both Black/White and HeartGold/SoulSilver showed Union Room
messages without an interactable remote trainer. That physical failure takes
precedence over earlier desktop screenshots. A corrected phone pass is pending.

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

Native receive waits still use a 25ms wall deadline and notifications, with no
CPU-clock spin. The send queue now has interactive priority and honors flush
hints. Numeric diagnostics distinguish identity initialization, peer count,
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
R5-derived Azahar Vulkan/Vapecord. The concurrent AirPlay R8 correction replaces
only its injected component. Previous IPAs and real user saves remain untouched.
Candidates are unsigned; compilation and Simulator checks do not prove iPhone
local networking or native presentation success.
