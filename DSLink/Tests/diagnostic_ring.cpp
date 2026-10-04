// SPDX-License-Identifier: AGPL-3.0-or-later
#include "DiagnosticRing.hpp"
#include <cstdio>
#include <cstdlib>
using namespace manicds;
static unsigned checks=0;
static void check(bool condition){++checks;if(!condition)std::exit(1);}
int main(){
    DiagnosticRing ring;NativeDiagnostic trace;trace.event=2;
    std::array<uint8_t,2048> payload{};for(size_t i=0;i<payload.size();++i)payload[i]=uint8_t(i);
    trace.length=2048;trace.payload=payload.data();trace.sourceSlot=4;trace.sourceAid=2;trace.aid=2;
    check(ring.record(trace,100));payload.fill(0);
    check(ring.at(0).native.payload==nullptr&&ring.at(0).native.length==2048);
    for(size_t i=0;i<payload.size();++i)check(ring.at(0).payload[i]==uint8_t(i));
    trace.length=2049;trace.payload=reinterpret_cast<const void*>(uintptr_t(1));check(!ring.record(trace,101));
    trace.length=1;trace.payload=nullptr;check(!ring.record(trace,101));
    trace.length=0;trace.version=2;check(!ring.record(trace,101));trace.version=1;
    trace.event=9;check(!ring.record(trace,101));trace.event=5;
    trace.aid=16;check(!ring.record(trace,101));trace.aid=0;
    trace.sourceAid=16;check(!ring.record(trace,101));trace.sourceAid=0;
    trace.sourceSlot=65536;check(!ring.record(trace,101));trace.sourceSlot=65535;
    trace.packetType=4;check(!ring.record(trace,101));trace.packetType=3;
    trace.aidmask=65536;check(!ring.record(trace,101));trace.aidmask=0;
    trace.payloadmask=65536;check(!ring.record(trace,101));trace.payloadmask=0;
    trace.answeredmask=65536;check(!ring.record(trace,101));trace.answeredmask=0;
    for(unsigned i=0;i<10000;++i){trace.timestamp=i;check(ring.record(trace,i+200));}
    check(ring.size()==128&&ring.count()==10001&&ring.overwritten()==9873&&ring.rejected()==11);
    for(size_t i=0;i<ring.size();++i){check(ring.at(i).sequence==9874+i);check(ring.at(i).native.timestamp==9872+i);}
    trace.event=100;trace.payload=payload.data();trace.length=1000;check(ring.record(trace,20000));
    check(sizeof(NativeDiagnostic)==72);
    std::printf("{\"checks\":%u,\"bounded_records\":128,\"max_copied_bytes\":2048,\"no_retained_engine_pointer\":true,\"private_inputs\":false}\n",checks);
}
