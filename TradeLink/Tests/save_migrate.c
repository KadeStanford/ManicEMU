// Exercise libretro's raw battery interface with actual mGBA and gpSP libraries.
#include <libretro.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static bool env(unsigned c,void *data){
    if(c==RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE){*(bool *)data=false;return true;}
    if(c==RETRO_ENVIRONMENT_GET_VARIABLE){struct retro_variable *v=data;if(!strcmp(v->key,"gpsp_bios"))v->value="builtin";else if(!strcmp(v->key,"gpsp_boot_mode"))v->value="game";else return false;return true;}
    return c==RETRO_ENVIRONMENT_SET_PIXEL_FORMAT||c==RETRO_ENVIRONMENT_GET_INPUT_BITMASKS;
}
static void video(const void *p,unsigned w,unsigned h,size_t n){(void)p;(void)w;(void)h;(void)n;}
static void sample(int16_t a,int16_t b){(void)a;(void)b;}
static size_t audio(const int16_t *p,size_t n){(void)p;return n;}
static void poll(void){}
static int16_t input(unsigned a,unsigned b,unsigned c,unsigned d){(void)a;(void)b;(void)c;(void)d;return 0;}
#define API(name) __typeof__(&name) name##_fn=(__typeof__(&name))dlsym(lib,#name);assert(name##_fn)
int main(int argc,char **argv){
    assert(argc==5);void *lib=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);if(!lib){fprintf(stderr,"%s\n",dlerror());return 2;}
    API(retro_set_environment);API(retro_set_video_refresh);API(retro_set_audio_sample);API(retro_set_audio_sample_batch);API(retro_set_input_poll);API(retro_set_input_state);API(retro_init);API(retro_load_game);API(retro_run);API(retro_get_memory_data);API(retro_get_memory_size);API(retro_unload_game);API(retro_deinit);API(retro_serialize_size);API(retro_serialize);API(retro_unserialize);
    retro_set_environment_fn(env);retro_set_video_refresh_fn(video);retro_set_audio_sample_fn(sample);retro_set_audio_sample_batch_fn(audio);retro_set_input_poll_fn(poll);retro_set_input_state_fn(input);retro_init_fn();
    char path[1024];snprintf(path,sizeof(path),"%s/legal.gba",argv[4]);struct retro_game_info game={path,NULL,0,NULL};assert(retro_load_game_fn(&game));
    assert(retro_get_memory_size_fn(RETRO_MEMORY_SAVE_RAM)==131072);uint8_t *battery=retro_get_memory_data_fn(RETRO_MEMORY_SAVE_RAM);assert(battery);
    uint8_t expected[131072];int exporting=!strcmp(argv[2],"export");
    if(exporting){for(unsigned i=0;i<sizeof(expected);i++)expected[i]=(uint8_t)((i*37u+(i>>8)*11u)^0xa5);}
    else {FILE *f=fopen(argv[3],"rb");assert(f&&fread(expected,1,sizeof(expected),f)==sizeof(expected));assert(fgetc(f)==EOF);fclose(f);}
    memcpy(battery,expected,sizeof(expected));for(unsigned i=0;i<120;i++)retro_run_fn();assert(!memcmp(battery,expected,sizeof(expected)));
    snprintf(path,sizeof(path),"%s/mgba.state",argv[4]);
    if(exporting){
        size_t n=retro_serialize_size_fn();uint8_t *state=malloc(n);assert(state&&retro_serialize_fn(state,n));FILE *f=fopen(path,"wb");assert(f&&fwrite(state,1,n,f)==n);fclose(f);free(state);
        f=fopen(argv[3],"wb");assert(f&&fwrite(battery,1,sizeof(expected),f)==sizeof(expected));fclose(f);
    }else{
        FILE *f=fopen(path,"rb");assert(f);assert(!fseek(f,0,SEEK_END));long n=ftell(f);assert(n>0);rewind(f);uint8_t *state=malloc(n);assert(state&&fread(state,1,n,f)==(size_t)n);fclose(f);
        assert(!retro_unserialize_fn(state,n));assert(!memcmp(battery,expected,sizeof(expected)));free(state);
        puts("PASS: real mGBA 128KiB raw battery imports byte-for-byte into gpSP and survives 120 frames; mGBA save state is rejected without changing battery data");
    }
    retro_unload_game_fn();retro_deinit_fn();dlclose(lib);return 0;
}
