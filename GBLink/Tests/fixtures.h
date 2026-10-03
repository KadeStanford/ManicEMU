// Synthetic DMG cartridge; no Nintendo logo, firmware or game data.
#pragma once
#include "MGLCore.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, #x); exit(1); } } while (0)
static uint8_t rom[32768], boot[256], saves[2][MGL_SAVE_SIZE];
static void fixtures(void) {
    rom[0x100] = 0xc3; rom[0x101] = 0x50; rom[0x102] = 1;
    rom[0x150] = 0x18; rom[0x151] = 0xfe;
    rom[0x147] = 0x13; rom[0x148] = 0; rom[0x149] = 3;
    uint8_t sum = 0;
    for (unsigned i = 0x134; i <= 0x14c; i++) sum -= rom[i] + 1;
    rom[0x14d] = sum;
    boot[0] = 0x3e; boot[1] = 1; boot[2] = 0xc3; boot[3] = 0xfe;
    boot[0xfe] = 0xe0; boot[0xff] = 0x50;
    memset(saves[0], 0x35, sizeof(saves[0]));
    memset(saves[1], 0xca, sizeof(saves[1]));
}
