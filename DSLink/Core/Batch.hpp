// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include "Protocol.hpp"
#include <algorithm>
#include <cstring>
namespace manicds {
constexpr size_t BatchFrames=16;
constexpr size_t MaxBatch=8+BatchFrames*(2+WireHeader+MaxPacket);
inline std::vector<Bytes> batchWire(const std::vector<Bytes>&frames){
    std::vector<Bytes> batches;
    for(size_t i=0;i<frames.size();){
        const size_t count=std::min(BatchFrames,frames.size()-i);
        Bytes batch{'M','D','B','1',0,uint8_t(count),0,0};
        for(size_t n=0;n<count;n++,i++){
            const auto &f=frames[i];if(f.size()<WireHeader||f.size()>WireHeader+MaxPacket)return {};
            batch.push_back(uint8_t(f.size()>>8));batch.push_back(uint8_t(f.size()));batch.insert(batch.end(),f.begin(),f.end());
        }
        batches.push_back(std::move(batch));
    }
    return batches;
}
inline bool unbatchWire(const void *data,size_t size,std::vector<Bytes>&frames){
    if(!data||size<8||size>MaxBatch)return false;
    const auto *p=static_cast<const uint8_t*>(data);
    if(std::memcmp(p,"MDB1",4)||p[4]||!p[5]||p[5]>BatchFrames||p[6]||p[7])return false;
    std::vector<Bytes> parsed;size_t offset=8;
    for(size_t n=0;n<p[5];n++){
        if(size-offset<2)return false;
        const size_t length=(size_t(p[offset])<<8)|p[offset+1];offset+=2;
        if(length<WireHeader||length>WireHeader+MaxPacket||length>size-offset)return false;
        parsed.emplace_back(p+offset,p+offset+length);offset+=length;
    }
    if(offset!=size)return false;frames=std::move(parsed);return true;
}
}
