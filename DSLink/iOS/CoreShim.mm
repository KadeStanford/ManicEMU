// SPDX-License-Identifier: AGPL-3.0-or-later
// Public libretro ABI forwarding shim. The pinned original DS engine stays in
// its own signed framework; no app/main, GBA, Azahar or AirPlay code is replaced.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <chrono>
#include "Bridge.h"
#include "../Core/Protocol.hpp"
#include "GeneratedConsole.h"
static retro_environment_t frontend;
static bool localPokemon=false;
static uint32_t identityRequests=0;
#ifndef MDS_TESTING
static void *engine;
#endif
static void *symbol(const char *name){
#ifdef MDS_TESTING
    return MDS_testEngineSymbol(name);
#else
    if(!engine){
        NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/DSOriginal.framework/DSOriginal"];
        engine=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL|RTLD_FIRST);
    }
    return engine?dlsym(engine,name):nullptr;
#endif
}
template<class F> static F original(const char *name){return reinterpret_cast<F>(symbol(name));}
struct Event {uint32_t number,reserved;const void *packet;};
static bool environment(unsigned command,void *data){
    if(command==0x4d445303){bool ok=localPokemon&&generatedConsole(static_cast<MDSGeneratedConsole*>(data));if(ok)identityRequests++;return ok;}
    if(command==0x4d445302){
        if(!data)return false;const auto *p=static_cast<const uint32_t*>(data);
        if(p[1]||p[0]>1000)return false;MDS_waitForPackets(p[0]);return true;
    }
    if(command==0x4d445301){
        if(data){const auto *e=static_cast<const Event*>(data);if(!e->reserved&&e->number<=9)MDS_signal(e->number,e->packet);}
        return true;
    }
    if(command==RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE){
        if(!data)return false;MDS_netpacket(static_cast<const retro_netpacket_callback*>(data));return true;
    }
    return frontend&&frontend(command,data);
}
extern "C" void retro_set_environment(retro_environment_t cb){
    frontend=cb;auto f=original<decltype(&retro_set_environment)>("retro_set_environment");if(f)f(environment);
}
static uint32_t requests(){return identityRequests;}
static bool localMatches(){
    using Identity=bool(*)(uint8_t*);auto f=original<Identity>("manic_ds_wireless_identity");
    MDSGeneratedConsole expected{1,{},{}};uint8_t native[6]{};
    return identityRequests&&localPokemon&&generatedConsole(&expected)&&f&&f(native)&&!std::memcmp(native,expected.mac,6);
}
extern "C" bool retro_load_game(const retro_game_info *info){
    identityRequests=0;
    char code[4]{};uint8_t revision=0;
    // Read only the authorized game's standard 32-byte cartridge header.
    if(info&&info->data&&info->size>=32){std::memcpy(code,static_cast<const uint8_t*>(info->data)+12,4);revision=static_cast<const uint8_t*>(info->data)[30];}
    else if(info&&info->path){FILE *file=std::fopen(info->path,"rb");if(file){uint8_t header[32];if(std::fread(header,1,32,file)==32){std::memcpy(code,header+12,4);revision=header[30];}std::fclose(file);}}
    localPokemon=manicds::title(code)!=0;
    auto f=original<decltype(&retro_load_game)>("retro_load_game");if(!f||!f(info)){localPokemon=false;return false;}
    using Identity=bool(*)(uint8_t*);
    using Matches=bool(*)();
    MDSCore core{original<decltype(&retro_get_memory_data)>("retro_get_memory_data"),original<decltype(&retro_get_memory_size)>("retro_get_memory_size"),original<decltype(&retro_serialize_size)>("retro_serialize_size"),original<decltype(&retro_serialize)>("retro_serialize"),original<Identity>("manic_ds_wireless_identity"),original<Matches>("manic_ds_firmware_identity_matches"),localMatches,requests};
    // A reset-capable engine is mandatory. The diagnostic binary patch lacks
    // queue reset; it cannot enable a feature IPA merely by having event hooks.
    using Revision=unsigned(*)();auto revisionFn=original<Revision>("manic_ds_protocol_revision");
    char disabled[4]{};MDS_gameLoaded(revisionFn&&revisionFn()==7?code:disabled,revision,core);return true;
}
extern "C" void retro_run(){
    if(!MDS_beforeFrame())return;
    auto begin=std::chrono::steady_clock::now();auto f=original<decltype(&retro_run)>("retro_run");if(f)f();
    MDS_afterFrame(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count());
}
extern "C" void retro_unload_game(){MDS_gameUnloading();localPokemon=false;auto f=original<decltype(&retro_unload_game)>("retro_unload_game");if(f)f();}
extern "C" void retro_deinit(){MDS_gameUnloading();localPokemon=false;auto f=original<decltype(&retro_deinit)>("retro_deinit");if(f)f();}
extern "C" bool retro_unserialize(const void *data,size_t size){
    if(!MDS_allowRestore())return false;auto f=original<decltype(&retro_unserialize)>("retro_unserialize");return f&&f(data,size);
}
extern "C" void retro_reset(){if(MDS_allowRestore()){auto f=original<decltype(&retro_reset)>("retro_reset");if(f)f();}}
#define VOID_FORWARD(name,args,call) extern "C" void name args {auto f=original<decltype(&name)>(#name);if(f)f call;}
#define VALUE_FORWARD(type,name,args,call,fallback) extern "C" type name args {auto f=original<decltype(&name)>(#name);return f?f call:fallback;}
VOID_FORWARD(retro_init,(),())
VOID_FORWARD(retro_set_video_refresh,(retro_video_refresh_t cb),(cb))
VOID_FORWARD(retro_set_audio_sample,(retro_audio_sample_t cb),(cb))
VOID_FORWARD(retro_set_audio_sample_batch,(retro_audio_sample_batch_t cb),(cb))
VOID_FORWARD(retro_set_input_poll,(retro_input_poll_t cb),(cb))
VOID_FORWARD(retro_set_input_state,(retro_input_state_t cb),(cb))
VOID_FORWARD(retro_get_system_info,(retro_system_info *info),(info))
VOID_FORWARD(retro_get_system_av_info,(retro_system_av_info *info),(info))
VOID_FORWARD(retro_set_controller_port_device,(unsigned port,unsigned device),(port,device))
VOID_FORWARD(retro_cheat_reset,(),())
VOID_FORWARD(retro_cheat_set,(unsigned index,bool enabled,const char *code),(index,enabled,code))
VALUE_FORWARD(unsigned,retro_api_version,(),(),RETRO_API_VERSION)
VALUE_FORWARD(unsigned,retro_get_region,(),(),RETRO_REGION_NTSC)
VALUE_FORWARD(void*,retro_get_memory_data,(unsigned id),(id),nullptr)
VALUE_FORWARD(size_t,retro_get_memory_size,(unsigned id),(id),0)
VALUE_FORWARD(size_t,retro_serialize_size,(),(),0)
VALUE_FORWARD(bool,retro_serialize,(void *data,size_t size),(data,size),false)
// Slot-2 subsystem launching remains native and never starts the Pokemon bridge.
VALUE_FORWARD(bool,retro_load_game_special,(unsigned type,const retro_game_info *info,size_t size),(type,info,size),false)
// Manic's custom layout and DNS exports must survive wrapper selection.
extern "C" void set_melonds_custom_layout(const char *value){using F=void(*)(const char*);auto f=original<F>("set_melonds_custom_layout");if(f)f(value);}
extern "C" void set_melonds_wfc_dns(const char *value){using F=void(*)(const char*);auto f=original<F>("set_melonds_wfc_dns");if(f)f(value);}
