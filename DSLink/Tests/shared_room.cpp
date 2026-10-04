// SPDX-License-Identifier: AGPL-3.0-or-later
#include "Room.hpp"
#include "Batch.hpp"
#include <iostream>
#include <stdexcept>
#include <algorithm>
using namespace manicds;
static unsigned checks=0;
static void check(bool b){if(!b)throw std::runtime_error("shared room regression");++checks;}
static Nonce nonce(unsigned n){Nonce v{};v[0]=uint8_t(n);v[15]=uint8_t(n+1);return v;}
static void pump(std::vector<Room*> &rooms){for(unsigned pass=0;pass<8;pass++)for(size_t a=0;a<rooms.size();a++)for(size_t b=0;b<rooms.size();b++){
    if(a==b)continue;for(const auto &wire:rooms[a]->takeWire(nonce(unsigned(b))))check(rooms[b]->receive(nonce(unsigned(a)),wire.data(),wire.size()));}}
int main(){
    MAC native{0,9,191,17,34,51};std::vector<std::unique_ptr<Room>> owned;std::vector<Room*> rooms;
    for(unsigned n=0;n<8;n++){owned.push_back(std::make_unique<Room>(nonce(n),n%2?"IRAO":"IRBO",uint8_t(0),native));rooms.push_back(owned.back().get());rooms.back()->radio(true);}
    for(unsigned a=0;a<8;a++)for(unsigned b=0;b<8;b++)if(a!=b)check(rooms[a]->add(nonce(b),b%2?"IRAO":"IRBO",0,Room::address(nonce(b))));
    pump(rooms);for(auto *r:rooms)check(r->active()&&r->size()==7&&r->pendingCount()==0);
    // Shared default firmware identities retain unique stable header aliases.
    Bytes beacon(100,0);beacon[22]=0x80;std::copy(native.begin(),native.end(),beacon.begin()+32);std::copy(native.begin(),native.end(),beacon.begin()+38);std::copy(native.begin(),native.end(),beacon.begin()+70);
    check(rooms[0]->send(beacon.data(),beacon.size()));pump(rooms);Received received;
    for(unsigned n=1;n<8;n++){check(rooms[n]->pop(received));
        MAC alias=rooms[0]->alias();check(std::equal(alias.begin(),alias.end(),received.data.begin()+32));check(std::equal(beacon.begin()+44,beacon.end(),received.data.begin()+44));}
    check(std::equal(native.begin(),native.end(),beacon.begin()+32));
    // Native client source IDs are local stable slots, independent of pair order.
    auto oldSlot=rooms[0]->slot(nonce(1));rooms[0]->remove(nonce(7));rooms[7]->remove(nonce(0));check(rooms[0]->slot(nonce(1))==oldSlot);
    check(rooms[0]->add(nonce(7),"IRAO",0,Room::address(nonce(7))));check(rooms[7]->add(nonce(0),"IRBO",0,Room::address(nonce(0))));pump(rooms);check(rooms[0]->slot(nonce(7))!=oldSlot);
    // Two unrelated addressed exchanges neither broadcast nor import saves.
    for(unsigned a:{0u,2u}){Bytes data=beacon;data[70]=uint8_t(a+40);check(rooms[a]->send(data.data(),data.size(),rooms[a]->slot(nonce(a+1))));}
    pump(rooms);for(unsigned n=0;n<8;n++){bool present=rooms[n]->pop(received);check(present==(n==1||n==3));if(present)check(received.data[70]==uint8_t(n+39));}
    // Radio off/reentry and a held bystander leave unrelated members running.
    rooms[7]->hold(true);pump(rooms);check(!rooms[0]->paused());rooms[6]->radio(false);pump(rooms);
    for(unsigned i=0;i<300;i++){check(rooms[0]->send(beacon.data(),beacon.size(),rooms[0]->slot(nonce(6))));pump(rooms);}check(!rooms[6]->hasIncoming());
    rooms[6]->radio(true);rooms[7]->hold(false);pump(rooms);check(rooms[0]->send(beacon.data(),beacon.size(),rooms[0]->slot(nonce(6))));pump(rooms);check(rooms[6]->pop(received));
    check(!rooms[0]->add(nonce(9),"IPKE",0,Room::address(nonce(9))));
    std::cout<<"{\"synthetic_shared_room_checks\":"<<checks<<",\"independent_consoles\":8,\"physical_verified\":false}"<<std::endl;
}
