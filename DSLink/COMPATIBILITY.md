# Compatibility and evidence

No actual Pokemon trade, battle, save/reload, clean room exit or physical phone
session has passed at this checkpoint. Region/revision and game-specific rules
must be recorded with each real test. All nine requested titles are targets.

| Title | Cartridge code prefix | Intended local route | Current game evidence |
|---|---|---|---|
| Diamond | ADA | Local wireless room | Unverified |
| Pearl | APA | Local wireless room | Unverified |
| Platinum | CPU | Local wireless room | Unverified |
| HeartGold | IPK | Local wireless room | Unverified |
| SoulSilver | IPG | Local wireless room | Unverified |
| Black | IRB | Local wireless room; other wireless modes need separate checks | Unverified |
| White | IRA | Local wireless room; other wireless modes need separate checks | Unverified |
| Black 2 | IRE | Local wireless room; other wireless modes need separate checks | Unverified |
| White 2 | IRD | Local wireless room; other wireless modes need separate checks | Unverified |

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

Nintendo WFC/GTS/friend-code service access is a separate path. The transport's
local detector rejects infrastructure ToDS/FromDS frames and recognizes Nintendo
CMD/reply frames or local host vendor beacons. Passive-scanner activation and
avoiding false discovery in WFC flows still need real game verification.

Relevant primary emulator sources:

- [libretro's melonDS DS LAN documentation](https://github.com/libretro/docs/blob/master/docs/library/melonds_ds.md#lan-netplay)
- [melonDS DS v1.3.1 packet transport](https://github.com/JesseTG/melonds-ds/blob/v1.3.1/src/libretro/net/mp.cpp)
- [melonDS DS v1.3.1 lifecycle callbacks](https://github.com/JesseTG/melonds-ds/blob/v1.3.1/src/libretro/platform/mp.cpp)
- [melonDS infrared cartridge implementation](https://github.com/melonDS-emu/melonDS/blob/1.0/src/NDSCart.cpp)

Physical evidence must record: exact title/code/revision on each device; mode;
trade completed on both; both saved, closed and reloaded with the traded result;
battle completed; both exited; fresh discovery; repeated session; trade-to-battle
transition; interruption behavior. Desktop and simulator evidence stays separate.
