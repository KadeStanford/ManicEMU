# Compatibility and evidence

An actual Platinum CPUE revision 1 / CPUE revision 1 Union Room trade passed on
two independent desktop core processes. Infernape "Mario" (PID 2413151600) and
Staraptor "Limit Bird" (PID 3963018234) exchanged selected party slots. Both games
returned to party selection and wrote newer, valid battery-save blocks; both
exchanged Pokemon checksums passed. Fresh emulator processes loaded each battery
save without a state file and retained the exchanged identities. Both games also
returned to the Union Room contact flow and left the room with radio shutdown.

A No Restrictions single battle also ran through the Colosseum after the trade.
This distinct-MAC Platinum battle series used the earlier v0.1 bridge revision
with the same native engine. The final v0.2 production map's default-MAC Platinum
trade, cold reload and exits were verified separately; its Platinum battle check
remains pending.
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
| Diamond | ADAE revision 5 | Union Room; Colosseum battles | ADAE/APAE trade, bilateral newer valid saves and fresh-process battery-only cold reload passed with identical default MACs; post-trade Union exits; trade-to-Colosseum transition; matching turn damage; two completed forfeit battles in the same group |
| Pearl | APAE revision 5 | Union Room; Colosseum battles | ADAE/APAE trade, bilateral newer valid saves and fresh-process battery-only cold reload passed with identical default MACs; post-trade Union exits; trade-to-Colosseum transition; matching turn damage; two completed forfeit battles in the same group |
| Platinum | CPUE revision 1 | Union Room; Colosseum battles | CPUE/CPUE trade and bilateral cold reload; Union Room exit; trade-to-Colosseum transition; two battles with turn exchange and completed forfeit exits; faint/replacement passed |
| HeartGold | IPKE header revision 0 | Union Room standard Trade; HGSS Spin Trade; Colosseum battles | IPKE/IPGE standard trade, bilateral valid saves/cold reload, both Union exits, trade-to-Colosseum transition, matching turn damage, faint/replacement, two completed forfeit battles and both final Colosseum exits passed with default MACs; Spin Trade and full-party knockout pending |
| SoulSilver | IPGE header revision 0 | Union Room standard Trade; HGSS Spin Trade; Colosseum battles | IPKE/IPGE standard trade, bilateral valid saves/cold reload, both Union exits, trade-to-Colosseum transition, matching turn damage, faint/replacement, two completed forfeit battles and both final Colosseum exits passed with default MACs; Spin Trade and full-party knockout pending |
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
this proves the exchange and persistence, not Pokemon legality. A further native
Platinum test used the identical default firmware MAC on both consoles and
translated only the peer transport's 802.11 addresses. Both players appeared,
connected and traded back the selected Pokemon. The production map retains the
native firmware/WFC identity and save payload, with distinct peer aliases only
when identities collide. The exact production C++ map subsequently passed native
CPUE revision 1 / CPUE revision 1 discovery and trading with both firmware MACs
unchanged at 00:09:BF:11:22:33. Both newer native save blocks and exchanged PK4
checksums passed, and separate fresh emulator processes loaded each battery save
without a state file and retained the exchanged identities. A separate fresh
same-MAC production session passed normal Union Room pad exits on both consoles.
These are desktop results; default-MAC Platinum battle completion and physical
phone verification remain pending. The initial production trade series checked only
Down for its second player's exit while it was on the entry mat. Stepping away
and re-entering the pad passed in the separate exit test, so the earlier attempt
does not establish an emulator exit bug.

The actual desktop harness uses two native core processes and a local TCP channel
around the unchanged production C++ protocol; it does not exercise iOS Multipeer
Connectivity. The original stepping harness paused each process at command
boundaries and slowed sharply during the native contact handshake. A continuous
frame pump is used for subsequent game-flow testing. No cartridge/save/firmware
input is published or included in CI artifacts.

Diamond ADAE revision 5 / Pearl APAE revision 5 also passed actual native Union
Room discovery, contact through a Trainer Case offer, and normal room exits on
both consoles with identical default MACs. A later state-assisted fresh session
timed out during contact and displayed the game's cancellation message. A fresh
battery-only session subsequently completed the cross-title trade: Diamond's
Torterra "Nick" (PID 2984372571, species 389) and Pearl's Empoleon "Nigel"
(PID 379005264, species 395) exchanged selected slots. Both games returned to
party selection with the received Pokemon, both wrote newer valid native saves,
all party checksums passed, and both independent fresh processes loaded the
traded batteries without state input and retained the exchanged identities.
Both players completed the normal trade Quit confirmations, returned to the Union
activity flow and left the room normally. The same running cores and desktop
transport then entered the Colosseum, using Single Battle / No Restrictions.
Both reflected the matching BubbleBeam / Crunch turn: Empoleon's HP changed from
203 to 176 and Torterra's from 251 to 203. Diamond forfeited the first battle;
Pearl forfeited the second battle in the same group. Both returned to the arena
after each battle and subsequently completed both normal Colosseum exit
confirmations, returned to the Pokemon Center and shut their radios down.
The final native saves retained the traded party identities and valid checksums.
All-party knockout completion has not been tested. Several harness timing details
also changed during the earlier contact retest, so its timeout cause is not established.
This does not establish all-pair or physical phone success.

HeartGold IPKE header revision 0 / SoulSilver IPGE header revision 0 also passed
native discovery and the standard Union Room Trade request/response flow on the
final v0.2 C++ protocol and address map, with both firmware MACs unchanged at
00:09:BF:11:22:33. HeartGold's Meganium "HDChipCard" (PID 1729677535) and
SoulSilver's Typhlosion "Math" (PID 2483307331) exchanged party slot zero.
Both wrote newer valid native save blocks, all party PK4 checksums passed,
trainer IDs and the five unselected party members stayed intact, and both
fresh processes cold-loaded their traded batteries without state input.
Both completed normal Trade Quit confirmations, returned to the Union contact
flow and exited the Union Room normally. The HGSS menu additionally offers
Spin Trade; it has not yet been tested. The same cores and desktop transport
then entered Colosseum Single Battle / No Restrictions. Both displayed Meganium's
knockout from Flamethrower and its replacement with Espeon. In the next turn,
Psychic changed Typhlosion's HP from 294 to 126, and Flamethrower changed
Espeon's from 276 to 165 on both consoles. HeartGold forfeited the first battle,
SoulSilver forfeited a second battle in the same group, and both returned to
the arena. The normal Colosseum exit returned both to the Pokemon Center with
both radios off; final native batteries retained the traded party, trainer IDs
and valid checksums. Full-party knockout and fresh transport rejoin remain
pending. These native desktop results exclude
physical iPhone discovery, frontend save paths and Multipeer reconnect prompts.

The actual Union Room battle attempt displayed the game's requirement for two
Pokemon at level 30 or lower. The disposable parties were level 65, so that
restriction is a game rule. The Colosseum's No Restrictions route accepts these
parties and was tested separately. The
desktop transport's parked radio-off state was observed; the iOS five-second
fenced teardown, automatic same-peer rejoin and prompt behavior still require
physical verification.

Nintendo WFC/GTS/friend-code service access is a separate path. The transport's
local detector recognizes native Nintendo CMD/reply packets, Nintendo local
destination addresses and host vendor beacons. Ordinary infrastructure frames
without those markers do not start discovery. Nintendo multiplayer itself uses
ToDS/FromDS flags (native reply 0x0158 and ACK 0x0218), so those flags alone cannot
identify WFC. Passive-scanner activation and
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
