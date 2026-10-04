// SPDX-License-Identifier: AGPL-3.0-or-later
#include "Batch.hpp"
#include "ReceiveDeadline.hpp"
#include <iostream>
#include <thread>
#include <ctime>
#include <stdexcept>
using namespace manicds;
static unsigned checks=0;
static void check(bool pass){if(!pass)throw std::runtime_error("batch/wall-clock check failed");checks++;}
int main(){
    std::vector<Bytes> frames;for(unsigned n=0;n<35;n++){Bytes f(WireHeader+20,uint8_t(n));frames.push_back(f);}
    auto batches=batchWire(frames);check(batches.size()==3);std::vector<Bytes> roundtrip;
    for(const auto &batch:batches){std::vector<Bytes> parsed;check(unbatchWire(batch.data(),batch.size(),parsed));roundtrip.insert(roundtrip.end(),parsed.begin(),parsed.end());}
    check(roundtrip==frames);
    for(size_t size=0;size<batches[0].size();size++){
        std::vector<Bytes> unchanged{Bytes{42}};check(!unbatchWire(batches[0].data(),size,unchanged)&&unchanged==std::vector<Bytes>{Bytes{42}});
    }
    for(size_t offset:{size_t(0),size_t(4),size_t(5),size_t(6),size_t(7),size_t(8)}){
        auto bad=batches[0];bad[offset]=255;std::vector<Bytes> parsed;check(!unbatchWire(bad.data(),bad.size(),parsed));
    }
    auto trailing=batches[0];trailing.push_back(0);std::vector<Bytes> parsed;check(!unbatchWire(trailing.data(),trailing.size(),parsed));
    Bytes maximum(WireHeader+MaxPacket,0);auto maximumBatch=batchWire(std::vector<Bytes>(BatchFrames,maximum));check(maximumBatch[0].size()==MaxBatch&&unbatchWire(maximumBatch[0].data(),MaxBatch,parsed));
    auto begin=std::chrono::steady_clock::now();const auto idleCpuBegin=std::clock();ReceiveDeadline deadline(25);unsigned polls=0;
    while(auto wait=deadline.nextWaitMicros()){check(wait<=1000);std::this_thread::sleep_for(std::chrono::microseconds(wait));polls++;}
    const auto idleCpu=std::clock()-idleCpuBegin;const auto idleMs=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();check(idleMs>=20&&polls>0);
    const auto spinCpuBegin=std::clock();ReceiveDeadline old(25);while(old.nextWaitMicros()){}const auto spinCpu=std::clock()-spinCpuBegin;
    std::cout<<"{\"synthetic_checks\":"<<checks<<",\"idle_wall_ms\":"<<idleMs<<",\"notification_or_yield_polls\":"<<polls<<",\"yield_clock_ticks\":"<<idleCpu<<",\"spin_clock_ticks\":"<<spinCpu<<",\"physical_phone_performance_verified\":false}"<<std::endl;
}
