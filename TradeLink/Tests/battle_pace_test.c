#include "TradeCore.h"
#include "AudioPace.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
static uint8_t battery[MT_SAVE_SIZE],state[32];static unsigned wakes;
static void start(unsigned role){assert(role<2);}static void receive(const void *p,size_t n,unsigned peer){assert(p&&n==24&&peer==1);}static void stop(void){}
static size_t size(void){return sizeof(state);}static bool save(void *p,size_t n){memcpy(p,state,n);return true;}static bool load(const void *p,size_t n){memcpy(state,p,n);return true;}
static MTGBA gba={start,receive,stop,size,save,load,battery,NULL};
static void wake(void){assert(MT_phase()==MT_LINKED);wakes++;} // Re-enters the core: callback must hold no mutex.
static void relay(void){uint8_t p[56],ack[56];while(MT_next_packet(0,p)){assert(MT_receive_packet(p,56,ack)>=0);assert(MT_receive_packet(ack,56,p)==2);}MT_poll_receive();}
static void command(unsigned cmd,unsigned arg){uint8_t p[24]={'M','P','K','1',0x80,0,0,2};p[8]=cmd>>8;p[9]=cmd;p[10]=arg>>8;p[11]=arg;MT_send(0xffff,p,24);}
static void audio(void){
    MTAudioPace pace={0};int16_t data[]={-32768,32767,-32768,32767,100,-100,300,-300,5,-5};
    int16_t original[10];memcpy(original,data,sizeof(data));
    assert(MT_audio_pace(&pace,data,5,1)==5&&!memcmp(original,data,sizeof(data)));
    assert(MT_audio_pace(&pace,data,5,2)==2&&pace.pending);
    assert(data[0]==-32768&&data[1]==32767&&data[2]==200&&data[3]==-200);
    int16_t next[]={9,-9};assert(MT_audio_pace(&pace,next,1,2)==1&&!pace.pending&&next[0]==7&&next[1]==-7);
    size_t frames=0;for(unsigned i=0;i<99;i++){int16_t odd[]={1,2,3,4,5,6};frames+=MT_audio_pace(&pace,odd,3,2);}
    assert(frames==148&&pace.pending); // 297 input frames, never a rounding-growth audio backlog.
    int16_t normal[]={-1,1};assert(MT_audio_pace(&pace,normal,1,1)==1&&!pace.pending&&normal[0]==-1&&normal[1]==1);
}
int main(void){
    audio();MT_enable(1);MT_set_battle_wake(wake);MT_loaded("/legal.gba",(const uint8_t *)"BPRE");
    assert(MT_battle_budget()==1&&!MT_battle_accelerated());MT_request();assert(!MT_frame(&gba)&&MT_battle_budget()==0);
    uint8_t session[16]={3};MT_connect(0,session);assert(MT_frame(&gba));MT_serial_state(1);relay();
    for(unsigned kind=0;kind<4;kind++){const unsigned types[]={0x1111,0x1122,0x2233,0x2244};command(0x2222,types[kind]);relay();assert(MT_battle_budget()==1&&!MT_battle_transport()&&!MT_battle_accelerated()&&!wakes);}
    command(0x2222,0x2211);assert(!MT_battle_transport()&&MT_battle_budget()==1);relay();assert(MT_battle_transport());
    assert(MT_battle_budget()==1);uint8_t p[56],ack[56];assert(MT_next_packet(0,p)&&p[5]==10);
    p[47]=3;assert(MT_receive_packet(p,56,ack)==-1);p[47]=2;
    assert(MT_receive_packet(p,56,ack)==1&&!MT_battle_accelerated()); // Peer offer alone is insufficient.
    assert(MT_receive_packet(ack,56,p)==2&&MT_battle_accelerated()&&MT_battle_budget()==2);
    for(unsigned i=0;i<4;i++)MT_battle_did_frame();assert(MT_battle_budget()==0);
    relay();assert(MT_battle_budget()==2);uint64_t local,peer;MT_battle_clocks(&local,&peer);assert(local==peer&&local==4);
    MT_frontend_hold(1);relay();assert(MT_phase()==MT_HELD&&MT_battle_budget()==0&&!MT_battle_accelerated());
    MT_battle_did_frame();MT_battle_clocks(&local,&peer);assert(local==4);
    MT_frontend_hold(0);relay();assert(MT_phase()==MT_LINKED&&MT_battle_budget()==2);
    MT_suspend();relay();assert(MT_battle_budget()==0&&!MT_battle_accelerated());
    MT_frontend_hold(0);relay();assert(MT_phase()==MT_SUSPENDED);MT_resume();relay();assert(MT_battle_budget()==2);
    MT_battle_did_frame(); // An older progress control remains pending during a legitimate game close.
    command(0x5fff,0);assert(!MT_battle_accelerated()&&MT_battle_budget()==1);relay();assert(MT_phase()==MT_LINKED);
    MT_serial_state(0);relay();assert(MT_battle_budget()==1&&!MT_battle_accelerated());
    MT_serial_state(1);relay();command(0x2222,0x2211);relay();assert(MT_battle_budget()==1);relay();assert(MT_battle_budget()==2);
    command(0x2222,0x1111);relay();assert(MT_battle_budget()==1&&!MT_battle_accelerated());
    MT_unloaded();assert(MT_battle_budget()==1&&!MT_battle_accelerated());
    puts("PASS: bilateral 2x capability + own ACK, battle-only/type/hardware/hold/loss/close gates, four-frame credit, in-flight old progress on exit, fresh agreement on reopen, exact stereo audio pacing");
}
