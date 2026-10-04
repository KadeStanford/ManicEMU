// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <cstddef>
#include <cstdint>
#include <libretro.h>
struct MDSCore {
    void *(*memory)(unsigned);
    size_t (*memorySize)(unsigned);
    size_t (*stateSize)();
    bool (*serialize)(void *,size_t);
    bool (*wirelessIdentity)(uint8_t *);
    bool (*firmwareIdentityMatches)();
};
void MDS_gameLoaded(const char code[4],uint8_t revision,MDSCore core);
void MDS_gameUnloading();
void MDS_netpacket(const retro_netpacket_callback *callbacks);
void MDS_signal(unsigned event,const void *packet);
bool MDS_beforeFrame();
void MDS_afterFrame(double nativeMilliseconds=0);
void MDS_waitForPackets(uint32_t microseconds);
bool MDS_allowRestore();
