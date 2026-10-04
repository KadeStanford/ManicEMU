// SPDX-License-Identifier: AGPL-3.0-or-later
#include "NintendoIdentity.hpp"
#include "Room.hpp"
#include <iostream>
#include <stdexcept>
using namespace manicds;
static unsigned checks=0;
static void check(bool value){if(!value)throw std::runtime_error("Gen 5 beacon identity regression");++checks;}
static void put(Bytes &p,size_t at,uint16_t v){p[at]=uint8_t(v);p[at+1]=uint8_t(v>>8);}
static void address(Bytes &p,size_t at,MAC m){std::copy(m.begin(),m.end(),p.begin()+at);}
static Bytes beacon(MAC m,size_t prefix=0){
    Bytes p(200+prefix,0);p[22]=0x80;
    if(prefix){p[58]=0;p[59]=uint8_t(prefix-2);}
    size_t tag=58+prefix,base=tag+2,body=base+26;
    p[tag]=0xdd;p[tag+1]=136;const uint8_t oui[]{0,9,191,0,10,0};std::copy_n(oui,6,p.begin()+base);
    put(p,base+8,1);put(p,base+10,1);put(p,base+12,0x1380);p[base+18]=112;p[base+19]=1;
    put(p,body,0x1380);put(p,body+2,0x14);
    address(p,body+46,m);address(p,body+70,m); // MAC-shaped non-address data stays intact
    put(p,base+24,beaconCRC(p.data()+body,110));return p;
}
int main(){
    MAC native{0,9,191,17,34,51},alias{2,1,2,3,4,5},other{2,8,7,6,5,4};
    for(size_t prefix:{size_t(0),size_t(34)})for(unsigned subtype:{0x80u,0x50u}){
        Bytes original=beacon(native,prefix);original[22]=uint8_t(subtype);Bytes mapped=original;
        size_t base=60+prefix,body=base+26;
        check(mapGen5BeaconIdentity(mapped,native,alias));
        check(std::equal(alias.begin(),alias.end(),mapped.begin()+body+46));
        check(beacon16(mapped.data()+base+24)==beaconCRC(mapped.data()+body,110));
        for(size_t i=0;i<original.size();i++)if(i!=base+24&&i!=base+25&&!(i>=body+46&&i<body+52))check(mapped[i]==original[i]);
        Bytes peer=mapped;check(!mapGen5BeaconIdentity(peer,other,native)&&peer==mapped);
        check(mapGen5BeaconIdentity(mapped,alias,native)&&mapped==original);
    }
    for(unsigned fault=0;fault<10;fault++){
        Bytes p=beacon(native);
        switch(fault){
        case 0:p[59]=255;break;
        case 1:p[74]^=1;break;
        case 2:p[84]^=1;break;
        case 3:p[22]=0xa4;break;
        case 4:p[23]=0x40;break;
        case 5:put(p,72,0x1348);break;
        case 6:put(p,88,0x13);put(p,84,beaconCRC(p.data()+86,110));break;
        case 7:p[78]=111;break;
        case 8:p[79]=11;break;
        case 9:p.resize(199);break;
        }
        Bytes original=p;check(!mapGen5BeaconIdentity(p,native,alias)&&p==original);
    }
    // An invitation contains a recipient address separate from the sender's
    // trainer address. Resolve only our target alias on the incoming path.
    Bytes invite=beacon(other);address(invite,92,alias);put(invite,84,beaconCRC(invite.data()+86,110));
    Bytes original=invite;check(mapGen5BeaconIdentity(invite,alias,native));
    check(std::equal(native.begin(),native.end(),invite.begin()+92));
    check(std::equal(other.begin(),other.end(),invite.begin()+132));
    check(beacon16(invite.data()+84)==beaconCRC(invite.data()+86,110));
    check(mapGen5BeaconIdentity(invite,native,alias)&&invite==original);
    Nonce left{},right{};left[0]=7;right[0]=8;
    Room a(left,"IRBO",0,native),b(right,"IRAO",0,native);a.radio(true);b.radio(true);
    check(a.add(right,"IRAO",0,Room::address(right))&&b.add(left,"IRBO",0,Room::address(left)));
    auto pump=[&](){for(unsigned round=0;round<8;round++){
        for(auto &wire:a.takeWire(right))check(b.receive(left,wire.data(),wire.size()));
        for(auto &wire:b.takeWire(left))check(a.receive(right,wire.data(),wire.size()));
    }};
    pump();check(a.active()&&b.active());
    invite=beacon(native);address(invite,32,native);address(invite,38,native);address(invite,92,b.alias());
    put(invite,84,beaconCRC(invite.data()+86,110));original=invite;
    check(a.send(invite.data(),invite.size()));pump();Received delivered;check(b.pop(delivered));
    check(std::equal(native.begin(),native.end(),delivered.data.begin()+92));
    MAC leftAlias=a.alias();check(std::equal(leftAlias.begin(),leftAlias.end(),delivered.data.begin()+132));
    check(beacon16(delivered.data.data()+84)==beaconCRC(delivered.data.data()+86,110));
    check(invite==original);
    for(size_t length:{size_t(0),size_t(10),size_t(61),MaxPacket+1}){Bytes p(length,0),bounded=p;check(!mapGen5BeaconIdentity(p,native,alias)&&p==bounded);}
    std::cout<<"{\"synthetic_gen5_beacon_identity_checks\":"<<checks<<",\"physical_verified\":false}"<<std::endl;
}
