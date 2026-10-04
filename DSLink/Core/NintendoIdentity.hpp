// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include "Protocol.hpp"
#include <algorithm>
namespace manicds {
inline uint16_t beaconCRC(const uint8_t *data,size_t size){
    uint16_t value=0xffff;
    for(size_t n=0;n<size;n++){
        value^=uint16_t(data[n])<<8;
        for(unsigned bit=0;bit<8;bit++)value=uint16_t((value<<1)^((value&0x8000)?0x1021:0));
    }
    return value;
}
inline uint16_t beacon16(const uint8_t *p){return uint16_t(p[0]|(unsigned(p[1])<<8));}
// Gen 5 Union Room advertises the trainer's connection address inside its
// checksummed player information too. Mapping just IEEE headers leaves every
// generated-firmware console advertising the same trainer address: messages
// appear, but the game suppresses the remote avatar as its own console.
// Parse only this identified native field. Never search/replace arbitrary game
// payload, change firmware, or write the game's save/party/Trainer ID.
inline bool mapGen5BeaconIdentity(Bytes &packet,const MAC &from,const MAC &to){
    if(packet.size()<62||packet.size()>MaxPacket)return false;
    unsigned fc=packet[22]|(unsigned(packet[23])<<8);
    if((fc&0x00fc)!=0x0080&&(fc&0x00fc)!=0x0050)return false;
    if(fc&0x4000)return false;
    const size_t end=packet.size()-4; // native frame includes its FCS
    // First validate the entire bounded information-element list.
    for(size_t at=58;at<end;){
        if(end-at<2||size_t(packet[at+1])>end-at-2)return false;
        at+=size_t(packet[at+1])+2;
    }
    bool changed=false;
    for(size_t at=58;at<end;){
        const size_t length=packet[at+1],base=at+2;at=base+length;
        const uint8_t vendor[]{0,9,191,0,10,0};
        if(packet[base-2]!=0xdd||length!=136||
           !std::equal(std::begin(vendor),std::end(vendor),packet.begin()+base)||
           packet[base+18]!=112||packet[base+19]!=1||
           beacon16(packet.data()+base+12)!=0x1380||beacon16(packet.data()+base+14)!=0)continue;
        const size_t checksum=base+24,body=checksum+2;
        if(beacon16(packet.data()+body)!=0x1380||beacon16(packet.data()+body+2)!=0x14||
           beaconCRC(packet.data()+body,110)!=beacon16(packet.data()+checksum))continue;
        bool mapped=false;
        // +6: addressed invitation recipient; +46: advertised trainer address.
        // Incoming invitations must resolve our alias back to the native MAC
        // the receiving game compares against its own console identity.
        for(size_t address:{body+6,body+46})
            if(std::equal(from.begin(),from.end(),packet.begin()+address)){
                std::copy(to.begin(),to.end(),packet.begin()+address);mapped=true;
            }
        if(!mapped)continue;
        uint16_t crc=beaconCRC(packet.data()+body,110);
        packet[checksum]=uint8_t(crc);packet[checksum+1]=uint8_t(crc>>8);changed=true;
    }
    return changed;
}
}
