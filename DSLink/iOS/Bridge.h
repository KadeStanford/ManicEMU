// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <cstddef>
#include <cstdint>
#include <libretro.h>
#include "../Core/Diagnostics.hpp"
struct MDSCore {
    void *(*memory)(unsigned);
    size_t (*memorySize)(unsigned);
    size_t (*stateSize)();
    bool (*serialize)(void *,size_t);
    bool (*wirelessIdentity)(uint8_t *);
    bool (*firmwareIdentityMatches)();
    bool (*localIdentityMatches)();
    uint32_t (*identityRequests)();
};
void MDS_gameLoaded(const char code[4],uint8_t revision,MDSCore core);
void MDS_gameUnloading();
void MDS_netpacket(const retro_netpacket_callback *callbacks);
void MDS_signal(unsigned event,const void *packet);
void MDS_trace(const manicds::NativeDiagnostic& trace);
void MDS_coreOption(const char *key,const char *value);
void MDS_video(unsigned width,unsigned height,bool duplicate);
void MDS_audio(size_t frames,size_t consumed);
bool MDS_beforeFrame();
void MDS_afterFrame(double nativeMilliseconds=0,bool finalSnapshot=false);
void MDS_waitForPackets(uint32_t microseconds);
bool MDS_allowRestore();
