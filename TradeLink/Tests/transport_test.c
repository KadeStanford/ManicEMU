#include "TradeCore.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static uint8_t battery[MT_SAVE_SIZE],state[32];static unsigned delivered,snapshots,flushes,completed,errors;
static void start(unsigned role){assert(role<2);}
static void receive(const void *p,size_t n,unsigned peer){assert(p&&n==24&&peer==1);delivered++;}
static void stop(void){}
static size_t size(void){return sizeof(state);}
static bool save(void *p,size_t n){memcpy(p,state,n);return true;}
static bool load(const void *p,size_t n){memcpy(state,p,n);return true;}
static void snap(const uint8_t *b,const uint8_t *s,size_t n){assert(b[0]==0x45&&s[0]==0x67&&n==32);snapshots++;}
static int persist(const uint8_t *b,const uint8_t *s,size_t n){assert(b[0]==0x99&&s[0]==0xaa&&n==32);flushes++;return 1;}
static void ended(const char *s){if(!strcmp(s,"Link completed"))completed++;}
static void error(const char *s){assert(s);errors++;}
static int fail_save(const uint8_t *b,const uint8_t *s,size_t n){assert(b[0]==0x99&&s[0]==0xaa&&n==32);return 0;}
static void roundtrip(void){uint8_t p[56],ack[56];while(MT_next_packet(0,p)){assert(MT_receive_packet(p,56,ack)>=0);assert(MT_receive_packet(ack,56,p)==2);}}
static MTGBA gba={start,receive,stop,size,save,load,battery,NULL};
int main(void){
    battery[0]=0x45;state[0]=0x67;MT_install(snap,ended,error);MT_set_persist(persist);MT_enable(1);
    assert(MT_game_code((uint8_t *)"BPRE"));assert(!MT_game_code((uint8_t *)"ABCD"));
    assert(MT_compatible((uint8_t *)"BPRE",(uint8_t *)"AXPE"));assert(!MT_compatible((uint8_t *)"BPRE",(uint8_t *)"BPRJ"));
    MT_loaded("/synthetic.gba",(uint8_t *)"BPRE");assert(MT_frame(&gba));MT_request();assert(!MT_frame(&gba));assert(snapshots==1);
    uint8_t session[16]={1},data[24]={ 'M','P','K','1',0,0,0,1 },packet[56],ack[56];
    MT_connect(0,session);assert(MT_frame(&gba));MT_send(0xffff,data,24);assert(MT_pending()==1&&MT_sent()==1);
    assert(MT_next_packet(0,packet));assert(MT_receive_packet(packet,56,ack)==1);assert(MT_receive_packet(packet,56,ack)==0);
    assert(MT_frame(&gba));assert(delivered==1);assert(MT_receive_packet(ack,56,packet)==2);assert(MT_pending()==0);
    for(unsigned n=0;n<56;n++)assert(MT_receive_packet(packet,n,ack)==-1);
    uint8_t old_ready[56]={0};
    for(unsigned i=0;i<3;i++){
        MT_suspend();assert(!MT_frame(&gba));assert(delivered==1);roundtrip();
        if(i){assert(MT_receive_packet(old_ready,56,ack)==0);assert(MT_phase()==MT_SUSPENDED);}
        MT_resume();assert(!MT_frame(&gba)); // One READY alone cannot unfreeze.
        assert(MT_next_packet(0,old_ready));
        MT_resume();roundtrip();assert(MT_frame(&gba));
    }
    MT_send(0xffff,data,24);assert(MT_next_packet(0,packet));packet[23]^=1;assert(MT_receive_packet(packet,56,ack)==-1);packet[23]^=1;
    packet[31]++;assert(MT_receive_packet(packet,56,ack)==-1);packet[31]--;
    assert(MT_receive_packet(packet,56,ack)==1);assert(MT_frame(&gba));assert(delivered==2);
    assert(MT_receive_packet(ack,56,packet)==2);
    // Ordered final serial packet, then CLOSE. No completion callback on the UI thread.
    MT_send(0xffff,data,24);assert(MT_next_packet(0,packet));MT_leave();assert(!MT_complete());
    battery[0]=0x99;state[0]=0xaa;assert(MT_frame(&gba)&&flushes==1&&completed==0);
    MT_restore();MT_resume();assert(MT_phase()==MT_CLOSING); // Ended sessions cannot rewind/rejoin.
    roundtrip();assert(!MT_complete());assert(MT_frame(&gba));assert(MT_complete()&&completed==1&&MT_phase()==MT_IDLE);
    assert(battery[0]==0x99&&state[0]==0xaa);assert(MT_frame(&gba)&&flushes==1&&completed==1);
    MT_ack_packet(ack);assert(MT_receive_packet(ack,56,packet)==2&&MT_peer_disconnected());
    uint64_t old_epoch=MT_epoch();battery[0]=0x45;state[0]=0x67;
    MT_request();assert(!MT_frame(&gba));MT_connect(0,session);assert(MT_frame(&gba));
    assert(MT_epoch()>old_epoch);
    // Both CLOSE fences with a missing final ACK: waive only CLOSE, never DATA.
    MT_send(0xffff,data,24);assert(MT_next_packet(0,packet));assert(MT_receive_packet(packet,56,ack)==1);
    MT_leave();uint64_t final_data=MT_sent()-1;assert(MT_next_packet(final_data,packet));
    uint8_t close_ack[56];assert(MT_receive_packet(packet,56,close_ack)==1);assert(!MT_peer_disconnected());
    assert(MT_receive_packet(ack,56,packet)==2);assert(MT_peer_disconnected());
    battery[0]=0x99;state[0]=0xaa;assert(MT_frame(&gba)&&MT_complete()&&completed==2&&flushes==2);
    battery[0]=0x45;state[0]=0x67;MT_request();assert(!MT_frame(&gba));MT_connect(0,session);assert(MT_frame(&gba));
    battery[0]=0x99;state[0]=0xaa;MT_suspend();MT_restore();assert(MT_frame(&gba));assert(battery[0]==0x45&&state[0]==0x67);
    MT_leave();assert(MT_phase()==MT_IDLE);
    MT_request();assert(!MT_frame(&gba));MT_connect(0,session);assert(MT_frame(&gba));
    for(unsigned i=0;i<MT_QUEUE_SIZE;i++)MT_send(0xffff,data,24);
    MT_send(0xffff,data,24);assert(MT_phase()==MT_BROKEN&&!MT_frame(&gba));MT_resume();assert(MT_phase()==MT_BROKEN);
    MT_restore();assert(MT_frame(&gba)&&MT_phase()==MT_CANCELLED);MT_unloaded();
    // Failed persistence reports a problem, keeps current SRAM/state and normal
    // play, and never substitutes the pre-link battery/checkpoint.
    battery[0]=0x45;state[0]=0x67;MT_loaded("/synthetic.gba",(uint8_t *)"BPRE");
    MT_request();assert(!MT_frame(&gba));MT_connect(0,session);assert(MT_frame(&gba));
    MT_set_persist(fail_save);battery[0]=0x99;state[0]=0xaa;unsigned before=errors;
    MT_leave();roundtrip();assert(MT_frame(&gba)&&MT_phase()==MT_IDLE&&errors==before+1);
    assert(battery[0]==0x99&&state[0]==0xaa);MT_restore();assert(MT_phase()==MT_IDLE);MT_unloaded();
    puts("PASS: Gen3 compatibility, automatic checkpoint, duplicate/replay/session guards, pause/resume, battery + full-state rollback");
}
