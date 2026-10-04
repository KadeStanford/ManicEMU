// SPDX-License-Identifier: AGPL-3.0-or-later
// Production room/control/RF integration; synthetic bytes, no private inputs.
#include "Room.hpp"
#include <cstdio>
#include <cstdlib>
using namespace manicds;
static unsigned checks=0;
static void check(bool value){++checks;if(!value){std::fprintf(stderr,"room RF check %u failed\n",checks);std::exit(1);}}
static Nonce nonce(unsigned id){Nonce n{};n[0]=uint8_t(id);return n;}
static MAC mac(unsigned id){return MAC{0,9,191,1,2,uint8_t(id)};}
static Bytes payload(size_t size){Bytes p(size);for(size_t i=0;i<size;++i)p[i]=uint8_t(i*13+71);p[8]=0;p[9]=size==10?1:0;return p;}
static void controls(Room &a,Nonce an,Room &b,Nonce bn){
    for(unsigned i=0;i<20;++i){auto ab=a.takeWire(bn),ba=b.takeWire(an);if(ab.empty()&&ba.empty())return;
        for(const auto &f:ab)check(b.receive(an,f.data(),f.size()));
        for(const auto &f:ba)check(a.receive(bn,f.data(),f.size()));
    }check(false);
}
struct Pair{
    Nonce an=nonce(1),bn=nonce(2);Room a,b;
    Pair(const char *ac="IPKE",const char *bc="IPGE"):a(an,ac,0,mac(1)),b(bn,bc,0,mac(2)){
        a.radio(true);b.radio(true);check(a.add(bn,bc,0,mac(2)));check(b.add(an,ac,0,mac(1)));controls(a,an,b,bn);
        check(a.active()&&b.active()&&a.pendingCount()==0&&b.pendingCount()==0);
    }
    std::vector<Bytes> encode(const Bytes &p){check(a.sendRadio(p.data(),p.size(),a.slot(bn)));return a.takeRadioWire(bn);}
    void deliver(const std::vector<Bytes> &frames){for(const auto &f:frames)check(b.receiveRadio(an,f.data(),f.size()));}
};
int main(){
    // Every admitted title pairing traverses the same actual RF carrier.
    const char *titles[]={"ADAE","APAE","CPUE","IPKE","IPGE","IRBO","IRAO","IREO","IRDO"};
    unsigned pairings=0;const auto small=payload(10),normal=payload(100),maximum=payload(MaxPacket);
    for(const auto *a:titles)for(const auto *b:titles)if(compatible(a,b)){
        Pair pair(a,b);auto frames=pair.encode(normal);pair.deliver(frames);Received p;
        check(pair.b.pop(p)&&p.data==normal&&p.source==pair.b.slot(pair.an));
        check(pair.a.pendingCount()==0&&pair.a.sentCount()==1);++pairings;
    }check(pairings==41);
    Pair pair;Received received;
    auto fragmented=pair.encode(maximum);check(fragmented.size()==3);
    check(pair.b.receiveRadio(pair.an,fragmented[0].data(),fragmented[0].size()));
    check(!pair.b.hasIncoming()&&!pair.b.pop(received));
    // A lost RF fragment cannot hold up a later complete RF packet or controls.
    auto later=pair.encode(normal);pair.deliver(later);check(pair.b.pop(received)&&received.data==normal);
    pair.a.hold(true);controls(pair.a,pair.an,pair.b,pair.bn);
    check(pair.a.pendingCount()==0&&!pair.a.sendRadio(normal.data(),normal.size()));
    pair.a.hold(false);controls(pair.a,pair.an,pair.b,pair.bn);
    check(pair.a.pendingCount()==0&&!pair.b.receiveRadio(pair.an,fragmented[1].data(),fragmented[1].size()));
    auto fresh=pair.encode(maximum);std::reverse(fresh.begin(),fresh.end());pair.deliver(fresh);
    check(pair.b.pop(received)&&received.data==maximum);
    for(const auto &f:fresh)pair.b.receiveRadio(pair.an,f.data(),f.size());
    check(!pair.b.pop(received)); // Duplicate completed RF never reaches the game twice.
    // Native exit/reentry changes both epoch fences without reconnect prompts.
    for(unsigned session=0;session<12;++session){
        auto stale=pair.encode(small);pair.a.radio(false);pair.b.radio(false);controls(pair.a,pair.an,pair.b,pair.bn);
        check(!pair.a.hasIncoming()&&!pair.b.hasIncoming());
        pair.a.radio(true);controls(pair.a,pair.an,pair.b,pair.bn);
        check(!pair.a.sendRadio(small.data(),small.size()));
        pair.b.radio(true);controls(pair.a,pair.an,pair.b,pair.bn);
        for(const auto &f:stale)check(!pair.b.receiveRadio(pair.an,f.data(),f.size()));
        auto current=pair.encode(normal);pair.deliver(current);check(pair.b.pop(received)&&received.data==normal);
        check(pair.a.pendingCount()==0&&pair.b.pendingCount()==0);
    }
    // Reattaching the same consoles/nonces still rejects a previous RF session.
    auto old=pair.encode(normal);const auto oldSlot=pair.a.slot(pair.bn);
    pair.a.remove(pair.bn);pair.b.remove(pair.an);
    check(pair.a.add(pair.bn,"IPGE",0,mac(2))&&pair.b.add(pair.an,"IPKE",0,mac(1)));
    controls(pair.a,pair.an,pair.b,pair.bn);check(pair.a.slot(pair.bn)!=oldSlot);
    for(const auto &f:old)check(!pair.b.receiveRadio(pair.an,f.data(),f.size()));
    auto current=pair.encode(normal);pair.deliver(current);check(pair.b.pop(received)&&received.data==normal);
    // Outbound queue stays bounded; rejection doesn't poison reliable controls.
    for(unsigned i=0;i<MaxQueue/3;++i)check(pair.a.sendRadio(maximum.data(),maximum.size()));
    check(!pair.a.sendRadio(maximum.data(),maximum.size())&&pair.a.active()&&pair.a.pendingCount()==0);
    check(pair.a.takeRadioWire(pair.bn).size()==(MaxQueue/3)*3);
    check(pair.a.sendRadio(normal.data(),normal.size()));pair.a.takeRadioWire(pair.bn);
    // A failed reliable fence clears queued RF and cannot create a busy wait.
    current=pair.encode(normal);pair.deliver(current);check(pair.b.hasIncoming());
    check(pair.a.send(normal.data(),normal.size()));auto reliable=pair.a.takeWire(pair.bn);
    check(reliable.size()==1);reliable[0][51]+=1;check(!pair.b.receive(pair.an,reliable[0].data(),reliable[0].size()));
    check(!pair.b.hasIncoming()&&!pair.b.pop(received));
    // Full eight-console carrier with independent source slots and directed RF.
    const Nonce hubNonce=nonce(10);Room hub(hubNonce,"IRBO",0,mac(10));hub.radio(true);
    std::vector<std::unique_ptr<Room>> guests;
    for(unsigned i=0;i<7;++i){const auto n=nonce(i+20);guests.push_back(std::make_unique<Room>(n,"IRAO",uint8_t(0),mac(i+20)));auto &guest=*guests.back();guest.radio(true);
        check(hub.add(n,"IRAO",0,mac(i+20))&&guest.add(hubNonce,"IRBO",0,mac(10)));controls(hub,hubNonce,guest,n);}
    check(hub.sendRadio(normal.data(),normal.size()));
    for(unsigned i=0;i<7;++i){const auto n=nonce(i+20);auto &guest=*guests[i];
        for(const auto &f:hub.takeRadioWire(n))check(guest.receiveRadio(hubNonce,f.data(),f.size()));
        check(guest.pop(received)&&received.data==normal&&received.source==guest.slot(hubNonce));
        auto p=normal;p[10]=uint8_t(i);check(guest.sendRadio(p.data(),p.size(),guest.slot(hubNonce)));
        for(const auto &f:guest.takeRadioWire(hubNonce))check(hub.receiveRadio(n,f.data(),f.size()));
    }
    unsigned mask=0;for(unsigned i=0;i<7;++i){check(hub.pop(received));const auto index=received.data[10];check(index<7&&received.source==hub.slot(nonce(index+20)));mask|=1u<<index;}
    check(mask==127&&!hub.hasIncoming()&&hub.pendingCount()==0&&hub.radioSentCount()==7);
    std::printf("{\"checks\":%u,\"admitted_title_pairings\":%u,\"production_room_carrier\":true,\"private_inputs\":false,\"physical_phone_verified\":false}\n",checks,pairings);
}
