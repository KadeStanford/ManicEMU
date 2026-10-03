#include "TradeCore.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint8_t battery[MT_SAVE_SIZE],state[32];static unsigned delivered,snapshots;
static void start(unsigned role){assert(role<2);}
static void receive(const void *p,size_t n,unsigned peer){assert(p&&n==24&&peer==1);delivered++;}
static void stop(void){}
static size_t size(void){return sizeof(state);}
static bool save(void *p,size_t n){memcpy(p,state,n);return true;}
static bool load(const void *p,size_t n){memcpy(state,p,n);return true;}
static void snap(const uint8_t *b,const uint8_t *s,size_t n){assert(b[0]==0x45&&s[0]==0x67&&n==32);snapshots++;}
static MTGBA gba={start,receive,stop,size,save,load,battery};
int main(void){
    battery[0]=0x45;state[0]=0x67;MT_install(snap,NULL,NULL);MT_enable(1);
    assert(MT_game_code((uint8_t *)"BPRE"));assert(!MT_game_code((uint8_t *)"ABCD"));
    assert(MT_compatible((uint8_t *)"BPRE",(uint8_t *)"AXPE"));assert(!MT_compatible((uint8_t *)"BPRE",(uint8_t *)"BPRJ"));
    MT_loaded("/synthetic.gba",(uint8_t *)"BPRE");assert(MT_frame(&gba));MT_request();assert(!MT_frame(&gba));assert(snapshots==1);
    uint8_t session[16]={1},data[24]={ 'M','P','K','1',0,0,0,1 },packet[56],ack[56];
    MT_connect(0,session);assert(MT_frame(&gba));MT_send(0xffff,data,24);assert(MT_pending()==1&&MT_sent()==1);
    assert(MT_next_packet(0,packet));assert(MT_receive_packet(packet,56,ack)==1);assert(MT_receive_packet(packet,56,ack)==0);
    assert(MT_frame(&gba));assert(delivered==1);assert(MT_receive_packet(ack,56,packet)==2);assert(MT_pending()==0);
    for(unsigned n=0;n<56;n++)assert(MT_receive_packet(packet,n,ack)==-1);
    MT_suspend();assert(!MT_frame(&gba));assert(delivered==1);MT_resume();assert(MT_frame(&gba));
    MT_send(0xffff,data,24);assert(MT_next_packet(0,packet));packet[23]^=1;assert(MT_receive_packet(packet,56,ack)==-1);packet[23]^=1;
    packet[31]++;assert(MT_receive_packet(packet,56,ack)==-1);packet[31]--;
    assert(MT_receive_packet(packet,56,ack)==1);assert(MT_frame(&gba));assert(delivered==2);
    assert(MT_receive_packet(ack,56,packet)==2);
    // End only after the last acknowledged packet executes on the core thread.
    MT_send(0xffff,data,24);assert(MT_next_packet(0,packet));MT_leave();assert(!MT_complete());
    assert(MT_receive_packet(packet,56,ack)==1);assert(MT_receive_packet(ack,56,packet)==2);assert(!MT_complete());
    assert(MT_frame(&gba)&&delivered==3);assert(MT_complete());assert(MT_frame(&gba)&&MT_phase()==MT_IDLE);
    MT_request();assert(!MT_frame(&gba));MT_connect(0,session);assert(MT_frame(&gba));
    battery[0]=0x99;state[0]=0xaa;MT_suspend();MT_restore();assert(MT_frame(&gba));assert(battery[0]==0x45&&state[0]==0x67);
    MT_leave();assert(MT_phase()==MT_IDLE);
    MT_request();assert(!MT_frame(&gba));MT_connect(0,session);assert(MT_frame(&gba));
    for(unsigned i=0;i<MT_QUEUE_SIZE;i++)MT_send(0xffff,data,24);
    MT_send(0xffff,data,24);assert(MT_phase()==MT_BROKEN&&!MT_frame(&gba));MT_resume();assert(MT_phase()==MT_BROKEN);
    MT_restore();assert(MT_frame(&gba)&&MT_phase()==MT_CANCELLED);MT_unloaded();
    puts("PASS: Gen3 compatibility, automatic checkpoint, duplicate/replay/session guards, pause/resume, battery + full-state rollback");
}
