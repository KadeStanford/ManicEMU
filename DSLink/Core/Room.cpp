// SPDX-License-Identifier: AGPL-3.0-or-later
#include "Room.hpp"
#include <algorithm>
#include <cstring>
namespace manicds {
MAC Room::address(Nonce n){return MAC{2,n[0],n[1],n[2],n[3],n[4]};}
Room::Room(Nonce n,const char code[4],uint8_t r,MAC native):identity_(n),revision_(r),native_(native),alias_(title(code)>=6?native:address(n)){
    if(code)std::memcpy(code_.data(),code,4);
}
bool Room::add(Nonce n,const char code[4],uint8_t revision,MAC alias){
    if(n==identity_||contains(n)||peers_.size()>=MaxPeers||nextSlot_==65535||
       !compatible(code_.data(),code)||alias==alias_||
       (title(code_.data())<6&&(alias!=address(n)||alias==native_)))return false;
    if(title(code_.data())>=6){
        bool nonzero=false;for(auto b:alias)nonzero|=b!=0;
        if(!nonzero||(alias[0]&1))return false;
    }
    for(const auto &p:peers_)if(p.second.alias==alias)return false;
    auto protocol=std::make_unique<Protocol>(identity_,code_.data(),revision_);
    protocol->radio(radio_);if(!protocol->bind(n,code,revision))return false;
    protocol->hold(held_);peers_.emplace(n,Edge{std::move(protocol),alias,nextSlot_++});return true;
}
void Room::remove(Nonce n){peers_.erase(n);}
uint16_t Room::slot(Nonce n)const{auto p=peers_.find(n);return p==peers_.end()?65535:p->second.slot;}
void Room::translate(Bytes &p,bool outgoing)const{
    // Gen 5 includes its console identity throughout Nintendo's application
    // protocol. Keep every native byte intact; generated consoles receive a
    // stable distinct identity before boot instead of rewriting game data.
    if(title(code_.data())>=6)return;
    if(p.size()<46||p.size()>MaxPacket)return;
    unsigned type=((p[22]|(unsigned(p[23])<<8))>>2)&3;if(type!=0&&type!=2)return;
    const auto &from=outgoing?native_:alias_,&to=outgoing?alias_:native_;
    for(size_t offset:{size_t(26),size_t(32),size_t(38)})
        if(std::equal(from.begin(),from.end(),p.begin()+offset))std::copy(to.begin(),to.end(),p.begin()+offset);
}
bool Room::receive(Nonce n,const void *data,size_t size){
    auto p=peers_.find(n);if(p==peers_.end())return false;
    bool ok=p->second.protocol->receive(data,size);
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
bool Room::pop(Received &packet){
    if(!radio_||held_)return false;
    // Round robin prevents a busy battle from starving other room beacons.
    for(unsigned pass=0;pass<2;pass++)for(auto &p:peers_){
        if((pass==0&&p.second.slot<=cursor_)||(pass==1&&p.second.slot>cursor_))continue;
        if(p.second.protocol->pop(packet)){cursor_=p.second.slot;packet.source=p.second.slot;translate(packet.data,false);return true;}}
    return false;
}
std::vector<Bytes> Room::takeWire(Nonce n){auto p=peers_.find(n);return p==peers_.end()?std::vector<Bytes>{}:p->second.protocol->takeWire();}
void Room::radio(bool on){radio_=on;for(auto &p:peers_)p.second.protocol->radio(on);}
void Room::hold(bool on){held_=on;for(auto &p:peers_)p.second.protocol->hold(on);}
bool Room::hasIncoming()const{for(const auto &p:peers_)if(p.second.protocol->hasIncoming())return true;return false;}
bool Room::active()const{for(const auto &p:peers_)if(p.second.protocol->paired())return true;return false;}
uint64_t Room::sentCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->sentCount();return v;}
uint64_t Room::receivedCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->receivedCount();return v;}
uint64_t Room::acknowledged()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->acknowledged();return v;}
uint64_t Room::rejectedCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->rejectedCount();return v;}
uint64_t Room::duplicateCount()const{uint64_t v=0;for(const auto &p:peers_)v+=p.second.protocol->duplicateCount();return v;}
size_t Room::pendingCount()const{size_t v=0;for(const auto &p:peers_)v+=p.second.protocol->pendingCount();return v;}
}
