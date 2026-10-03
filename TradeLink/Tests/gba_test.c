// Legal synthetic GBA cartridge. No Nintendo logo, official BIOS, or game data.
#include "TradeCore.h"
#include "common.h"
#include <libretro.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static uint8_t rom[1024*1024];static unsigned videos,audios,backups;
static bool environment(unsigned command,void *data){
    switch(command){
    case RETRO_ENVIRONMENT_GET_VARIABLE:{struct retro_variable *v=data;v->value=!strcmp(v->key,"gpsp_bios")?"builtin":!strcmp(v->key,"gpsp_boot_mode")?"game":!strcmp(v->key,"gpsp_serial")?"mul_poke":"disabled";return true;}
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:*(bool *)data=false;return true;
    default:return false;
    }
}
static void video(const void *p,unsigned w,unsigned h,size_t pitch){(void)p;(void)pitch;assert(w==240&&h==160);videos++;}
static size_t audio(const int16_t *p,size_t frames){(void)p;audios++;return frames;}
static void sample(int16_t l,int16_t r){(void)l;(void)r;}
static void poll(void){}
static int16_t input(unsigned p,unsigned d,unsigned i,unsigned b){(void)p;(void)d;(void)i;(void)b;return 0;}
static void checkpoint(const uint8_t *b,const uint8_t *s,size_t n){assert(b&&s&&n>131072);backups++;}
int main(void){
    memcpy(rom+0xac,"BPRE",4);memcpy(rom+0xa0,"LEGAL LINK",10);rom[0xb2]=0x96;
    // Entry branches over the header to an ARM infinite loop.
    uint32_t entry=0xea00002e,loop=0xeafffffe;memcpy(rom,&entry,4);memcpy(rom+0xc0,&loop,4);
    memcpy(rom+0x200,"FLASH1M_V",9);
    char path[]="/tmp/manic-gba-test-XXXXXX";int fd=mkstemp(path);assert(fd>=0);assert(write(fd,rom,sizeof(rom))==sizeof(rom));close(fd);
    MT_install(checkpoint,NULL,NULL);MT_enable(1);
    retro_set_environment(environment);retro_set_video_refresh(video);retro_set_audio_sample(sample);retro_set_audio_sample_batch(audio);retro_set_input_poll(poll);retro_set_input_state(input);retro_init();
    struct retro_game_info game={path,NULL,0,NULL};assert(retro_load_game(&game));assert(MT_active());
    for(int i=0;i<10;i++)retro_run();assert(videos&&audios);
    // Trigger the exact Gen3 cable token through the running engine's IO API.
    write_ioreg(REG_SIOMLT_SEND,0xb9a0);write_rcnt(0);write_siocnt(0x6083);
    assert(MT_phase()==MT_WAITING);unsigned irq=serial_get_irq_cycles();assert(irq>0);assert(!update_serial(irq));assert(serial_get_irq_cycles()==irq);
    retro_run();assert(backups==1);unsigned before=videos;retro_run();assert(videos==before+1&&MT_phase()==MT_WAITING);
    uint8_t session[16]={9};MT_connect(0,session);retro_run();assert(netplay_client_id==0&&netplay_num_clients==1);
    uint8_t packet[56];assert(MT_next_packet(0,packet));assert(!memcmp(packet+32,"MPK1",4));
    size_t state_size=retro_serialize_size();void *state=malloc(state_size);assert(state&&retro_serialize(state,state_size));
    assert(!retro_unserialize(state,state_size));free(state); // No one-sided rewind in a live link.
    // Master timing at 115200: 2621 clocks per player, two players.
    serial_set_irq_cycles(0);write_ioreg(REG_SIOMLT_SEND,0xb9a0);write_siocnt(0x6083);assert(serial_get_irq_cycles()==5242);
    assert(!update_serial(5241));assert(update_serial(1));assert(!(read_ioreg(REG_SIOCNT)&0x80));
    MT_suspend();unsigned cyc=serial_get_irq_cycles();retro_run();assert(serial_get_irq_cycles()==cyc);
    MT_resume();assert(MT_phase()==MT_SUSPENDED); // Requires the other phone's READY.
    MT_restore();retro_run();assert(MT_phase()==MT_CANCELLED);
    retro_unload_game();retro_deinit();unlink(path);
    puts("PASS: real gpSP core boots legal GBA program, preserves video/audio, detects Gen3 serial activity, captures checkpoint, blocks pairing clocks, sets link role, and executes multiplayer serial timing/IRQ + recovery");
}
