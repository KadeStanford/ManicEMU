// Two independent processes run real gpSP cores against a legal synthetic ROM.
#include "TradeCore.h"
#include "common.h"
#include <libretro.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static uint8_t rom[1024*1024];
static bool environment(unsigned cmd,void *data) {
    if(cmd==RETRO_ENVIRONMENT_GET_VARIABLE){struct retro_variable *v=data;v->value=!strcmp(v->key,"gpsp_bios")?"builtin":!strcmp(v->key,"gpsp_boot_mode")?"game":!strcmp(v->key,"gpsp_serial")?"mul_poke":"disabled";return true;}
    if(cmd==RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE){*(bool *)data=false;return true;}
    return cmd==RETRO_ENVIRONMENT_SET_PIXEL_FORMAT||cmd==RETRO_ENVIRONMENT_GET_INPUT_BITMASKS;
}
static void video(const void *p,unsigned w,unsigned h,size_t n){(void)p;(void)n;assert(w==240&&h==160);}
static void sample(int16_t a,int16_t b){(void)a;(void)b;}
static size_t audio(const int16_t *p,size_t n){(void)p;return n;}
static void poll(void){}
static int16_t input(unsigned a,unsigned b,unsigned c,unsigned d){(void)a;(void)b;(void)c;(void)d;return 0;}
static void packet(const char *name,const uint8_t *p){printf("%s ",name);for(unsigned i=0;i<56;i++)printf("%02x",p[i]);puts("");}
static uint64_t cursor;
static const char *save_path;static unsigned flushes;
static int persist(const uint8_t *b,const uint8_t *s,size_t n){
    assert(b&&s&&n>131072);flushes++;if(!save_path)return 1;
    FILE *f=fopen(save_path,"wb");assert(f);assert(fwrite(b,1,MT_SAVE_SIZE,f)==MT_SAVE_SIZE);assert(!fflush(f)&&!fsync(fileno(f))&&!fclose(f));return 1;
}
static void report(void){
    uint8_t p[56];while(MT_next_packet(cursor,p)){cursor=0;for(unsigned i=24;i<32;i++)cursor=(cursor<<8)|p[i];packet("PACKET",p);}
    printf("REG %04x %04x %04x %04x PHASE %d PENDING %zu RX %llu MODE %d SRAM %u FLUSH %u\n",read_ioreg(REG_SIOMULTI0),read_ioreg(REG_SIOMULTI1),read_ioreg(REG_SIOMULTI2),read_ioreg(REG_SIOMULTI3),MT_phase(),MT_pending(),(unsigned long long)MT_received(),MT_mode(),((uint8_t *)retro_get_memory_data(RETRO_MEMORY_SAVE_RAM))[0],flushes);puts("END");fflush(stdout);
}
int main(int argc,char **argv){
    assert(argc==2||argc==3);unsigned role=(unsigned)atoi(argv[1]);assert(role<2);if(argc==3)save_path=argv[2];MT_set_persist(persist);
    memcpy(rom+0xac,"BPRE",4);rom[0xb2]=0x96;uint32_t entry=0xea00002e,loop=0xeafffffe;memcpy(rom,&entry,4);memcpy(rom+0xc0,&loop,4);memcpy(rom+0x200,"FLASH1M_V",9);
    char path[]="/tmp/manic-gba-peer-XXXXXX";int fd=mkstemp(path);assert(fd>=0&&write(fd,rom,sizeof(rom))==sizeof(rom));close(fd);
    MT_enable(1);retro_set_environment(environment);retro_set_video_refresh(video);retro_set_audio_sample(sample);retro_set_audio_sample_batch(audio);retro_set_input_poll(poll);retro_set_input_state(input);retro_init();struct retro_game_info game={path,NULL,0,NULL};assert(retro_load_game(&game));
    uint8_t *battery=retro_get_memory_data(RETRO_MEMORY_SAVE_RAM);battery[0]=0x45;
    if(save_path){FILE *saved=fopen(save_path,"rb");if(saved){assert(fread(battery,1,MT_SAVE_SIZE,saved)==MT_SAVE_SIZE);fclose(saved);}}
    write_ioreg(REG_SIOMLT_SEND,0xb9a0);write_rcnt(0);write_siocnt(0x6083);retro_run();assert(MT_phase()==MT_WAITING);
    uint8_t session[16]={0x5a};MT_connect(role,session);retro_run();assert(MT_phase()==MT_LINKED);report();
    char line[256];while(fgets(line,sizeof(line),stdin)){
        unsigned word,cycles;
        if(!strncmp(line,"packet ",7)){
            uint8_t p[56],ack[56];assert(strlen(line+7)>=112);
            for(unsigned i=0;i<56;i++){unsigned byte;assert(sscanf(line+7+2*i,"%2x",&byte)==1);p[i]=(uint8_t)byte;}
            int accepted=MT_receive_packet(p,56,ack);assert(accepted>=0);if(accepted<2)packet("ACK",ack);MT_poll_receive();
        }else if(sscanf(line,"sio %x",&word)==1){write_siocnt(word);}
        else if(sscanf(line,"rcnt %x",&word)==1){write_rcnt(word);}
        else if(sscanf(line,"frames %u",&cycles)==1){for(unsigned i=0;i<cycles;i++)retro_run();}
        else if(sscanf(line,"idle %u",&cycles)==1){assert(!update_serial(cycles));}
        else if(sscanf(line,"master %x",&word)==1){
            assert(role==0);serial_set_irq_cycles(0);write_ioreg(REG_SIOMLT_SEND,word);write_siocnt(0x6083);assert(serial_get_irq_cycles()==5242);assert(update_serial(5242));
        }else if(sscanf(line,"slave %x %u",&word,&cycles)==2){
            assert(role==1);MT_poll_receive();write_ioreg(REG_SIOMLT_SEND,word);assert(update_serial(cycles));
        }else if(!strncmp(line,"pause",5)){MT_suspend();unsigned before=serial_get_irq_cycles();retro_run();assert(MT_phase()==MT_SUSPENDED&&before==serial_get_irq_cycles());}
        else if(!strncmp(line,"resume",6)){MT_resume();}
        else if(!strncmp(line,"restore",7)){battery[0]=0x99;MT_suspend();MT_restore();retro_run();assert(MT_phase()==MT_CANCELLED&&battery[0]==0x45);}
        else if(!strncmp(line,"leave",5)){write_siocnt(0x2000);assert(MT_phase()==MT_LINKED||MT_phase()==MT_CLOSING);assert(!update_serial(300000));retro_run();}
        else if(!strncmp(line,"stopped",7)){assert(netplay_client_id==0&&netplay_num_clients==0&&serial_get_irq_cycles()==0&&!(read_ioreg(REG_SIOCNT)&0xfc));}
        else if(!strncmp(line,"frame",5)){retro_run();}
        else if(!strncmp(line,"disconnected",12)){printf("EXPECTED %d\n",MT_peer_disconnected());}
        else if(!strncmp(line,"mutate",6)){battery[0]=0x99;}
        else if(!strncmp(line,"checksave",9)){assert(battery[0]==0x99);}
        else if(!strncmp(line,"quit",4))break;
        else if(strncmp(line,"status",6))assert(!"unknown command");
        report();
    }
    retro_unload_game();retro_deinit();unlink(path);return 0;
}
