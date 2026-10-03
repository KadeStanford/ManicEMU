// SPDX-License-Identifier: AGPL-3.0-or-later
#include "TradeCore.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
typedef struct { uint64_t sequence; uint8_t data[MT_DATA_SIZE]; } Message;
static struct {
    enum MTPhase phase;
    int enabled, active, started, captured, leaving, complete;
    unsigned role;
    char path[4096];
    uint8_t code[4], session[16], battery[MT_SAVE_SIZE];
    uint8_t *state;
    size_t state_size;
    MTSnapshot snapshot;
    MTNotice stopped, error;
    MTGBA gba;
    Message out[MT_QUEUE_SIZE], in[MT_QUEUE_SIZE];
    size_t out_head, out_count, in_head, in_count;
    uint64_t tx, rx, acked;
} g;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t read64(const uint8_t *p) { uint64_t v=0; for(unsigned i=0;i<8;i++) v=(v<<8)|p[i]; return v; }
static void write64(uint8_t *p,uint64_t v) { for(int i=7;i>=0;i--){p[i]=v;v>>=8;} }
static void envelope(uint8_t *out,unsigned type,uint64_t seq) {
    memset(out,0,MT_PACKET_SIZE); memcpy(out,"MTR1",4); out[4]=1;out[5]=type;
    memcpy(out+8,g.session,16);write64(out+24,seq);
}
static int valid_data(const uint8_t *data) {
    if(memcmp(data,"MPK1",4))return 0;
    uint32_t flags=(uint32_t)data[4]<<24|(uint32_t)data[5]<<16|(uint32_t)data[6]<<8|data[7];
    return !(flags & 0x7fff0000) && (flags & 0xffff)<=2;
}
static void fault(const char *message) {
    MTNotice fn; pthread_mutex_lock(&lock);g.phase=g.captured?MT_SUSPENDED:MT_CANCELLED;fn=g.error;pthread_mutex_unlock(&lock);
    if(fn)fn(message);
}
void MT_install(MTSnapshot snapshot,MTNotice stopped,MTNotice error) { pthread_mutex_lock(&lock);g.snapshot=snapshot;g.stopped=stopped;g.error=error;pthread_mutex_unlock(&lock); }
void MT_enable(int enabled) { pthread_mutex_lock(&lock);g.enabled=!!enabled;pthread_mutex_unlock(&lock); }
int MT_game_code(const uint8_t code[4]) {
    if(!code||code[3]<'A'||code[3]>'Z')return 0;
    return !memcmp(code,"AXV",3)||!memcmp(code,"AXP",3)||!memcmp(code,"BPR",3)||!memcmp(code,"BPG",3)||!memcmp(code,"BPE",3);
}
int MT_compatible(const uint8_t a[4],const uint8_t b[4]) { return MT_game_code(a)&&MT_game_code(b)&&a[3]==b[3]; }
void MT_loaded(const char *path,const uint8_t code[4]) {
    MT_unloaded();pthread_mutex_lock(&lock);
    if(g.enabled&&path&&strlen(path)<sizeof(g.path)&&MT_game_code(code)) {
        strcpy(g.path,path);memcpy(g.code,code,4);g.active=1;g.phase=MT_IDLE;
    }pthread_mutex_unlock(&lock);
}
void MT_unloaded(void) {
    MTNotice fn;pthread_mutex_lock(&lock);fn=g.active?g.stopped:NULL;
    free(g.state);g.state=NULL;g.state_size=0;g.active=g.started=g.captured=g.leaving=g.complete=0;g.phase=MT_OFF;
    g.out_head=g.out_count=g.in_head=g.in_count=0;g.tx=g.rx=g.acked=0;memset(&g.gba,0,sizeof(g.gba));
    pthread_mutex_unlock(&lock);if(fn)fn("Game closed");
}
const char *MT_path(void) { return g.path; } // Loaded/unloaded only by the core thread.
const uint8_t *MT_code(void) { return g.code; }
int MT_active(void) { int v;pthread_mutex_lock(&lock);v=g.active;pthread_mutex_unlock(&lock);return v; }
enum MTPhase MT_phase(void) { enum MTPhase p;pthread_mutex_lock(&lock);p=g.phase;pthread_mutex_unlock(&lock);return p; }
void MT_request(void) { pthread_mutex_lock(&lock);if(g.active&&g.phase==MT_IDLE)g.phase=MT_WAITING;pthread_mutex_unlock(&lock); }
void MT_leave(void) {
    // Only core-thread callers may release or replace the active checkpoint.
    MTNotice fn=NULL;pthread_mutex_lock(&lock);
    if(g.active&&g.phase==MT_LINKED&&!g.leaving){g.leaving=1;fn=g.stopped;}
    if(g.active&&g.phase==MT_CANCELLED){
        if(g.started&&g.gba.stop)g.gba.stop();g.started=0;g.phase=MT_IDLE;g.captured=0;g.leaving=g.complete=0;
        free(g.state);g.state=NULL;g.state_size=0;
        g.out_head=g.out_count=g.in_head=g.in_count=0;g.tx=g.rx=g.acked=0;fn=g.stopped;
    }pthread_mutex_unlock(&lock);if(fn)fn("Cable session ended");
}
void MT_complete(void) { pthread_mutex_lock(&lock);if(g.leaving&&!g.out_count)g.complete=1;pthread_mutex_unlock(&lock); }
size_t MT_pending(void) { size_t n;pthread_mutex_lock(&lock);n=g.out_count;pthread_mutex_unlock(&lock);return n; }
void MT_connect(unsigned role,const uint8_t session[16]) {
    pthread_mutex_lock(&lock);
    if(g.phase==MT_WAITING&&g.captured&&role<2&&session){g.role=role;memcpy(g.session,session,16);g.phase=MT_LINKED;}
    pthread_mutex_unlock(&lock);
}
void MT_suspend(void) { pthread_mutex_lock(&lock);if(g.phase==MT_LINKED)g.phase=MT_SUSPENDED;pthread_mutex_unlock(&lock); }
void MT_resume(void) { pthread_mutex_lock(&lock);if(g.phase==MT_SUSPENDED&&g.started)g.phase=MT_LINKED;pthread_mutex_unlock(&lock); }
void MT_cancel(void) { pthread_mutex_lock(&lock);if(g.phase==MT_WAITING)g.phase=MT_CANCELLED;pthread_mutex_unlock(&lock); }
void MT_restore(void) { pthread_mutex_lock(&lock);if(g.captured&&(g.phase==MT_SUSPENDED||g.phase==MT_LINKED))g.phase=MT_RESTORE;pthread_mutex_unlock(&lock); }
void MT_poll_receive(void) {
    for(unsigned n=0;n<MT_QUEUE_SIZE;n++){
        Message m;MTGBA gba;unsigned peer;
        pthread_mutex_lock(&lock);
        if(g.phase!=MT_LINKED||!g.started||!g.in_count){pthread_mutex_unlock(&lock);break;}
        m=g.in[g.in_head];g.in_head=(g.in_head+1)%MT_QUEUE_SIZE;g.in_count--;gba=g.gba;peer=1-g.role;
        pthread_mutex_unlock(&lock);if(gba.receive)gba.receive(m.data,MT_DATA_SIZE,peer);
    }
}
int MT_frame(const MTGBA *gba) {
    enum MTPhase phase;int capture=0,start=0,restore=0;unsigned role=0;MTSnapshot fn=NULL;
    pthread_mutex_lock(&lock);g.gba=*gba;phase=g.phase;
    if(g.complete){if(g.started&&gba->stop)gba->stop();g.started=g.captured=g.leaving=g.complete=0;g.phase=phase=MT_IDLE;free(g.state);g.state=NULL;g.state_size=0;g.in_count=0;g.tx=g.rx=g.acked=0;}
    if(phase==MT_WAITING&&!g.captured)capture=1;
    if(phase==MT_LINKED&&!g.started){g.started=1;start=1;role=g.role;}
    if(phase==MT_RESTORE)restore=1;
    pthread_mutex_unlock(&lock);
    if(capture){
        size_t size=gba->state_size();uint8_t *state=size&&size<=4*1024*1024?malloc(size):NULL;
        if(!state||!gba->battery||!gba->save_state(state,size)){free(state);fault("Could not create the automatic pre-trade backup");return 0;}
        pthread_mutex_lock(&lock);g.state=state;g.state_size=size;memcpy(g.battery,gba->battery,MT_SAVE_SIZE);g.captured=1;fn=g.snapshot;pthread_mutex_unlock(&lock);
        if(fn)fn(g.battery,state,size);
    }
    if(restore){
        if(gba->stop)gba->stop();
        if(!gba->load_state(g.state,g.state_size)){fault("Pre-trade checkpoint could not be restored; battery backup is retained");return 0;}
        memcpy(gba->battery,g.battery,MT_SAVE_SIZE);
        pthread_mutex_lock(&lock);g.started=0;g.phase=MT_CANCELLED;g.out_count=g.in_count=0;pthread_mutex_unlock(&lock);return 1;
    }
    if(start&&gba->start)gba->start(role);
    MT_poll_receive();
    return phase!=MT_WAITING&&phase!=MT_SUSPENDED&&phase!=MT_RESTORE;
}
void MT_send(uint16_t recipient,const void *data,size_t size) {
    (void)recipient;
    if(!data||size!=MT_DATA_SIZE||!valid_data(data)){fault("Invalid GBA serial packet");return;}
    int overflow=0;pthread_mutex_lock(&lock);
    if(g.phase==MT_LINKED&&!g.leaving){
        if(g.out_count==MT_QUEUE_SIZE||g.tx==UINT64_MAX)overflow=1;
        else {Message *m=&g.out[(g.out_head+g.out_count)%MT_QUEUE_SIZE];m->sequence=++g.tx;memcpy(m->data,data,size);g.out_count++;}
    }pthread_mutex_unlock(&lock);if(overflow)fault("Connection stalled; games paused and pre-trade backups retained");
}
int MT_next_packet(uint64_t after,uint8_t packet[MT_PACKET_SIZE]) {
    int found=0;pthread_mutex_lock(&lock);
    for(size_t i=0;i<g.out_count;i++){Message *m=&g.out[(g.out_head+i)%MT_QUEUE_SIZE];if(m->sequence>after){envelope(packet,1,m->sequence);memcpy(packet+32,m->data,MT_DATA_SIZE);found=1;break;}}
    pthread_mutex_unlock(&lock);return found;
}
void MT_ack_packet(uint8_t packet[MT_PACKET_SIZE]) { pthread_mutex_lock(&lock);envelope(packet,2,g.rx);pthread_mutex_unlock(&lock); }
int MT_receive_packet(const uint8_t *p,size_t size,uint8_t ack[MT_PACKET_SIZE]) {
    if(!p||size!=MT_PACKET_SIZE||memcmp(p,"MTR1",4)||p[4]!=1||p[6]||p[7]||(p[5]!=1&&p[5]!=2))return -1;
    uint64_t seq=read64(p+24);int result=0;
    pthread_mutex_lock(&lock);
    if(!g.captured||(g.phase!=MT_LINKED&&g.phase!=MT_SUSPENDED)||memcmp(p+8,g.session,16)){pthread_mutex_unlock(&lock);return -1;}
    if(p[5]==2){
        for(unsigned i=32;i<MT_PACKET_SIZE;i++)if(p[i]){pthread_mutex_unlock(&lock);return -1;}
        if(seq>g.tx){pthread_mutex_unlock(&lock);return -1;}
        while(g.out_count&&g.out[g.out_head].sequence<=seq){g.out_head=(g.out_head+1)%MT_QUEUE_SIZE;g.out_count--;}
        if(seq>g.acked)g.acked=seq;
    }else{
        if(!seq||!valid_data(p+32)||seq>g.rx+1||(seq==g.rx+1&&g.in_count==MT_QUEUE_SIZE)){pthread_mutex_unlock(&lock);return -1;}
        if(seq==g.rx+1){Message *m=&g.in[(g.in_head+g.in_count)%MT_QUEUE_SIZE];m->sequence=seq;memcpy(m->data,p+32,MT_DATA_SIZE);g.in_count++;g.rx=seq;result=1;}
        envelope(ack,2,g.rx);
    }pthread_mutex_unlock(&lock);return p[5]==2?2:result;
}
uint64_t MT_received(void){uint64_t v;pthread_mutex_lock(&lock);v=g.rx;pthread_mutex_unlock(&lock);return v;}
uint64_t MT_sent(void){uint64_t v;pthread_mutex_lock(&lock);v=g.tx;pthread_mutex_unlock(&lock);return v;}
