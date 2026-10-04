# Compatibility and evidence

An actual Platinum CPUE revision 1 / CPUE revision 1 Union Room trade passed on
two independent desktop core processes. Infernape "Mario" (PID 2413151600) and
Staraptor "Limit Bird" (PID 3963018234) exchanged selected party slots. Both games
returned to party selection and wrote newer, valid battery-save blocks; both
exchanged Pokemon checksums passed. Fresh emulator processes loaded each battery
save without a state file and retained the exchanged identities. Both games also
returned to the Union Room contact flow and left the room with radio shutdown.

A No Restrictions single battle also ran through the Colosseum after the trade.
Both sides exchanged Aerial Ace / Flamethrower actions and reflected the matching
damage: Staraptor went from 217 to 60 HP and Infernape from 210 to 82 HP. One
player then selected Run (forfeit); both games ended the battle and returned to
the arena. This establishes a completed forfeit exit, not all-party knockout
completion. A second battle in the same Colosseum group passed, including a
fainted Infernape, replacement with Cacturne, and another completed forfeit exit
on both consoles. Fresh transport reconnect and physical phone results remain
unverified.
This desktop game result does not establish iPhone discovery, the
iOS frontend's actual save-path integration, or all-title support. Region/revision
and game-specific rules must be recorded with each real test.

| Title | Exact authorized cartridge | Local trade/battle route | Current desktop game evidence |
|---|---|---|---|
| Diamond | ADAE revision 5 | Union Room; Colosseum battles | Boots public save: 8 badges; state roundtrip passes |
| Pearl | APAE revision 5 | Union Room; Colosseum battles | Boots public save: 8 badges; state roundtrip passes |
| Platinum | CPUE revision 1 | Union Room; Colosseum battles | CPUE/CPUE trade and bilateral cold reload; Union Room exit; trade-to-Colosseum transition; two battles with turn exchange and completed forfeit exits; faint/replacement passed |
| HeartGold | IPKE revision 0 | Union Room; Colosseum battles | Boots public save: 16 badges; state roundtrip passes |
| SoulSilver | IPGE revision 0 | Union Room; Colosseum battles | Boots public save: 16 badges; state roundtrip passes |
| Black | IRBO revision 0 | Union Room; C-Gear IR starts a separate IR-to-wireless route | Boots public save: 8 badges; state roundtrip passes; IR unimplemented |
| White | IRAO revision 0 | Union Room; C-Gear IR starts a separate IR-to-wireless route | Boots public save: 8 badges; state roundtrip passes; IR unimplemented |
| Black 2 | IREO revision 0 | Union Room; C-Gear IR starts a separate IR-to-wireless route | Boots public save: 8 badges; state roundtrip passes; IR unimplemented |
| White 2 | IRDO revision 0 | Union Room; C-Gear IR starts a separate IR-to-wireless route | Boots public save: 8 badges; state roundtrip passes; IR unimplemented |

The admission filter permits the five Gen 4 titles to pair with one another,
including same-title pairs, and the four Gen 5 titles to pair with one another,
including same-title pairs. It rejects ordinary cross-generation trade/battle
pairing. This filter is not a game compatibility result; the games still govern
unlocks, languages, available Pokemon/forms/items and battle rules.

The nine-code Cartesian matrix has 81 ordered admission cases: 41 admitted and
40 rejected. Synthetic tests pass bidirectional raw packet exchange, duplicate
suppression, radio-off transitions, repeated sessions, hold/release and explicit
same-peer continuation. They execute no Pokemon logic and verify no actual saves.

Two-player sessions are the present transport scope. Four-player Multi Battle,
other multiplayer activities, Download Play and cartridge infrared are not
implemented or established. In particular, Gen 5 infrared trade/battle is a
distinct cartridge peripheral; the audited upstream has a TODO for actual IR
communication. This is an emulator gap, not a game restriction.

The initial CPUE/CPUE test used cloned public saves and did not display the peer.
The successful discovery retest used disposable public-derived saves with distinct
trainer IDs (checksums verified) and distinct test firmware MAC values. It must
not be treated as testing two real user saves. Because the original parties were
clones, exchanging different slots leaves duplicate Pokemon in the fixtures;
this proves the exchange and persistence, not Pokemon legality. The production bridge never edits
firmware identity: identical existing MACs block pairing. Solving that collision
while preserving existing Pokemon saves remains an implementation gap.

The actual desktop harness uses two native core processes and a local TCP channel
around the unchanged production C++ protocol; it does not exercise iOS Multipeer
Connectivity. The original stepping harness paused each process at command
boundaries and slowed sharply during the native contact handshake. A continuous
frame pump is used for subsequent game-flow testing. No cartridge/save/firmware
input is published or included in CI artifacts.

The actual Union Room battle attempt displayed the game's requirement for two
Pokemon at level 30 or lower. The disposable parties were level 65, so that
restriction is a game rule. The Colosseum's No Restrictions route accepts these
parties and was tested separately. The
desktop transport's parked radio-off state was observed; the iOS five-second
fenced teardown, automatic same-peer rejoin and prompt behavior still require
physical verification.

Nintendo WFC/GTS/friend-code service access is a separate path. The transport's
local detector rejects infrastructure ToDS/FromDS frames and recognizes Nintendo
CMD/reply frames or local host vendor beacons. Passive-scanner activation and
avoiding false discovery in WFC flows still need real game verification.

Relevant primary emulator sources:

- [libretro's melonDS DS LAN documentation](https://github.com/libretro/docs/blob/master/docs/library/melonds_ds.md#lan-netplay)
- [melonDS DS v1.3.1 packet transport](https://github.com/JesseTG/melonds-ds/blob/v1.3.1/src/libretro/net/mp.cpp)
- [melonDS DS v1.3.1 lifecycle callbacks](https://github.com/JesseTG/melonds-ds/blob/v1.3.1/src/libretro/platform/mp.cpp)
- [Current melonDS infrared cartridge implementation](https://github.com/melonDS-emu/melonDS/blob/master/src/NDSCart/CartRetailIR.cpp)
- [Nintendo explains the Gen 5 IR-to-local-wireless connection](https://iwataasks.nintendo.com/interviews/ds/pokemon-black-white/0/2/)

Physical evidence must record: exact title/code/revision on each device; mode;
trade completed on both; both saved, closed and reloaded with the traded result;
battle completed; both exited; fresh discovery; repeated session; trade-to-battle
transition; interruption behavior. Desktop and simulator evidence stays separate.
