// SPDX-License-Identifier: AGPL-3.0-or-later
#include "TradeCore.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

enum { DATA=1, ACK=2, CLOSE=3, PAUSE=4, READY=5, SERIAL=6, QUIET=7, HOLD=8, RELEASE=9 };
typedef struct { uint64_t sequence; unsigned type; uint8_t data[MT_DATA_SIZE]; } Message;
static struct {
    enum MTPhase phase;
    enum MTMode mode;
    int enabled, active, started, captured, leaving, remote_left, stopped_core, persisted, completed;
    int local_ready, remote_ready;
    int serial_on, peer_serial_on, close_sent, close_received;
    int idle_ready, peer_idle_ready;
    int room_exit_sent, room_exit_received;
    int local_hold, remote_hold;
    uint64_t hold_generation, peer_hold_generation, hold_release_sequence;
    unsigned link_type;
    unsigned quiet;
    uint64_t frames, serial_generation, peer_serial_generation, diagnostic_revision;
    char diagnostics[128][176];
    size_t diagnostic_head, diagnostic_count;
    unsigned role;
    char path[4096];
    uint8_t code[4], session[16], battery[MT_SAVE_SIZE];
    uint8_t *state;
    size_t state_size;
    MTSnapshot snapshot;
    MTPersist persist;
    MTNotice stopped, error;
    MTGBA gba;
    Message out[MT_QUEUE_SIZE], in[MT_QUEUE_SIZE];
    size_t out_head, out_count, in_head, in_count;
    uint64_t tx, rx, acked, epoch, round;
} g;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static void diagnostic(const char *event,unsigned detail) { // Caller holds lock.
    size_t slot=(g.diagnostic_head+g.diagnostic_count)%128;
    if(g.diagnostic_count==128){slot=g.diagnostic_head;g.diagnostic_head=(g.diagnostic_head+1)%128;}
    else g.diagnostic_count++;
    snprintf(g.diagnostics[slot],176,"%llu frame=%llu event=%s detail=%04x phase=%d serial=%d/%d close=%d/%d quiet=%u tx=%llu rx=%llu pending=%zu\n",
        (unsigned long long)++g.diagnostic_revision,(unsigned long long)g.frames,event,detail,g.phase,g.serial_on,g.peer_serial_on,g.close_sent,g.close_received,g.quiet,
        (unsigned long long)g.tx,(unsigned long long)g.rx,g.out_count);
}
size_t MT_diagnostics(char *buffer,size_t capacity,uint64_t *revision) {
    size_t used=0;pthread_mutex_lock(&lock);if(revision)*revision=g.diagnostic_revision;
    if(buffer&&capacity){
        int n=snprintf(buffer,capacity,"Manic GBA link v0.6; game=%.4s; epoch=%llu; metadata only\n",g.code,(unsigned long long)g.epoch);
        used=n>0?(size_t)n:0;if(used>=capacity)used=capacity-1;
        for(size_t i=0;i<g.diagnostic_count;i++){
            const char *line=g.diagnostics[(g.diagnostic_head+i)%128];size_t size=strlen(line);
            if(size>=capacity-used)break;memcpy(buffer+used,line,size);used+=size;
        }buffer[used]=0;
    }pthread_mutex_unlock(&lock);return used;
}
void MT_serial_registers(uint16_t siocnt,uint16_t rcnt) {
    pthread_mutex_lock(&lock);diagnostic("registers-sio-rcnt",(unsigned)siocnt<<16|rcnt);pthread_mutex_unlock(&lock);
}
static uint64_t read64(const uint8_t *p) { uint64_t v=0; for(unsigned i=0;i<8;i++)v=(v<<8)|p[i];return v; }
static void write64(uint8_t *p,uint64_t v) { for(int i=7;i>=0;i--){p[i]=v;v>>=8;} }
static void envelope(uint8_t *out,unsigned type,uint64_t seq) {
    memset(out,0,MT_PACKET_SIZE);memcpy(out,"MTR1",4);out[4]=5;out[5]=type;
    memcpy(out+8,g.session,16);write64(out+24,seq);
}
static int valid_data(const uint8_t *p) {
    if(memcmp(p,"MPK1",4))return 0;
    uint32_t flags=(uint32_t)p[4]<<24|(uint32_t)p[5]<<16|(uint32_t)p[6]<<8|p[7];
    return !(flags&0x7fff0000)&&(flags&0xffff)<=2;
}
static void clear_session(void) {
    free(g.state);g.state=NULL;g.state_size=0;
    g.started=g.captured=g.leaving=g.remote_left=g.stopped_core=g.persisted=g.completed=0;
    g.out_head=g.out_count=g.in_head=g.in_count=0;g.tx=g.rx=g.acked=g.round=0;
    g.local_ready=g.remote_ready=0;g.mode=MT_MODE_UNKNOWN;
    g.peer_serial_on=1;g.close_sent=g.close_received=0;g.quiet=0;
    g.idle_ready=g.peer_idle_ready=0;
    g.room_exit_sent=g.room_exit_received=0;g.link_type=0;
    g.local_hold=g.remote_hold=0;g.hold_generation=g.peer_hold_generation=g.hold_release_sequence=0;
    g.serial_generation=g.peer_serial_generation=0;
}
static int queue(unsigned type,const void *data) { // Caller holds lock; controls share the serial sequence.
    if(g.out_count==MT_QUEUE_SIZE||g.tx==UINT64_MAX)return 0;
    Message *m=&g.out[(g.out_head+g.out_count)%MT_QUEUE_SIZE];m->sequence=++g.tx;m->type=type;
    memset(m->data,0,sizeof(m->data));if(data)memcpy(m->data,data,MT_DATA_SIZE);g.out_count++;return 1;
}
static void fault(const char *message) {
    MTNotice fn;pthread_mutex_lock(&lock);g.phase=g.captured?MT_BROKEN:MT_CANCELLED;diagnostic("fault",0);fn=g.error;pthread_mutex_unlock(&lock);if(fn)fn(message);
}
void MT_failure(const char *message) { fault(message); }
void MT_install(MTSnapshot snapshot,MTNotice stopped,MTNotice error) { pthread_mutex_lock(&lock);g.snapshot=snapshot;g.stopped=stopped;g.error=error;pthread_mutex_unlock(&lock); }
void MT_set_persist(MTPersist persist) { pthread_mutex_lock(&lock);g.persist=persist;pthread_mutex_unlock(&lock); }
void MT_enable(int enabled) { pthread_mutex_lock(&lock);g.enabled=!!enabled;pthread_mutex_unlock(&lock); }
int MT_game_code(const uint8_t code[4]) {
    if(!code||code[3]<'A'||code[3]>'Z')return 0;
    return !memcmp(code,"AXV",3)||!memcmp(code,"AXP",3)||!memcmp(code,"BPR",3)||!memcmp(code,"BPG",3)||!memcmp(code,"BPE",3);
}
int MT_compatible(const uint8_t a[4],const uint8_t b[4]) { return MT_game_code(a)&&MT_game_code(b)&&a[3]==b[3]; }
void MT_loaded(const char *path,const uint8_t code[4]) {
    MT_unloaded();pthread_mutex_lock(&lock);
    if(g.enabled&&path&&strlen(path)<sizeof(g.path)&&MT_game_code(code)){strcpy(g.path,path);memcpy(g.code,code,4);g.active=1;g.phase=MT_IDLE;}
    pthread_mutex_unlock(&lock);
}
void MT_unloaded(void) {
    MTNotice fn;pthread_mutex_lock(&lock);fn=g.active?g.stopped:NULL;g.epoch++;
    diagnostic("unload",0);clear_session();g.active=0;g.phase=MT_OFF;g.serial_on=0;memset(&g.gba,0,sizeof(g.gba));pthread_mutex_unlock(&lock);if(fn)fn("Game closed");
}
const char *MT_path(void) { return g.path; }
const uint8_t *MT_code(void) { return g.code; }
int MT_active(void) { int v;pthread_mutex_lock(&lock);v=g.active;pthread_mutex_unlock(&lock);return v; }
enum MTPhase MT_phase(void) { enum MTPhase p;pthread_mutex_lock(&lock);p=g.phase;pthread_mutex_unlock(&lock);return p; }
uint64_t MT_epoch(void) { uint64_t v;pthread_mutex_lock(&lock);v=g.epoch;pthread_mutex_unlock(&lock);return v; }
enum MTMode MT_mode(void) { enum MTMode v;pthread_mutex_lock(&lock);v=g.mode;pthread_mutex_unlock(&lock);return v; }
void MT_request(void) { pthread_mutex_lock(&lock);if(g.active&&g.phase==MT_IDLE){clear_session();g.epoch++;g.phase=MT_WAITING;diagnostic("request",0);}pthread_mutex_unlock(&lock); }
void MT_serial_state(int enabled) {
    int ok=1;enabled=!!enabled;pthread_mutex_lock(&lock);
    if(g.serial_on!=enabled){
        g.serial_on=enabled;g.quiet=0;g.idle_ready=g.peer_idle_ready=0;
        if(enabled){g.close_sent=g.close_received=0;g.room_exit_sent=g.room_exit_received=0;}
        diagnostic(enabled?"serial-on":"serial-off",0);
        if(g.active&&(g.phase==MT_LINKED||g.phase==MT_SUSPENDED||g.phase==MT_HELD)&&!g.leaving){
            uint8_t data[24]={0};data[0]=(uint8_t)enabled;write64(data+8,++g.serial_generation);ok=queue(SERIAL,data);
        }
    }pthread_mutex_unlock(&lock);if(!ok)fault("Cable state queue overflow; current save and backups retained");
    if(!enabled&&MT_phase()==MT_CANCELLED)MT_leave();
}
void MT_leave(void) { // Core-thread hardware DisableSerial, never a UI/network disconnect.
    int ok=1;MTNotice fn=NULL;pthread_mutex_lock(&lock);
    if(g.active&&(g.phase==MT_LINKED||g.phase==MT_CLOSING)&&!g.leaving){g.leaving=1;g.phase=MT_CLOSING;ok=queue(CLOSE,NULL);diagnostic("final-close",0);}
    else if(g.active&&g.phase==MT_CANCELLED){if(g.started&&g.gba.stop)g.gba.stop();clear_session();g.phase=MT_IDLE;fn=g.stopped;}
    pthread_mutex_unlock(&lock);if(!ok)fault("Link close queue overflow; current save and backups are retained");if(fn)fn("Link cancelled");
}
int MT_finishing(void) { int v;pthread_mutex_lock(&lock);v=g.leaving||g.remote_left;pthread_mutex_unlock(&lock);return v; }
static int terminal_locked(void) {
    if(g.completed)return 1;
    if(g.phase!=MT_LINKED&&g.phase!=MT_SUSPENDED&&g.phase!=MT_CLOSING&&g.phase!=MT_HELD)return 0;
    if(g.serial_on||!g.room_exit_sent||!g.room_exit_received)return 0;
    // Never turn a transport loss with unacknowledged serial DATA into success.
    for(size_t i=0;i<g.out_count;i++)if(g.out[(g.out_head+i)%MT_QUEUE_SIZE].type==DATA)return 0;
    return 1;
}
static int quiet_close_allowed(void) { // FR/LG's known subconnections return to the room; they are not exits.
    if(!memcmp(g.code,"BPR",3)||!memcmp(g.code,"BPG",3))
        return g.link_type!=0x1122&&g.link_type!=0x1133&&g.link_type!=0x1144&&g.link_type!=0x2211;
    return 1;
}
int MT_terminal_exit(void) { int v;pthread_mutex_lock(&lock);v=terminal_locked();pthread_mutex_unlock(&lock);return v; }
int MT_local_closed(void) { int v;pthread_mutex_lock(&lock);v=g.leaving;pthread_mutex_unlock(&lock);return v; }
int MT_complete(void) { int v;pthread_mutex_lock(&lock);v=g.completed;pthread_mutex_unlock(&lock);return v; }
int MT_peer_disconnected(void) {
    int expected=0;pthread_mutex_lock(&lock);
    if(g.completed)expected=1;
    else if(g.leaving&&g.remote_left){
        expected=1;for(size_t i=0;i<g.out_count;i++)if(g.out[(g.out_head+i)%MT_QUEUE_SIZE].type!=CLOSE)expected=0;
        // Both ordered fences received: only a final close ACK may be waived.
        if(expected)g.out_count=0;
    }else if(terminal_locked()&&!g.in_count){
        // Both games already agreed to leave the room and this game applied
        // CloseLink. No further game data is required, only transport controls.
        g.leaving=g.remote_left=1;g.phase=MT_CLOSING;g.out_count=0;expected=1;diagnostic("room-exit-disconnect",0);
    }pthread_mutex_unlock(&lock);return expected;
}
size_t MT_pending(void) { size_t n;pthread_mutex_lock(&lock);n=g.out_count;pthread_mutex_unlock(&lock);return n; }
void MT_connect(unsigned role,const uint8_t session[16]) {
    pthread_mutex_lock(&lock);if(g.phase==MT_WAITING&&g.captured&&role<2&&session){g.role=role;memcpy(g.session,session,16);g.phase=MT_LINKED;diagnostic("pair",role);}pthread_mutex_unlock(&lock);
}
static void suspend_locked(uint64_t round) { g.round=round;g.local_ready=g.remote_ready=0;g.quiet=0;g.idle_ready=g.peer_idle_ready=0;g.phase=MT_SUSPENDED;diagnostic("pause",0); }
static enum MTPhase hold_phase_locked(void) { return g.local_hold||g.remote_hold||g.hold_release_sequence>g.acked?MT_HELD:MT_LINKED; }
void MT_frontend_hold(int held) {
    int ok=1;held=!!held;pthread_mutex_lock(&lock);
    if((g.phase==MT_LINKED||g.phase==MT_HELD||(!held&&g.phase==MT_SUSPENDED))&&!g.leaving&&!g.remote_left&&!terminal_locked()&&g.local_hold!=held){
        uint8_t data[24]={0};g.local_hold=held;write64(data,++g.hold_generation);ok=queue(held?HOLD:RELEASE,data);
        if(!held)g.hold_release_sequence=g.tx;
        if(g.phase!=MT_SUSPENDED)g.phase=hold_phase_locked();
        g.quiet=0;g.idle_ready=g.peer_idle_ready=0;diagnostic(held?"frontend-hold":"frontend-release",0);
    }pthread_mutex_unlock(&lock);if(!ok)fault("Frontend hold queue overflow; backups retained");
}
void MT_suspend(void) {
    int ok=1;pthread_mutex_lock(&lock);
    if((g.phase==MT_LINKED||g.phase==MT_HELD)&&!g.leaving&&!g.remote_left&&!terminal_locked()){uint8_t data[24]={0};suspend_locked(g.round+1);write64(data,g.round);ok=queue(PAUSE,data);}
    pthread_mutex_unlock(&lock);if(!ok)fault("Link pause queue overflow; backups retained");
}
void MT_resume(void) {
    int ok=1;pthread_mutex_lock(&lock);
    if(g.phase==MT_SUSPENDED&&g.started&&!g.local_ready){uint8_t data[24]={0};g.local_ready=1;write64(data,g.round);ok=queue(READY,data);if(g.remote_ready)g.phase=hold_phase_locked();}
    pthread_mutex_unlock(&lock);if(!ok)fault("Link resume queue overflow; backups retained");
}
void MT_cancel(void) { pthread_mutex_lock(&lock);if(g.phase==MT_WAITING)g.phase=MT_CANCELLED;pthread_mutex_unlock(&lock); }
void MT_restore(void) { pthread_mutex_lock(&lock);if(g.captured&&!g.leaving&&(g.phase==MT_SUSPENDED||g.phase==MT_LINKED||g.phase==MT_BROKEN))g.phase=MT_RESTORE;pthread_mutex_unlock(&lock); }
void MT_poll_receive(void) {
    for(unsigned n=0;n<MT_QUEUE_SIZE;n++){
        Message m;MTGBA gba;unsigned peer;int deliver;pthread_mutex_lock(&lock);
        if((g.phase!=MT_LINKED&&g.phase!=MT_CLOSING&&!((g.phase==MT_SUSPENDED||g.phase==MT_HELD)&&terminal_locked()))||!g.started||!g.in_count){pthread_mutex_unlock(&lock);break;}
        if(!g.leaving&&g.gba.receive_capacity&&!g.gba.receive_capacity(1-g.role)){pthread_mutex_unlock(&lock);break;}
        m=g.in[g.in_head];g.in_head=(g.in_head+1)%MT_QUEUE_SIZE;g.in_count--;gba=g.gba;peer=1-g.role;deliver=!g.leaving;
        pthread_mutex_unlock(&lock);if(deliver&&gba.receive)gba.receive(m.data,MT_DATA_SIZE,peer);
    }
}
int MT_frame(const MTGBA *gba) {
    enum MTPhase phase;int capture=0,start=0,restore=0,persist=0,stop=0,finish=0;unsigned role=0;
    MTSnapshot fn=NULL;MTPersist writer=NULL;MTNotice notice=NULL;
    pthread_mutex_lock(&lock);g.gba=*gba;phase=g.phase;g.frames++;
    if((phase==MT_SUSPENDED||phase==MT_HELD)&&terminal_locked()&&!g.peer_serial_on&&!g.in_count){g.phase=phase=MT_LINKED;diagnostic("terminal-unsuspend",0);}
    // FireRed/LeafGreen room termination sends CAFE/17 from each player, then
    // directly closes hardware, without 5FFF. This is explicit terminal intent,
    // distinct from menu/animation/battle handoffs; no quiet timer is needed.
    if((phase==MT_LINKED||phase==MT_CLOSING)&&g.started&&!g.leaving&&terminal_locked()&&!g.peer_serial_on&&!g.out_count&&!g.in_count){
        g.leaving=1;g.phase=phase=MT_CLOSING;if(!queue(CLOSE,NULL)){pthread_mutex_unlock(&lock);fault("Room exit close queue overflow");return 0;}diagnostic("room-exit-close",0);
    }
    // Gen3 closes/reopens for room -> menu, menu -> animation, animation ->
    // menu, and battle entry/return. A toggle (even with 5FFF) is not an exit.
    // Keep the existing transport/backup until both ordered hardware-idle
    // notifications and close commands are retained and the stream is quiet.
    if((phase==MT_LINKED||phase==MT_CLOSING)&&g.started&&!g.leaving&&quiet_close_allowed()&&!g.serial_on&&!g.peer_serial_on&&g.close_sent&&g.close_received&&!g.out_count&&!g.in_count){
        if(!g.quiet)diagnostic("quiet-start",0);
        if(g.quiet<MT_CLOSE_QUIET_FRAMES)g.quiet++;
        if(g.quiet>=MT_CLOSE_QUIET_FRAMES&&!g.idle_ready){
            uint8_t data[24]={0};write64(data,g.serial_generation);g.idle_ready=1;
            if(!queue(QUIET,data)){pthread_mutex_unlock(&lock);fault("Link idle queue overflow");return 0;}diagnostic("quiet-ready",0);
        }
        if(g.idle_ready&&g.peer_idle_ready&&!g.out_count){g.leaving=1;g.phase=phase=MT_CLOSING;if(!queue(CLOSE,NULL)){pthread_mutex_unlock(&lock);fault("Link close queue overflow");return 0;}diagnostic("final-close",0);}
    }else g.quiet=0;
    if(phase==MT_WAITING&&!g.captured)capture=1;
    if(phase==MT_LINKED&&!g.started){g.started=1;start=1;role=g.role;}
    if(g.leaving&&!g.stopped_core){g.stopped_core=1;stop=1;}
    if(g.leaving&&!g.persisted){g.persisted=1;persist=1;writer=g.persist;}
    if(phase==MT_RESTORE)restore=1;pthread_mutex_unlock(&lock);
    if(capture){
        size_t size=gba->state_size();uint8_t *state=size&&size<=4*1024*1024?malloc(size):NULL;
        if(!state||!gba->battery||!gba->save_state(state,size)){free(state);fault("Could not create the automatic pre-link backup");return 0;}
        pthread_mutex_lock(&lock);g.state=state;g.state_size=size;memcpy(g.battery,gba->battery,MT_SAVE_SIZE);g.captured=1;fn=g.snapshot;pthread_mutex_unlock(&lock);if(fn)fn(g.battery,state,size);
    }
    if(restore){
        if(gba->stop)gba->stop();if(!gba->load_state(g.state,g.state_size)){fault("Pre-link checkpoint could not be restored; battery backup is retained");return 0;}
        memcpy(gba->battery,g.battery,MT_SAVE_SIZE);pthread_mutex_lock(&lock);g.started=0;g.phase=MT_CANCELLED;g.out_count=g.in_count=0;MTNotice restored=g.stopped;pthread_mutex_unlock(&lock);
        if(restored)restored("Pre-trade checkpoint restored");return 1;
    }
    if(start&&gba->start)gba->start(role);if(stop&&gba->stop)gba->stop();
    if(persist&&writer){
        size_t size=gba->state_size();uint8_t *state=size&&size<=4*1024*1024?malloc(size):NULL;
        int saved=state&&gba->battery&&gba->save_state(state,size)&&writer(gba->battery,state,size);free(state);
        pthread_mutex_lock(&lock);diagnostic(saved?"save-written":"save-failed",0);pthread_mutex_unlock(&lock);
        if(!saved){pthread_mutex_lock(&lock);notice=g.error;pthread_mutex_unlock(&lock);if(notice)notice("The link ended, but disk saving failed. Keep this game open and export its current save; nothing was restored.");}
    }
    MT_poll_receive();pthread_mutex_lock(&lock);
    if(g.phase==MT_CLOSING&&g.leaving&&g.remote_left&&!g.out_count&&!g.in_count&&g.stopped_core&&g.persisted){
        // Keep identity/rx tombstone until next request to ACK late duplicates.
        g.completed=1;g.phase=MT_IDLE;g.started=0;free(g.state);g.state=NULL;g.state_size=0;notice=g.stopped;finish=1;diagnostic("complete",0);
    }phase=g.phase;pthread_mutex_unlock(&lock);if(finish&&notice)notice("Link completed");
    return phase!=MT_WAITING&&phase!=MT_SUSPENDED&&phase!=MT_HELD&&phase!=MT_RESTORE&&phase!=MT_BROKEN;
}
static int classify(const uint8_t *p,int outgoing) { // Metadata only; party/block payloads remain opaque.
    if(!(p[4]&0x80))return 1;
    unsigned cmd=(unsigned)p[8]<<8|p[9];
    unsigned arg=(unsigned)p[10]<<8|p[11];
    if(cmd==0xcafe&&arg==0x17&&(!memcmp(g.code,"BPR",3)||!memcmp(g.code,"BPG",3))&&
        (g.link_type==0x1111||g.link_type==0x2233||g.link_type==0x2244)){
        if(outgoing)g.room_exit_sent=1;else g.room_exit_received=1;diagnostic(outgoing?"room-exit-key-tx":"room-exit-key-rx",arg);
    }
    if(cmd==0x5fff){if(outgoing)g.close_sent=1;else g.close_received=1;diagnostic(outgoing?"close-command-tx":"close-command-rx",(unsigned)p[10]<<8|p[11]);}
    if(cmd!=0x2222)return 1;
    unsigned type=(unsigned)p[10]<<8|p[11];
    g.link_type=type;
    diagnostic(outgoing?"link-type-tx":"link-type-rx",type);
    switch(type){case 0x1111:case 0x1122:case 0x1133:case 0x1144:g.mode=MT_MODE_TRADE;break;
    case 0x2211:if(g.mode!=MT_MODE_DOUBLE_BATTLE)g.mode=MT_MODE_SINGLE_BATTLE;break;
    case 0x2233:g.mode=MT_MODE_SINGLE_BATTLE;break;
    case 0x2244:g.mode=MT_MODE_DOUBLE_BATTLE;break;
    case 0x2255:return 0; // Four-player Multi Battle is outside the two-phone transport.
    default:break;}return 1;
}
void MT_send(uint16_t recipient,const void *data,size_t size) {
    (void)recipient;if(!data||size!=MT_DATA_SIZE||!valid_data(data)){fault("Invalid GBA serial packet");return;}
    int ok=1,supported=1;pthread_mutex_lock(&lock);
    if((g.phase==MT_LINKED||g.phase==MT_HELD||g.phase==MT_CLOSING)&&!g.leaving){supported=classify(data,1);if(supported)ok=queue(DATA,data);g.quiet=0;g.idle_ready=g.peer_idle_ready=0;}
    pthread_mutex_unlock(&lock);
    if(!supported)fault("Four-player Multi Battle requires four consoles. Use Single or Double Battle with two phones.");
    else if(!ok)fault("Connection stalled; games paused and pre-link backups retained");
}
int MT_next_packet(uint64_t after,uint8_t packet[MT_PACKET_SIZE]) {
    int found=0;pthread_mutex_lock(&lock);
    for(size_t i=0;i<g.out_count;i++){Message *m=&g.out[(g.out_head+i)%MT_QUEUE_SIZE];if(m->sequence>after){envelope(packet,m->type,m->sequence);memcpy(packet+32,m->data,MT_DATA_SIZE);found=1;break;}}
    pthread_mutex_unlock(&lock);return found;
}
void MT_ack_packet(uint8_t packet[MT_PACKET_SIZE]) { pthread_mutex_lock(&lock);envelope(packet,ACK,g.rx);pthread_mutex_unlock(&lock); }
int MT_receive_packet(const uint8_t *p,size_t size,uint8_t ack[MT_PACKET_SIZE]) {
    if(!p||size!=MT_PACKET_SIZE||memcmp(p,"MTR1",4)||p[4]!=5||p[6]||p[7]||p[5]<DATA||p[5]>RELEASE)return -1;
    uint64_t seq=read64(p+24);unsigned type=p[5];int result=0,supported=1;
    if(type==DATA&&!valid_data(p+32))return -1;
    if(type==SERIAL){if(p[32]>1||!read64(p+40))return -1;for(unsigned i=33;i<56;i++)if((i<40||i>=48)&&p[i])return -1;}
    else if(type!=DATA){unsigned begin=(type==PAUSE||type==READY||type==QUIET||type==HOLD||type==RELEASE)?40:32;for(unsigned i=begin;i<MT_PACKET_SIZE;i++)if(p[i])return -1;if((type==HOLD||type==RELEASE)&&!read64(p+32))return -1;}
    pthread_mutex_lock(&lock);
    if(!g.captured||memcmp(p+8,g.session,16)){pthread_mutex_unlock(&lock);return -1;}
    if(g.completed){if(seq>(type==ACK?g.tx:g.rx)){pthread_mutex_unlock(&lock);return -1;}envelope(ack,ACK,g.rx);pthread_mutex_unlock(&lock);return type==ACK?2:0;}
    if(g.phase!=MT_LINKED&&g.phase!=MT_SUSPENDED&&g.phase!=MT_CLOSING&&g.phase!=MT_HELD){pthread_mutex_unlock(&lock);return -1;}
    if(type==ACK){
        if(seq>g.tx){pthread_mutex_unlock(&lock);return -1;}
        while(g.out_count&&g.out[g.out_head].sequence<=seq){g.out_head=(g.out_head+1)%MT_QUEUE_SIZE;g.out_count--;}
        if(seq>g.acked)g.acked=seq;
        if(g.phase==MT_HELD)g.phase=hold_phase_locked();
    }else{
        if(!seq||seq>g.rx+1||(seq==g.rx+1&&type==DATA&&g.in_count==MT_QUEUE_SIZE)){pthread_mutex_unlock(&lock);return -1;}
        if(seq==g.rx+1){
            if(type==DATA){supported=classify(p+32,0);g.quiet=0;g.idle_ready=g.peer_idle_ready=0;Message *m=&g.in[(g.in_head+g.in_count)%MT_QUEUE_SIZE];m->sequence=seq;m->type=DATA;memcpy(m->data,p+32,MT_DATA_SIZE);g.in_count++;}
            else if(type==CLOSE){g.remote_left=1;g.phase=MT_CLOSING;}
            else if(type==SERIAL){uint64_t generation=read64(p+40);if(generation<=g.peer_serial_generation){pthread_mutex_unlock(&lock);return -1;}
                g.peer_serial_generation=generation;g.peer_serial_on=p[32];g.quiet=0;g.idle_ready=g.peer_idle_ready=0;if(g.peer_serial_on){g.close_sent=g.close_received=0;g.room_exit_sent=g.room_exit_received=0;}diagnostic("peer-serial",p[32]);}
            else if(type==QUIET){
                // A faster phone cannot finalize while the slower game is still
                // preparing to reopen. Readiness belongs to this OFF generation.
                if(!g.peer_serial_on&&read64(p+32)==g.peer_serial_generation)g.peer_idle_ready=1;
                diagnostic("peer-quiet",0);
            }
            else if((type==HOLD||type==RELEASE)&&!g.leaving&&!g.remote_left){
                uint64_t generation=read64(p+32);if(generation<=g.peer_hold_generation){pthread_mutex_unlock(&lock);return -1;}
                g.peer_hold_generation=generation;g.remote_hold=type==HOLD;g.quiet=0;g.idle_ready=g.peer_idle_ready=0;
                if(g.phase!=MT_SUSPENDED&&g.phase!=MT_CLOSING)g.phase=hold_phase_locked();diagnostic(type==HOLD?"peer-hold":"peer-release",0);
            }
            else if(!g.leaving&&!g.remote_left){uint64_t round=read64(p+32);if(!round){pthread_mutex_unlock(&lock);return -1;}
                if(type==PAUSE&&round>g.round&&!terminal_locked())suspend_locked(round);
                else if(type==READY&&round==g.round&&g.phase==MT_SUSPENDED){g.remote_ready=1;if(g.local_ready)g.phase=hold_phase_locked();}
            }g.rx=seq;result=1;
        }envelope(ack,ACK,g.rx);
    }pthread_mutex_unlock(&lock);
    if(!supported)fault("Four-player Multi Battle is unsupported; use Single or Double Battle with two phones.");return type==ACK?2:result;
}
uint64_t MT_received(void){uint64_t v;pthread_mutex_lock(&lock);v=g.rx;pthread_mutex_unlock(&lock);return v;}
uint64_t MT_sent(void){uint64_t v;pthread_mutex_lock(&lock);v=g.tx;pthread_mutex_unlock(&lock);return v;}
