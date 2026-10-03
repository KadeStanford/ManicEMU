# Experimental local Game Boy link

This fork implements a real two-machine DMG cable engine and an encrypted local
session for two iPhones. It targets original Pokémon Red/Blue's MBC3 + 32 KB RAM
battery cartridge, not GBA Pokémon FireRed, Mother 3 or GBA multiplayer. It is
experimental until a complete trade is verified on two physical phones.

## Implemented

The host runs both GBs using SameBoy's bit callbacks and emulated-cycle scheduler.
The guest supplies its own selected battery save and the SHA256 of its locally
selected ROM. Both must independently possess exactly the same ROM; ROM bytes
never cross the network. The host loads its selected ROM for both instances.
Player 0 is the host, player 1 the guest. Guest input drives only player 1 and
guest battery exports contain only player 1's SRAM. Host exports contain player
0's SRAM. Each player has a separate display and controls.

MultipeerConnectivity requires encryption, uses a six-digit invitation code,
and advertises `_manic-gblink._tcp`. It can use local Wi-Fi/AWDL/Bluetooth; keep
both phones on good Wi-Fi. This is a host/guest screen-streaming implementation.
The guest receives RGB565 video (46,080 bytes/frame). At 59.73 fps this is about
2.75 MB/s before transport overhead. One input request is outstanding at a time;
network latency slows both emulated machines together instead of changing cable
bit timing. There is no audio, GBC-specific mode, rewind, save-state loading or
fast-forward in the link screen.

Disconnect, a ten-second receive timeout or backgrounding freezes the pair.
Keep both apps open; find the same host again to resume. The original guest save,
ROM hash, peer identity and frame counter are checked on reconnect. A lost last
frame response permits resuming one frame ahead. Another peer or stale/future
input cannot reset or advance the pair. Closing/killing the host discards its
in-memory pair: resume then requires battery snapshots rather than continuing
the live trade. Guest recovery snapshots may lag by up to 120 emulated frames.

## Saves and playing

1. Exit ordinary Manic gameplay and back up each person's battery save using
   Manic's existing **Export Save** option. Do not use a save state.
2. Open **Game Boy Link (local)** from a GB game's options in a source-built
   fork, or the **GB Link** overlay in a repackaged sideload app.
3. Both select their own ROM and their own `.sav`/`.srm` battery file (exactly
   32,768 bytes). A fresh game is also possible. No other files are read/shared.
4. One presses **Host**, tells the friend the displayed host name and code, and
   keeps the screen open. The friend enters the code, presses **Find / Reconnect**
   and selects that host. Local Network permission must be allowed on both.
   Selecting Host/Join is explicit consent to sharing the selected battery with
   the host; no internet service receives it.
5. Both games boot from their selected batteries. Use the in-game cable club.
   After a trade, complete an in-game save on **both** games, then each presses
   **Export my new battery save**. Export writes a unique file under
   `Documents/GBLinkExports`, and opens the share sheet. Original saves, normal
   core settings and cloud-sync files are never overwritten by this library.
6. Keep the original backups. Close the link session. Use Manic's existing
   **Import Save** on each person's matching original GB game/core to import
   their own exported file, then verify the result. State files from mGBA or
   other cores are incompatible with this session. SRAM has no added wrapper.

An interrupted trade can leave an incomplete battery snapshot. Recovery exports
are separate files, not a guarantee that the game's trade transaction completed.
Verify both parties' results before replacing any originals. This version does
not implement a distributed atomic save commit.

## No-Mac build and IPA route

The `GB Link` GitHub Actions workflow builds the unsigned arm64 iOS 15+ framework
on a macOS runner, using public Xcode frameworks and SameBoy's source-assembled,
Expat-licensed replacement DMG bootstrap. It uses no developer certificates,
Apple login, paid components, Nintendo BIOS or game ROM. Download the
`ManicGBLink-unsigned` artifact from a successful run. Extract it so the binary
and Info.plist are inside a directory named `ManicGBLink.framework` (Actions
may place the framework contents at the archive root).

On Windows, Linux or macOS with Python 3:

```text
python GBLink/scripts/ipa_link.py your-original-sideload.ipa --inspect
python GBLink/scripts/ipa_link.py your-original-sideload.ipa --framework ManicGBLink.framework --output Manic-GBLink-unsigned.ipa
```

The input IPA is preserved. The tool validates arm64 Mach-O, an unencrypted
executable, safe ZIP paths, header padding, the framework, and binary/XML plist.
It adds a normal `LC_LOAD_DYLIB` command, embeds the source-built framework and
opts into its public-API overlay launcher. It changes no bundle ID, account,
entitlements or provisioning credentials. Previous signature resources become
invalid and are removed. **The output is unsigned and cannot be installed as-is.**
Re-sign the app and *every* embedded framework with your existing sideload tool
and account. Do not redistribute the original app's paid/proprietary components
without permission; preserve applicable notices/source obligations. This fork
only distributes its added source and library, not someone else's packaged IPA.

Use an official unencrypted sideload IPA or your own source build. Encrypted
App Store binaries, arm64e, multi-architecture binaries and insufficient header
padding are explicit blockers. The tool does not decrypt, move code sections,
bypass DRM or install onto a device. Original bundled resources, including
`System.core`, are copied byte for byte into the user's private output. Each
IPA must be inspected independently; repackaging alone does not establish that
it boots on a signed device.

A jailbreak is unnecessary for this embedding design. Friends' phones need
ordinary valid signing because the framework uses public APIs; they need no
jailbreak hooks. The added screen reads explicitly selected/exported files
instead of probing private app memory. If inspection is needed, the smallest
read-only input is the selected sideload IPA's main executable and Info.plist
(architecture/encryption/padding/version); no photos, accounts, keychain,
unrelated app data or signing settings are needed. Keep the phone disconnected
until a specific file-inspection need exists.

For a full Manic source build, embed `ManicGBLink.framework` in the app target's
**Frameworks, Libraries and Embedded Content** using **Embed & Sign**. The new
Swift option dynamically opens it and supplies only the chosen game's ROM and
current battery URL. Existing Manic dependencies still need their documented
macOS/Xcode, submodules and binary cores. A full Manic build was not run here.

## Verification and provenance

Run legal tests without any game/BIOS download:

```text
cmake -S GBLink -B build-gblink -DCMAKE_C_COMPILER=clang
cmake --build build-gblink
ctest --test-dir build-gblink --output-on-failure
python -m unittest discover -s GBLink/Tests -p "test_*.py" -v
```

CI uses ASan/UBSan. Core tests exercise 512 byte transfers with both master
roles, DMG transfer timing, serial IRQs, external-clock wait, pending-transfer
resume, save isolation/import/export, 120 frames, pause and input sequence gates,
plus 20,000 malformed-packet fuzz cases. A real loopback TCP harness injects
20 ms delays, fragments requests, drops a partial packet, reconnects the same
pair and rejects duplicate execution. The Python tests use synthetic Mach-O/IPA
fixtures to verify embedding, encryption/architecture/padding blockers, input
preservation, unrelated settings, ZIP traversal and duplicate protection.
They check raw ZIP backslashes on Windows and unchanged bundled resources too.

The macOS job also compiles/links the iOS library with warnings as errors,
type-checks the actual added Swift bridge against small dependency stubs, parses
the changed option files, and launches the frontend in an iOS simulator for a
UI smoke screenshot. These checks do **not** validate physical MCSession Wi-Fi,
real two-device Pokémon trading, signing/installation or a full Manic build.

Lineage: official [Manic-EMU/ManicEMU](https://github.com/Manic-EMU/ManicEMU)
at `fbaeab79c214d5920bb51afa6f2d786fb2b12a58`; the GitHub fork parent is
verified. Its Libretro submodule is Daiuno/RetroArch at
`00689c83f4d458e061d5fd7b52a181b8d240fe65`. GB defaults use Gambatte,
mGBA or VBA-M in this checkout. The bundled mGBA binary is LFS-only and its
exact build revision is unknown; no binary serial ABI is assumed.

Native [mGBA GB SIO source](https://github.com/mgba-emu/mgba/tree/c3c8e5e813f245028de118a56734e1dc0f35ce2a/src/gb/sio)
has `GBSIODriver` / `GBSIOLockstep`, distinct from GBA SIO. Its
[libretro source](https://github.com/mgba-emu/mgba/blob/c3c8e5e813f245028de118a56734e1dc0f35ce2a/src/platform/libretro/libretro.c)
uses a single core and returns false from `retro_load_game_special`; Manic's
pinned bridge header has no GB cable API. Merely enabling generic netplay would
not create two GBs or a cable.

SameBoy Core/BootROMs are vendored unmodified from
`213a12ce93d66b105a113debd9396306066a7cfc`. Its
[libretro linked-pair implementation](https://github.com/LIJI32/SameBoy/blob/213a12ce93d66b105a113debd9396306066a7cfc/libretro/libretro.c)
provides the scheduling/callback reference. Only its Expat-licensed core and
bootstrap sources are used; its separately conditioned iOS UI is not copied.
Our additions follow Manic's AGPL-3.0-or-later license; both notices are included
in the framework. No existing Manic projects, saves or experiments were edited.
