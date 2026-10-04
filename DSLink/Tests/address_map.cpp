// SPDX-License-Identifier: AGPL-3.0-or-later
#include "Protocol.hpp"
#include <algorithm>
#include <iostream>
#include <stdexcept>
using namespace manicds;
static unsigned checks=0;
static void check(bool ok,const char *name){if(!ok)throw std::runtime_error(name);++checks;}
static void address(Bytes &b,size_t n,const MAC &m){std::copy(m.begin(),m.end(),b.begin()+n);}
static MAC address(const Bytes &b,size_t n){MAC m;std::copy_n(b.begin()+n,6,m.begin());return m;}
int main(){try{
    const MAC native{0,9,191,17,34,51},different{0,9,191,1,2,3};
    FrameAddressMap a,b;check(a.configure(native,native,0)&&b.configure(native,native,1),"collision configuration");
    check(a.enabled()&&b.enabled(),"collision enables peer header map");
    for(unsigned fc:{0x0080u,0x0008u,0x0158u,0x0218u}){
        Bytes original(100,0);original[22]=uint8_t(fc);original[23]=uint8_t(fc>>8);
        address(original,32,native);address(original,38,native);address(original,60,native);
        Bytes wire=original;a.outgoing(wire);const MAC aliasA=address(wire,32);
        check(aliasA!=native&&address(wire,38)==aliasA,"source and BSSID translated");
        check(address(original,32)==native,"core's outgoing buffer remains unchanged");
        check(std::equal(wire.begin()+44,wire.end(),original.begin()+44),"game payload including MAC-shaped bytes remains unchanged");
        Bytes onB=wire;b.incoming(onB);check(onB==wire,"peer source alias stays distinct at receiver");
        Bytes reply=original;b.outgoing(reply);const MAC aliasB=address(reply,32);
        check(aliasB!=aliasA&&aliasB!=native,"two independent peer aliases");
        address(reply,26,aliasA);a.incoming(reply);check(address(reply,26)==native&&address(reply,32)==aliasB,"unicast destination restored without collapsing peer source");
    }
    FrameAddressMap normal;check(normal.configure(native,different,0)&&!normal.enabled(),"distinct firmware identities need no translation");
    Bytes unchanged(100,0);address(unchanged,32,native);Bytes copy=unchanged;normal.outgoing(copy);normal.incoming(copy);check(copy==unchanged,"distinct identity packets are byte-identical");
    for(size_t n:{size_t(0),size_t(10),size_t(45),MaxPacket+1}){Bytes shortPacket(n,0);copy=shortPacket;a.outgoing(copy);a.incoming(copy);check(copy==shortPacket,"short and oversize packet bounds");}
    Bytes control=unchanged;control[22]=0xa4;copy=control;a.outgoing(copy);check(copy==control,"control frame payload cannot be mistaken for address three");
    for(MAC invalid:{MAC{},MAC{1,9,191,1,2,3}})check(!a.configure(invalid,native,0)&&!a.enabled(),"invalid identity disables map");
    check(!a.configure(native,native,2),"only two independent consoles supported");
    const MAC reserved{0,9,191,250,0,1};check(a.configure(reserved,reserved,0)&&b.configure(reserved,reserved,1),"firmware matching a reserved alias");
    copy=unchanged;address(copy,32,reserved);a.outgoing(copy);check(address(copy,32)!=reserved,"alias never collides with native firmware identity");
    std::cout<<"{\"address_map_checks_passed\":"<<checks<<",\"synthetic_only\":true}"<<std::endl;return 0;
}catch(const std::exception &e){std::cerr<<e.what()<<std::endl;return 1;}}
