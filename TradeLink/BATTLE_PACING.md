# Battle-only pacing in v0.7

v0.6 is the user-confirmed working baseline. The new speed path preserves its
trade, pause/recovery, save and room-exit behavior. Physical v0.7 speed/audio
and complete game behavior still require testing on two phones.

## Avoidable send delay

v0.6's main-thread 25 ms NSTimer polls the core's outgoing queue. A generated
serial packet can wait 0..25 ms before MCSession sends it, independently of
actual Wi-Fi latency. The engine exchanges a checksum and eight halfwords per
protocol frame; repeated polling delay can add to game-side turn barriers.

When **both games identify the 2211 active battle subconnection**, v0.7 schedules
a coalesced main-queue packet pump as soon as the core queues battle DATA or
pacing controls. The callback runs outside the core mutex and carries the
session epoch. The ordinary timer remains the fallback. Trade, room/discovery
and normal-play packets retain their existing polling path. Heartbeats remain
once per wall-clock second even with additional pump calls. Receive callbacks,
ACK semantics, retransmit intervals and real-loss recovery remain intact.

The UIKit scheduling test deliberately defers its regular timer by 200 ms and
records queue-to-send time into an MCSession test override. It establishes that
the battle wake bypasses polling; it is not a measurement of physical radio
latency or of the old timer's real-device average delay.

## Synchronized maximum 2x

No frontend/global fast-forward setting is changed. Both local and remote game
link-type commands must indicate 2211, hardware must be on at both ends, and the
session must be LINKED with no close intent. Colosseum room types 2233/2244 do
not enable acceleration. Each core sends an ordered SPEED offer for a fixed
rate of two frames per frontend call; the other offer **and acknowledgment of
its own offer** are required. Before agreement the core runs normal speed.

The engine then executes up to two **complete** GBA frames per frontend call:
all CPU cycles, timers, VBlanks, serial IRQs and checksums run normally, and input
is polled for each emulated frame. Ordered PACE controls report completed
emulated frames. A core can lead its peer by at most four frames; with no credit
it presents its existing image and waits. This is a bounded maximum, not a
guarantee of 2x wall-clock performance on every device/network.

The second frame rechecks agreement, credit and core lifecycle. HOLD,
SUSPENDED, hardware OFF, a close command or a trade/room link type cancels the
extra frame immediately. Hardware/type changes require fresh speed agreement.
Held or disconnected cores cannot advance; ordinary resume does not override
the existing bilateral recovery rules. Ordered older PACE controls arriving
after a local close are acknowledged without restarting acceleration.

Each frontend call presents one image. Stereo audio from both emulated frames
is downsampled 2:1 with a two-sample average and odd-sample carry, preventing a
growing audio queue. Battle audio plays faster/higher in pitch, as expected for
this conservative acceleration path; it is not pitch-preserving time stretch.
Normal 1x audio buffers remain unchanged. Physical audio quality is untested.

The original 115200-baud two-player schedule remains 5242 emulated cycles, and
the game still chooses moves, battle rules and parties. No serial synchronization
is skipped, no game-memory address is patched, and the plugin cannot eliminate
waiting for the other player's choice or the game's required turn/save barriers.
gpSP's underlying Gen3 serial model remains an approximation, not cycle-exact
general GBA multiplayer.

## Checks and limits

The pacing guard suite covers both offers/ACKs, room/trade/hardware/hold/loss/
close gates, four-frame credit, in-flight progress at close, fresh agreement,
reentrant wake callback safety and exact signed stereo/carry behavior.

The real-core clock/audio suite compares 120 frontend calls at normal speed
against 120 calls after battle negotiation. It counts actual gpSP VBlanks,
input polls, presented images and emitted audio samples; then checks an
unserviced peer, hold/loss/recovery, result-return closure, trade reentry,
current SRAM and fresh bootstrap interrupts. Its ARM-loop ROM does not implement
a game's serial IRQ handler. Natural hardware OFF/ON and handshake realign the
manual word fixture after clock measurements. Other suites verify all forwarded
turn/party halfwords, save failures, loss/replay/backpressure and the 75 five-title
activity traces. None executes Pokemon battle/game logic or supplies ROM data.

Both phones must use v0.7/MTR1 wire version 6. No settings or home controls were
added. Keep v0.6 available until two-phone speed, audio, result/save/exit, genuine
Wi-Fi interruption and battle -> trade behavior are confirmed on v0.7.
