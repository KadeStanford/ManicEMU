// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic ROM and bootstrap are authored here. No Nintendo logo/ROM/BIOS.
#include "MGLCore.h"
#include "memory.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "fixtures.h"
static void cable_test(void) {
    MGLPair *p = mgl_create(rom, sizeof(rom), saves[0], MGL_SAVE_SIZE,
                          saves[1], MGL_SAVE_SIZE, boot, sizeof(boot));
    CHECK(p);
    for (int i = 0; i < 100; i++) mgl_quantum(p);
    GB_gameboy_t *a = mgl_machine(p, 0), *b = mgl_machine(p, 1);
    for (int master = 0; master < 2; master++) {
        GB_gameboy_t *internal = master ? b : a;
        GB_gameboy_t *external = master ? a : b;
        for (int n = 0; n < 256; n++) {
            uint8_t outgoing = n, other = n ^ 0xa5;
            GB_write_memory(internal, 0xff0f, 0);
            GB_write_memory(external, 0xff0f, 0);
            GB_write_memory(internal, 0xff01, outgoing);
            GB_write_memory(external, 0xff01, other);
            GB_write_memory(external, 0xff02, 0x80);
            GB_write_memory(internal, 0xff02, 0x81);
            unsigned steps = 0, cycles = 0;
            while (GB_read_memory(internal, 0xff02) & 0x80) {
                cycles += mgl_quantum(p); steps++;
                CHECK(steps < 10000);
            }
            // Both emulators share 8MHz units; a DMG transfer uses 4096
            // 4MHz clocks on the master. Sum includes the second GB's time.
            CHECK(cycles >= 15000 && cycles < 18000);
            CHECK(GB_read_memory(internal, 0xff01) == other);
            CHECK(GB_read_memory(external, 0xff01) == outgoing);
            CHECK(!(GB_read_memory(external, 0xff02) & 0x80));
            CHECK(GB_read_memory(internal, 0xff0f) & 8);
            CHECK(GB_read_memory(external, 0xff0f) & 8);
        }
    }
    // An external-clock machine must wait without a clock partner.
    GB_write_memory(a, 0xff02, 0);
    GB_write_memory(b, 0xff01, 0x42);
    GB_write_memory(b, 0xff02, 0x80);
    for (int i = 0; i < 10000; i++) mgl_quantum(p);
    CHECK(GB_read_memory(b, 0xff02) & 0x80);
    CHECK(GB_read_memory(b, 0xff01) == 0x42);
    // Save ownership and mutation: guest SRAM is distinct, originals immutable.
    uint8_t battery[MGL_SAVE_SIZE];
    CHECK(mgl_battery(p, 0, battery)); CHECK(!memcmp(battery, saves[0], sizeof(battery)));
    CHECK(mgl_battery(p, 1, battery)); CHECK(!memcmp(battery, saves[1], sizeof(battery)));
    GB_write_memory(a, 0, 0x0a); GB_write_memory(a, 0xa000, 0x7b);
    CHECK(mgl_battery(p, 0, battery)); CHECK(battery[0] == 0x7b);
    CHECK(saves[0][0] == 0x35);
    CHECK(mgl_battery(p, 1, battery)); CHECK(battery[0] == 0xca);
    // No tick on disconnect: caller retains the exact pair. Reconnect continues
    // the pending external transfer rather than resetting either GB.
    uint8_t before[MGL_SAVE_SIZE]; CHECK(mgl_battery(p, 0, before));
    CHECK(mgl_frames(p) == 0);
    GB_write_memory(a, 0xff01, 0x99); GB_write_memory(a, 0xff02, 0x81);
    for (int i = 0; i < 2000; i++) mgl_quantum(p);
    CHECK(GB_read_memory(b, 0xff01) == 0x99);
    CHECK(GB_read_memory(a, 0xff01) == 0x42);
    CHECK(mgl_battery(p, 0, battery)); CHECK(!memcmp(before, battery, sizeof(before)));
    mgl_set_connected(p, 0);
    for (int i = 0; i < 120; i++) CHECK(!mgl_advance(p, 0, 0, 0));
    CHECK(mgl_frames(p) == 0);
    CHECK(mgl_battery(p, 0, battery)); CHECK(!memcmp(before, battery, sizeof(before)));
    mgl_set_connected(p, 1);
    CHECK(mgl_advance(p, 0, 0, 0));
    CHECK(!mgl_advance(p, 0, 0, 0)); // duplicate
    CHECK(!mgl_advance(p, 2, 0, 0)); // future
    CHECK(mgl_frames(p) == 1);
    for (int i = 1; i < 120; i++) CHECK(mgl_advance(p, i, 0, 0));
    CHECK(mgl_frames(p) == 120);
    CHECK(mgl_pixels(p, 0) && mgl_pixels(p, 1));
    mgl_destroy(p);
    puts("PASS: 512 bidirectional byte transfers, DMG clock timing, serial IRQs,");
    puts("      external-clock wait, pending-transfer resume, save isolation, 120 frames,");
    puts("      disconnect freeze, reconnect continuation, duplicate/future input rejection");
}
static void protocol_test(void) {
    uint8_t out[MGL_MAX_PACKET], payload[MGL_SAVE_SIZE] = {0}; MGLPacket p;
    CHECK(mgl_encode(out, sizeof(out), MGL_INPUT, UINT64_MAX, payload, 1) == 17);
    CHECK(mgl_decode(out, 17, &p) && p.sequence == UINT64_MAX && p.type == MGL_INPUT);
    for (int i = 0; i < 17; i++) CHECK(!mgl_decode(out, i, &p));
    out[6] = 1; CHECK(!mgl_decode(out, 17, &p)); out[6] = 0;
    out[4]++; CHECK(!mgl_decode(out, 17, &p)); out[4]--;
    out[5] = 255; CHECK(!mgl_decode(out, 17, &p));
    CHECK(!mgl_encode(out, 16, MGL_INPUT, 0, payload, 1));
    CHECK(!mgl_encode(out, sizeof(out), MGL_SAVE, 0, payload, MGL_SAVE_SIZE - 1));
    CHECK(!mgl_encode(out, sizeof(out), MGL_READY, 0, payload, 1));
    CHECK(mgl_encode(out, sizeof(out), MGL_SAVE, 42, payload, sizeof(payload)));
    CHECK(mgl_decode(out, 16 + sizeof(payload), &p) && p.sequence == 42);
    CHECK(!mgl_decode(out, sizeof(out), &p));
    // Fuzz the decoder with bounded arbitrary packets. ASan/UBSan in CI.
    uint32_t seed = 123;
    for (int n = 0; n < 20000; n++) {
        seed = seed * 1664525 + 1013904223; size_t len = seed % sizeof(out);
        for (size_t i = 0; i < len; i++) { seed = seed * 1664525 + 1013904223; out[i] = seed >> 24; }
        CHECK(!mgl_decode(out, len, &p));
    }
    puts("PASS: protocol bounds, truncation, version, reserved bytes, save sizes, 20k fuzz cases");
}
int main(void) {
    fixtures(); CHECK(mgl_validate_rom(rom, sizeof(rom)));
    CHECK(!mgl_create(rom, sizeof(rom), saves[0], 100, saves[1], MGL_SAVE_SIZE, boot, 256));
    rom[0x147] = 0x10; CHECK(!mgl_validate_rom(rom, sizeof(rom))); rom[0x147] = 0x13;
    cable_test(); protocol_test(); return 0;
}
