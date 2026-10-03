// SPDX-License-Identifier: AGPL-3.0-or-later
#include "MGLCore.h"
#include "gb.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    struct MGLPair *pair;
    unsigned index;
    int vblank;
    int outgoing;
} Endpoint;
struct MGLPair {
    GB_gameboy_t *gb[2];
    Endpoint endpoints[2];
    uint32_t pixels[2][MGL_PIXELS];
    int debt;
    uint64_t frames;
};
static uint32_t rgb(GB_gameboy_t *gb, uint8_t r, uint8_t g, uint8_t b) {
    (void)gb;
    return r | (uint32_t)g << 8 | (uint32_t)b << 16 | 0xff000000;
}
static void vblank(GB_gameboy_t *gb, GB_vblank_type_t type) {
    (void)type;
    ((Endpoint *)GB_get_user_data(gb))->vblank = 1;
}
static void serial_start(GB_gameboy_t *gb, bool outgoing) {
    ((Endpoint *)GB_get_user_data(gb))->outgoing = outgoing;
}
static bool serial_end(GB_gameboy_t *gb) {
    Endpoint *e = GB_get_user_data(gb);
    GB_gameboy_t *other = e->pair->gb[1 - e->index];
    bool incoming = GB_serial_get_data_bit(other);
    GB_serial_set_data_bit(other, e->outgoing);
    return incoming;
}
int mgl_validate_rom(const uint8_t *rom, size_t size) {
    // Restrict deliberately: save size and RTC portability must not be guessed.
    if (!rom || size < 32768 || size > 2 * 1024 * 1024) return 0;
    if (rom[0x143] == 0xc0 || rom[0x147] != 0x13 || rom[0x149] != 3) return 0;
    if (rom[0x148] > 6 || size != ((size_t)32768 << rom[0x148])) return 0;
    uint8_t checksum = 0;
    for (unsigned i = 0x134; i <= 0x14c; i++) checksum -= rom[i] + 1;
    return checksum == rom[0x14d];
}
MGLPair *mgl_create(const uint8_t *rom, size_t size,
                    const uint8_t *host_save, size_t host_size,
                    const uint8_t *guest_save, size_t guest_size,
                    const uint8_t *boot, size_t boot_size) {
    if (!mgl_validate_rom(rom, size) || !boot || boot_size != 256 ||
        (host_size && (host_size != MGL_SAVE_SIZE || !host_save)) ||
        (guest_size && (guest_size != MGL_SAVE_SIZE || !guest_save))) return NULL;
    MGLPair *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    for (unsigned i = 0; i < 2; i++) {
        p->gb[i] = GB_alloc();
        if (!p->gb[i]) { mgl_destroy(p); return NULL; }
        GB_init(p->gb[i], GB_MODEL_DMG_B);
        p->endpoints[i] = (Endpoint){p, i, 0, 1};
        GB_set_user_data(p->gb[i], &p->endpoints[i]);
        GB_set_pixels_output(p->gb[i], p->pixels[i]);
        GB_set_rgb_encode_callback(p->gb[i], rgb);
        GB_set_vblank_callback(p->gb[i], vblank);
        GB_set_turbo_mode(p->gb[i], true, true);
        GB_set_turbo_cap(p->gb[i], 0);
        GB_set_emulate_joypad_bouncing(p->gb[i], false);
        GB_load_rom_from_buffer(p->gb[i], rom, size);
        GB_load_boot_rom_from_buffer(p->gb[i], boot, boot_size);
        const uint8_t *save = i ? guest_save : host_save;
        size_t save_size = i ? guest_size : host_size;
        if (save_size) GB_load_battery_from_buffer(p->gb[i], save, save_size);
        if (GB_save_battery_size(p->gb[i]) != MGL_SAVE_SIZE) {
            mgl_destroy(p); return NULL;
        }
        GB_set_serial_transfer_bit_start_callback(p->gb[i], serial_start);
        GB_set_serial_transfer_bit_end_callback(p->gb[i], serial_end);
    }
    return p;
}
void mgl_destroy(MGLPair *p) {
    if (!p) return;
    for (unsigned i = 0; i < 2; i++) if (p->gb[i]) GB_dealloc(p->gb[i]);
    free(p);
}
unsigned mgl_quantum(MGLPair *p) {
    unsigned cycles;
    if (p->debt >= 0) { cycles = GB_run(p->gb[0]); p->debt -= cycles; }
    else { cycles = GB_run(p->gb[1]); p->debt += cycles; }
    return cycles;
}
int mgl_frame(MGLPair *p, uint8_t host_keys, uint8_t guest_keys) {
    if (!p) return 0;
    GB_set_key_mask(p->gb[0], host_keys);
    GB_set_key_mask(p->gb[1], guest_keys);
    p->endpoints[0].vblank = p->endpoints[1].vblank = 0;
    unsigned watchdog = 1000000;
    while ((!p->endpoints[0].vblank || !p->endpoints[1].vblank) && --watchdog)
        mgl_quantum(p);
    if (!watchdog) return 0;
    p->frames++;
    return 1;
}
const uint32_t *mgl_pixels(MGLPair *p, unsigned player) {
    return p && player < 2 ? p->pixels[player] : NULL;
}
int mgl_battery(MGLPair *p, unsigned player, uint8_t save[MGL_SAVE_SIZE]) {
    return p && player < 2 && save &&
        !GB_save_battery_to_buffer(p->gb[player], save, MGL_SAVE_SIZE);
}
uint64_t mgl_frames(const MGLPair *p) { return p ? p->frames : 0; }
#ifdef MGL_TEST
GB_gameboy_t *mgl_machine(MGLPair *p, unsigned player) { return p->gb[player]; }
#endif

static size_t payload_size(uint8_t type) {
    switch (type) {
    case MGL_HELLO: return 32 + MGL_SAVE_SIZE; // SHA256 ROM + battery
    case MGL_READY: case MGL_EXPORT: return 0;
    case MGL_INPUT: return 1;
    case MGL_FRAME: return MGL_PIXELS * 2; // explicit little-endian RGB565
    case MGL_SAVE: return MGL_SAVE_SIZE;
    case MGL_ERROR: return 1;
    default: return SIZE_MAX;
    }
}
int mgl_decode(const uint8_t *bytes, size_t size, MGLPacket *p) {
    if (!bytes || !p || size < 16 || size > MGL_MAX_PACKET ||
        memcmp(bytes, "MGL1", 4) || bytes[4] != MGL_PROTOCOL_VERSION ||
        bytes[6] || bytes[7] || payload_size(bytes[5]) != size - 16) return 0;
    p->type = bytes[5]; p->sequence = 0;
    for (unsigned i = 8; i < 16; i++) p->sequence = (p->sequence << 8) | bytes[i];
    p->payload = bytes + 16; p->size = size - 16;
    return 1;
}
size_t mgl_encode(uint8_t *out, size_t capacity, uint8_t type, uint64_t seq,
                  const uint8_t *payload, size_t size) {
    if (!out || size > MGL_MAX_PACKET - 16 || capacity < size + 16 ||
        payload_size(type) != size || (size && !payload)) return 0;
    memcpy(out, "MGL1", 4); out[4] = MGL_PROTOCOL_VERSION;
    out[5] = type; out[6] = out[7] = 0;
    for (int i = 15; i >= 8; i--) { out[i] = seq & 255; seq >>= 8; }
    if (size) memcpy(out + 16, payload, size);
    return size + 16;
}
