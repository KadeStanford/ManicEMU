// SPDX-License-Identifier: AGPL-3.0-or-later
#include "Room.hpp"
#include <algorithm>
#include <cstring>
#include <limits>
namespace manicds {
MAC Room::address(Nonce n){return MAC{2,n[0],n[1],n[2],n[3],n[4]};}
Room::Room(Nonce n,const char code[4],uint8_t r,MAC native):identity_(n),revision_(r),alias_(native){
    if(code)std::memcpy(code_.data(),code,4);
}
bool Room::add(Nonce n,const char code[4],uint8_t revision,MAC alias){
    if(n==identity_||contains(n)||peers_.size()>=MaxPeers||nextSlot_==65535||
       !compatible(code_.data(),code)||alias==alias_)return false;
    {
        bool nonzero=false;for(auto b:alias)nonzero|=b!=0;
        if(!nonzero||(alias[0]&1))return false;
    }
    for(const auto &p:peers_)if(p.second.alias==alias)return false;
    if(nextEpoch_==std::numeric_limits<uint64_t>::max())return false;
    auto protocol=std::make_unique<Protocol>(identity_,code_.data(),revision_,nextEpoch_++);
    protocol->radio(radio_);if(!protocol->bind(n,code,revision))return false;
    protocol->hold(held_);preserveEpoch(*protocol);
    Edge edge{std::move(protocol),std::make_unique<NativeRadioEdge>(identity_,n),{}, {},alias,nextSlot_++};
    syncRadio(edge);peers_.emplace(n,std::move(edge));return true;
}
void Room::preserveEpoch(const Protocol &protocol){
    const auto epoch=protocol.localRadioEpoch();
    if(epoch>=nextEpoch_)nextEpoch_=epoch==std::numeric_limits<uint64_t>::max()?epoch:epoch+1;
}
void Room::syncRadio(Edge &edge){
    const auto &p=*edge.protocol;
    edge.radio->localRadio(p.localRadioEpoch(),p.localRadioOn()&&!p.localHeld());
    if(p.peerRadioEpoch())edge.radio->peerRadio(p.peerRadioEpoch(),p.peerRadioOn()&&!p.peerHeld());
    edge.fragments.expire();
    if(!edge.radio->active()||p.phase()==Phase::Failed||p.phase()==Phase::Ended||p.phase()==Phase::Interrupted){
        edge.radio->discardIncoming();edge.fragments.reset();edge.radioWire.clear();
    }
}
void Room::remove(Nonce n){auto p=peers_.find(n);if(p!=peers_.end())preserveEpoch(*p->second.protocol);peers_.erase(n);}
uint16_t Room::slot(Nonce n)const{auto p=peers_.find(n);return p==peers_.end()?65535:p->second.slot;}
void Room::translate(Bytes &p,bool outgoing)const{
    // Independent virtual hardware identities are established before boot.
    // Headers and checksummed Nintendo application identities must agree in
    // both generations, including real firmware and restored game caches.
    (void)p;(void)outgoing;
}
bool Room::receive(Nonce n,const void *data,size_t size){
    auto p=peers_.find(n);if(p==peers_.end())return false;
    bool ok=p->second.protocol->receive(data,size);
    syncRadio(p->second);
    if(!radio_){Received discarded;while(p->second.protocol->pop(discarded)){} }
    return ok;
}
bool Room::send(const void *data,size_t size,uint16_t target){
    if(!radio_||held_||!validPacket(data,size))return false;
    Bytes packet(static_cast<const uint8_t*>(data),static_cast<const uint8_t*>(data)+size);translate(packet,true);
    bool sent=false;
    for(auto &p:peers_){if(target!=65535&&target!=p.second.slot)continue;
        if(p.second.protocol->paired())sent=p.second.protocol->send(packet.data(),packet.size())||sent;}
    return sent;
}
bool Room::sendRadio(const void *data,size_t size,uint16_t target){
    if(!radio_||held_||!validPacket(data,size))return false;
    bool sent=false;
    for(auto &p:peers_){auto &edge=p.second;if(target!=65535&&target!=edge.slot)continue;
        syncRadio(edge);
        const size_t count=(size+RadioFragments::Chunk-1)/RadioFragments::Chunk;
        if(!edge.protocol->paired()||edge.protocol->paused()||edge.radioWire.size()+count>MaxQueue)continue;
        auto packet=edge.radio->encode(data,size);if(packet.empty())continue;
        auto fragments=RadioFragments::split(packet);
        if(fragments.empty()||edge.radioWire.size()+fragments.size()>MaxQueue)continue;
        for(auto &fragment:fragments)edge.radioWire.push_back(std::move(fragment));sent=true;
    }return sent;
}
bool Room::receiveRadio(Nonce n,const void *data,size_t size){
    auto p=peers_.find(n);if(p==peers_.end()||!radio_||held_)return false;
    auto &edge=p->second;syncRadio(edge);
    if(!edge.protocol->paired()||edge.protocol->paused())return false;
    if(!edge.fragments.receive(data,size,*edge.radio))return false;
    Bytes packet;bool accepted=false;
    while(edge.fragments.pop(packet))accepted=edge.radio->receive(packet.data(),packet.size())||accepted;
    // A valid incomplete fragment is accepted by the carrier, but no partial
    // packet is delivered to melonDS. Native retransmission remains authoritative.
    return accepted||edge.fragments.queuedIncomplete()>0;
}
bool Room::pop(Received &packet){
    if(!radio_||held_)return false;
    // Round robin prevents a busy battle from starving other room beacons.
    for(unsigned pass=0;pass<2;pass++)for(auto &p:peers_){
        if((pass==0&&p.second.slot<=cursor_)||(pass==1&&p.second.slot>cursor_))continue;
        if(p.second.protocol->pop(packet)){cursor_=p.second.slot;packet.source=p.second.slot;translate(packet.data,false);return true;}
        if(p.second.protocol->paired()&&!p.second.protocol->paused()&&p.second.radio->pop(packet.data)){cursor_=p.second.slot;packet.source=p.second.slot;return true;}}
    return false;
}
std::vector<Bytes> Room::takeWire(Nonce n){auto p=peers_.find(n);return p==peers_.end()?std::vector<Bytes>{}:p->second.protocol->takeWire();}
std::vector<Bytes> Room::takeRadioWire(Nonce n){auto p=peers_.find(n);if(p==peers_.end())return {};auto result=std::move(p->second.radioWire);p->second.radioWire.clear();return result;}
void Room::radio(bool on){radio_=on;for(auto &p:peers_){p.second.protocol->radio(on);preserveEpoch(*p.second.protocol);syncRadio(p.second);}}
void Room::hold(bool on){held_=on;for(auto &p:peers_){p.second.protocol->hold(on);preserveEpoch(*p.second.protocol);syncRadio(p.second);}}
bool Room::hasIncoming()const{if(!radio_||held_)return false;for(const auto &p:peers_)if(p.second.protocol->paired()&&!p.second.protocol->paused()&&(p.second.protocol->hasIncoming()||p.second.radio->queued()))return true;return false;}
bool Room::active()const{for(const auto &p:peers_)if(p.second.protocol->paired())return true;return false;}
uint64_t Room::sentCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->sentCount();return v;}
uint64_t Room::receivedCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->receivedCount();return v;}
uint64_t Room::acknowledged()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->acknowledged();return v;}
uint64_t Room::rejectedCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->rejectedCount();return v;}
uint64_t Room::duplicateCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->duplicateCount();return v;}
size_t Room::pendingCount()const{size_t v=0;for(const auto &p:peers_)v+=p.second.protocol->pendingCount();return v;}
uint64_t Room::radioSentCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.radio->sent();return v;}
uint64_t Room::radioReceivedCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.radio->received();return v;}
uint64_t Room::radioDroppedCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.radio->dropped();return v;}
uint64_t Room::fragmentDroppedCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.fragments.dropped();return v;}
}
