// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <stddef.h>
#include <stdint.h>

#define MGL_WIDTH 160
#define MGL_HEIGHT 144
#define MGL_PIXELS (MGL_WIDTH * MGL_HEIGHT)
#define MGL_SAVE_SIZE 32768
#define MGL_PROTOCOL_VERSION 1
#define MGL_MAX_PACKET (MGL_PIXELS * 2 + 64)
typedef struct MGLPair MGLPair;

// Original DMG / MBC3 RAM+battery (no RTC), the Pokémon Red/Blue cartridge
// configuration. Both users independently supply the exact same ROM.
int mgl_validate_rom(const uint8_t *rom, size_t size);
MGLPair *mgl_create(const uint8_t *rom, size_t size,
                    const uint8_t *host_save, size_t host_size,
                    const uint8_t *guest_save, size_t guest_size,
                    const uint8_t *open_boot, size_t boot_size);
void mgl_destroy(MGLPair *pair);
// Run both GBs on one thread, in emulated cycle order. No wall-clock cable IO.
int mgl_frame(MGLPair *pair, uint8_t host_keys, uint8_t guest_keys);
// Transport gate: a paused pair cannot advance. Stale/duplicate/future input
// requests are rejected without mutation. Reconnect keeps the same frame count.
void mgl_set_connected(MGLPair *pair, int connected);
int mgl_advance(MGLPair *pair, uint64_t request, uint8_t host_keys, uint8_t guest_keys);
const uint32_t *mgl_pixels(MGLPair *pair, unsigned player); // RGBA little endian
int mgl_battery(MGLPair *pair, unsigned player, uint8_t save[MGL_SAVE_SIZE]);
uint64_t mgl_frames(const MGLPair *pair);

enum MGLMessage { MGL_HELLO = 1, MGL_READY, MGL_INPUT, MGL_FRAME,
                  MGL_EXPORT, MGL_SAVE, MGL_ERROR };
typedef struct {
    uint8_t type;
    uint64_t sequence;
    const uint8_t *payload;
    size_t size;
} MGLPacket;
// Fixed 16-byte envelope: magic/version/type/zero-reserved/u64 BE sequence.
// Payload size is dictated by message type, never by an untrusted allocation.
int mgl_decode(const uint8_t *bytes, size_t size, MGLPacket *packet);
size_t mgl_encode(uint8_t *out, size_t capacity, uint8_t type,
                  uint64_t sequence, const uint8_t *payload, size_t size);

#ifdef MGL_TEST
#include "gb.h"
GB_gameboy_t *mgl_machine(MGLPair *pair, unsigned player);
unsigned mgl_quantum(MGLPair *pair); // elapsed in SameBoy's 8MHz units
#endif
