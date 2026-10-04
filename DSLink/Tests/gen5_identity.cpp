// SPDX-License-Identifier: AGPL-3.0-or-later
#include "Room.hpp"
#include <iostream>
#include <stdexcept>
using namespace manicds;
static unsigned checks=0;
static void check(bool value){if(!value)throw std::runtime_error("Gen 5 native identity regression");++checks;}
int main(){
    MAC leftMAC{0,9,191,1,2,3},rightMAC{0,9,191,1,2,4};
    for(const char *code:{"ADAE","APAE","CPUE","IPKE","IPGE","IRBO","IRAO","IREO","IRDO"}){
        const char *peer=title(code)<=5?"CPUE":"IRDO";
        Nonce left{},right{},extra{};left[0]=7;right[0]=8;extra[0]=9;
        Room a(left,code,0,leftMAC),b(right,peer,0,rightMAC);a.radio(true);b.radio(true);
        check(!a.add(extra,peer,0,leftMAC));check(!a.add(extra,peer,0,MAC{}));
        check(!a.add(extra,peer,0,MAC{1,9,191,1,2,5}));
        check(a.add(right,peer,0,rightMAC)&&b.add(left,code,0,leftMAC));
        auto pump=[&](){for(unsigned round=0;round<8;round++){
            for(auto &wire:a.takeWire(right))check(b.receive(left,wire.data(),wire.size()));
            for(auto &wire:b.takeWire(left))check(a.receive(right,wire.data(),wire.size()));
        }};
        pump();check(a.active()&&b.active());check(a.alias()==leftMAC&&b.alias()==rightMAC);
        // Addresses occur in headers, advertisements, invitations and native
        // command/reply bodies. Every byte must survive both directions.
        for(size_t size:{size_t(214),size_t(144),size_t(514),MaxPacket})for(unsigned kind:{0u,1u,2u}){
            Bytes original(size,0);for(size_t i=0;i<size;i++)original[i]=uint8_t(i*71+23);
            original[8]=kind==1?1:0;original[9]=uint8_t(kind);original[22]=kind?0xa4:0x80;
            for(size_t offset:{size_t(26),size_t(32),size_t(38),size_t(60),size_t(68),size_t(106)})
                std::copy(leftMAC.begin(),leftMAC.end(),original.begin()+offset);
            for(Room *sender:{&a,&b}){
                Room *receiver=sender==&a?&b:&a;
                check(sender->send(original.data(),original.size()));pump();Received packet;
                check(receiver->pop(packet)&&packet.data==original);
            }
        }
        b.radio(false);pump();b.radio(true);pump();
        check(a.active()&&b.active()&&a.pendingCount()==0&&b.pendingCount()==0);
    }
    std::cout<<"{\"synthetic_gen5_native_identity_checks\":"<<checks<<",\"physical_verified\":false}"<<std::endl;
}
