// Exercise the production, source-assembled SameBoy bootstrap with a legal
// synthetic cartridge. No Nintendo logo, ROM or firmware is used.
#include "fixtures.h"
#include "memory.h"
int main(int argc, char **argv) {
    CHECK(argc == 2); fixtures(); FILE *file = fopen(argv[1], "rb"); CHECK(file);
    CHECK(fread(boot, 1, sizeof(boot), file) == sizeof(boot)); CHECK(fgetc(file) == EOF); fclose(file);
    MGLPair *pair = mgl_create(rom, sizeof(rom), saves[0], sizeof(saves[0]), saves[1], sizeof(saves[1]), boot, sizeof(boot)); CHECK(pair);
    for (int frame = 0; frame < 240; frame++) CHECK(mgl_advance(pair, frame, 0, 0));
    for (unsigned player = 0; player < 2; player++) {
        GB_gameboy_t *gb = mgl_machine(pair, player);
        // After open-source boot, both synthetic CPUs reach JR at $150.
        GB_registers_t *registers = GB_get_registers(gb);
        CHECK(registers->pc == 0x150 || registers->pc == 0x152);
        uint8_t battery[MGL_SAVE_SIZE]; CHECK(mgl_battery(pair, player, battery));
        CHECK(!memcmp(battery, saves[player], sizeof(battery)));
    }
    mgl_destroy(pair); puts("PASS: production open DMG bootstrap boots both synthetic cartridges; batteries preserved");
    return 0;
}
