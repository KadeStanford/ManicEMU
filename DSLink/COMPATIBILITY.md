# Compatibility and validation status

Latest physical evidence is explicitly confirmed DS v0.8 on both phones.
The user reports HeartGold/SoulSilver trading and battling work, with remaining
interaction slowdown/stutter. Completion, bilateral cold save persistence and
repeat transitions are not independently confirmed on that revision.
Black/White trainers are visible, but talking fails; a trade stalled at
"The trade will be started!" for minutes, then both games reported communication
errors and returned to the Union Room at full speed. That pairing is physically
failing. Exact phone cartridge revisions/models remain unrecorded.
DS v0.9 corrects two proven native receive-boundary defects and adds consolidated
diagnostics. It requires physical verification; older desktop results do not
supersede the phone failures or prove a definitive fix.

| Exact authorized title/header version | Legitimate native local routes | Pairings with actual gameplay evidence | Evidence revision and limits |
|---|---|---|---|
| Diamond ADAE rev5 | Union Room trade/battle; Colosseum | Pearl APAE rev5 | Older v0.2 desktop trade, valid bilateral saves/cold Continue, two forfeit battles, trade-to-battle and normal exits passed. v0.9 phone pending. |
| Pearl APAE rev5 | Union Room trade/battle; Colosseum | Diamond ADAE rev5 | Same independent two-console v0.2 desktop series. v0.9 phone pending. |
| Platinum CPUE rev1 | Union Room trade/battle; Colosseum | Platinum CPUE rev1 | v0.2 desktop trade/cold Continue/exits passed. Earlier v0.1 distinct-MAC series completed two forfeits with matching moves, faint/replacement and repeat battle. Final candidate pending. |
| HeartGold IPKE rev0 | Union Room standard trade/battle, HGSS Spin Trade; Colosseum | SoulSilver IPGE rev0 | v0.2 desktop trade/cold Continue/exits/two forfeits; v0.4 native pair transport completed full-party knockout, fresh rejoin/reversed roles, second forfeit and bilateral save/cold Continue. Spin Trade pending. v0.8 phone user reports trading/battling work with stutter; current completion/persistence/repeats unconfirmed. v0.9 pending. |
| SoulSilver IPGE rev0 | Same HGSS routes | HeartGold IPKE rev0 | Same independent desktop series; v0.8 phone user reports trading/battling work with stutter. No independently confirmed current persistence/completion claim. |
| Black IRBO rev0 | Union Room wireless trade/battle; C-Gear cartridge IR route | White IRAO rev0 | v0.6 exact-source desktop Room v7 showed both trainers, native Hello/activity/Trade, bilateral valid native saves and fresh normal Continue. Native Trade Quit returned to activity. Battle completion and final repeat/exits pending. v0.8 phone trainers visible; talking/trade stall then communication errors; failed interaction. v0.9 pending. |
| White IRAO rev0 | Same Gen5 routes | Black IRBO rev0 | Same independent desktop v0.6 series. v0.8 phone interaction/trade fails; no MultipeerConnectivity completion proof. |
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

DS v0.9 focused checks compile the actual replacement receive function against
an independent queue stub and exercise empty replies, real payload copying,
AID15/maximum frame bounds, stale/duplicate/bystander rejection, timestamp
underflow and sustained unrelated traffic. Opaque frame tests cover all nine
recognized titles. UIKit tests exercise automatic discovery, core-thread
callbacks, independent checkpoint/persistence, repeated radio lifecycle and
CoreShim initialization for memory/path loading. These are synthetic/Simulator
checks; they do not replace physical MPC, actual native iPhone save-path,
wireless timing, complete battle or repeated-session validation. Production RF
tests additionally cover loss/reordering, bounded fragmentation, independent
reliable controls, all 41 admitted title pairings, eight source slots, native
exit/reentry and old-session rejection. These are synthetic admission and
carrier checks, not actual cartridge pairing evidence.

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
USB diagnostics now succeed through existing trust, without pairing or device
writes. Only the bounded numeric ManicDSDiagnostics/current.json was read.
Two same-session Black/White stalled-trade samples cover 106.14 seconds, with
1496 frames and 68.00% native time in receive waiting. A second user-requested
active Black slowdown interval measured 67.99%. These are one-phone numeric
samples, with no measured RF/fragment drops or identity/address rejections.
They do not measure end-to-end network latency or identify rejected-reply
reasons. The new bounded local diagnostics include both native packet metadata
and user-authorized packet contents. No private captures belong in source/CI.

Primary references: [melonDS DS LAN limits](https://github.com/libretro/docs/blob/master/docs/library/melonds_ds.md#lan-netplay),
[melonDS DS v1.3.1 native receive](https://github.com/JesseTG/melonds-ds/blob/v1.3.1/src/libretro/libretro.cpp),
[native melonDS local radio](https://github.com/melonDS-emu/melonDS/blob/master/src/Wifi.cpp),
[Nintendo's Gen5 IR description](https://iwataasks.nintendo.com/interviews/ds/pokemon-black-white/0/2/).
