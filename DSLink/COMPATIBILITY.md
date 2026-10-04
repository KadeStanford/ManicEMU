# Compatibility and validation status

Latest physical evidence: the user correctly installed the newest DS v0.6 IPA.
Black/White and HeartGold/SoulSilver both showed native Union Room player
messages but no remote avatars, blocking trade and battle interaction. v0.6 is
FAILED for those physical flows. Older HGSS working reports and passing desktop
screenshots do not supersede that result. DS v0.7 is a corrective candidate;
its physical validation is pending.

| Exact authorized title/header version | Legitimate native local routes | Pairings with actual gameplay evidence | Evidence revision and limits |
|---|---|---|---|
| Diamond ADAE rev5 | Union Room trade/battle; Colosseum | Pearl APAE rev5 | Older v0.2 desktop trade, valid bilateral saves/cold Continue, two forfeit battles, trade-to-battle and normal exits passed. v0.7 and phone pending. |
| Pearl APAE rev5 | Union Room trade/battle; Colosseum | Diamond ADAE rev5 | Same independent two-console v0.2 desktop series. v0.7 and phone pending. |
| Platinum CPUE rev1 | Union Room trade/battle; Colosseum | Platinum CPUE rev1 | v0.2 desktop trade/cold Continue/exits passed. Earlier v0.1 distinct-MAC series completed two forfeits with matching moves, faint/replacement and repeat battle. Final candidate pending. |
| HeartGold IPKE rev0 | Union Room standard trade/battle, HGSS Spin Trade; Colosseum | SoulSilver IPGE rev0 | v0.2 desktop trade/cold Continue/exits/two forfeits; v0.4 native pair transport completed full-party knockout, fresh rejoin/reversed roles, second forfeit and bilateral save/cold Continue. Spin Trade pending. Latest v0.6 phone presence FAILED; v0.7 pending. |
| SoulSilver IPGE rev0 | Same HGSS routes | HeartGold IPKE rev0 | Same independent desktop series and latest physical failure; no phone persistence/completion claim. |
| Black IRBO rev0 | Union Room wireless trade/battle; C-Gear cartridge IR route | White IRAO rev0 | v0.6 exact-source desktop Room v7 showed both trainers, native Hello/activity/Trade, bilateral valid native saves and fresh normal Continue. Native Trade Quit returned to activity. Battle completion and final repeat/exits pending. Latest v0.6 phone presence FAILED. |
| White IRAO rev0 | Same Gen5 routes | Black IRBO rev0 | Same independent desktop v0.6 series; not MultipeerConnectivity or physical proof. |
| Black 2 IREO rev0 | Union Room wireless trade/battle; C-Gear cartridge IR route | None with completed native trade/battle | Authorized boot/save/state checks only. Actual wireless flow and all pairings pending. |
| White 2 IRDO rev0 | Same Gen5 routes | None with completed native trade/battle | Authorized boot/save/state checks only. Actual wireless flow and all pairings pending. |

The transport admits every same-generation title pair, including same-title
pairs: the five Gen4 titles form a 5x5 set; the four Gen5 titles a 4x4 set. The
81 ordered synthetic admission cases contain 41 admitted and 40 rejected.
This is a transport matrix, not a tested-game compatibility promise. All
unlisted pairs remain unverified. Native rules and party/form/item restrictions
remain authoritative, especially when older and newer titles connect.

Game restriction observed in the older Gen4 Union battle test: the native game
required two Pokemon at level30 or lower; the public-derived test party was
level65. The separately tested Colosseum No Restrictions route accepted it.
Do not classify that native refusal as an emulator bug. Conversely, missing
remote avatars, dropped legitimate empty replies, imported-firmware identity
exclusion and absent cartridge infrared are emulator/integration gaps.

Nintendo WFC/GTS/friend codes are separate from local wireless. Direct
cross-generation trades/battles are not supported; Download Play Poke Transfer
is a different one-way transfer route and is not implemented. Cartridge IR
(C-Gear routes), HGSS Spin Trade, multi-player battle completion and all
language/region combinations are not verified. No all-nine phone-support claim.

DS v0.7 focused checks compile the actual replacement receive function against
an independent queue stub and exercise empty replies, real payload copying,
AID15/maximum frame bounds, stale/duplicate/bystander rejection, timestamp
underflow and sustained unrelated traffic. Opaque frame tests cover all nine
recognized titles. UIKit tests exercise automatic discovery, core-thread
callbacks, independent checkpoint/persistence, repeated radio lifecycle and
CoreShim initialization for memory/path loading. These are synthetic/Simulator
checks; they do not replace physical MPC, actual native iPhone save-path,
wireless timing, complete battle or repeated-session validation.

Previous actual desktop tests used separate native core processes, authorized
cartridges and disposable public-derived saves over loopback carriers. No real
user saves were modified. Detailed hashes, selected Pokemon identities and
cold-Continue evidence remain in local JSON reports. CI contains no cartridge,
firmware, save, game screenshot or private plugin input.

Physical verification still required on the corrected combined build: visible
and interactable trainers on both devices, completed native trade, save/close/
normal Continue on both retaining the exchange, completed battle, clean native
exits/reentry, repeats and trade-to-battle transition without emulator prompts.
The physical cartridge revisions/models have not been fully recorded. Read-only
USB diagnostics were unavailable at the latest check; no pairing was attempted.

Primary references: [melonDS DS LAN limits](https://github.com/libretro/docs/blob/master/docs/library/melonds_ds.md#lan-netplay),
[melonDS DS v1.3.1 native receive](https://github.com/JesseTG/melonds-ds/blob/v1.3.1/src/libretro/libretro.cpp),
[native melonDS local radio](https://github.com/melonDS-emu/melonDS/blob/master/src/Wifi.cpp),
[Nintendo's Gen5 IR description](https://iwataasks.nintendo.com/interviews/ds/pokemon-black-white/0/2/).
