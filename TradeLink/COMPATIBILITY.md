# Gen3 cable support and evidence

v0.6 recognizes Ruby (AXV), Sapphire (AXP), Emerald (BPE), FireRed (BPR) and
LeafGreen (BPG) cartridge headers. All use the actual gpSP Gen3 multiplayer
engine. The shared room-exit classifier now covers all five families; menu,
animation and battle-return subconnections retain their session even during a
long hardware-off handoff. No game addresses, save edits or FireRed-only party
layouts are used. Game data is forwarded unchanged.

The header language byte must match on both phones. The executed matrix uses
English `AXVE`, `AXPE`, `BPEE`, `BPRE`, `BPGE` fixtures only. Header recognition
alone does not validate another locale, cartridge revision or ROM hack.

| Pair | Trade / Single / Double transport enabled | Synthetic protocol traces, both peer roles | Actual two-phone game evidence |
| --- | --- | --- | --- |
| Ruby / Ruby | Yes, subject to game rules | Automated matrix | Not run |
| Ruby / Sapphire | Yes, subject to game rules | Automated matrix | Not run |
| Ruby / Emerald | Yes, subject to game rules | Automated matrix | Not run |
| Ruby / FireRed | Yes, subject to game rules | Automated matrix | Not run |
| Ruby / LeafGreen | Yes, subject to game rules | Automated matrix | Not run |
| Sapphire / Sapphire | Yes, subject to game rules | Automated matrix | Not run |
| Sapphire / Emerald | Yes, subject to game rules | Automated matrix | Not run |
| Sapphire / FireRed | Yes, subject to game rules | Automated matrix | Not run |
| Sapphire / LeafGreen | Yes, subject to game rules | Automated matrix | Not run |
| Emerald / Emerald | Yes, subject to game rules | Automated matrix | Not run |
| Emerald / FireRed | Yes, subject to game rules | Automated matrix | Not run |
| Emerald / LeafGreen | Yes, subject to game rules | Automated matrix | Not run |
| FireRed / FireRed | Yes, subject to game rules | Automated matrix + dedicated regressions | v0.5 user: trade saved and room exit quiet; battle worked first after loading. Sequential reentry and result pause were faulty. v0.6 pending. Battle mode/revision unspecified. |
| FireRed / LeafGreen | Yes, subject to game rules | Automated matrix | Not run |
| LeafGreen / LeafGreen | Yes, subject to game rules | Automated matrix | Not run |

The matrix runs 25 ordered header pairs, each through Trade -> Single -> Double
without reloading the core: 75 activity traces. It checks every forwarded block
halfword, ordinary frontend holds, long result/return handoffs, explicit two-sided
recovery, asymmetric terminal exits, disk SRAM and fresh bootstrap interrupts.
Its legal ARM-loop ROM has no Pokemon game logic, party structures, evolution,
battle AI or game save-sector checksums. This establishes the shared engine and
transport behavior, not completion of any of these real game combinations.
Other suites cover delay/loss/replay, queue backpressure and save write failures.

Use each game's cable-club flow and matching activity/rules on both devices.
The original games decide whether progression, National Pokedex, cross-region
connection, selected Pokemon, party, eggs or battle rules permit the operation.
The plugin does not bypass these checks or grant items/flags. Emerald's wireless
Union Room, four-player Multi Battle, contests, record mixing and Battle Tower
link modes are outside this two-phone cable-club implementation.

Protocol provenance is pinned to public reconstructed source:

- [Ruby/Sapphire link](https://github.com/pret/pokeruby/blob/5784633ce4ef7ade1a7f2d2d0c288e3d5e6cdd7f/src/link.c),
  [overworld exit](https://github.com/pret/pokeruby/blob/5784633ce4ef7ade1a7f2d2d0c288e3d5e6cdd7f/src/overworld.c):
  `MASTER_HANDSHAKE`/`SLAVE_HANDSHAKE`, CAFE, `sub_80554E4` returns decimal 23,
  `sub_80554BC` waits for both players' exiting state; cable scripts then return
  from the room. `src/cable_club.c` sets 2233/2244 and 2211 for battle handoffs.
- [Emerald definitions](https://github.com/pret/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/include/link.h),
  [overworld exit](https://github.com/pret/pokeemerald/blob/731ad5bfd6e6f265508d0efcca0ba42f9dcf5881/src/overworld.c):
  matching handshake, command and link-type values; `KeyInterCB_SendExitRoomKey`
  and bilateral exiting state. `include/overworld.h` defines EXIT_ROOM as 17 hex.
  `src/cable_club.c:CB2_ReturnFromCableClubBattle` saves and returns to multiplayer
  field; `src/trade.c:CanTradeSelectedMon` retains progression/party checks.
- [FireRed/LeafGreen trace](Tests/TRANSITION_TRACE.md), pinned to
  `037335f4c725d7c9aecdac87066f2002b4bd7e14`.

Only selected source routines were inspected. No Pokemon ROM or official BIOS
was downloaded, copied into fixtures or published.
