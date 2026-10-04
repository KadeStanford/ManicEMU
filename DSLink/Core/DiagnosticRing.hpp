// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include "Diagnostics.hpp"
#include <array>
#include <cstring>
#include <algorithm>
namespace manicds {
// Caller serializes access. Capture buffers own their data; no engine pointer
// or unbounded queue is retained. Packet recording performs no disk/JSON work.
class DiagnosticRing {
public:
    static constexpr size_t Capacity=128, MaxPayload=2048;
    struct Record {
        NativeDiagnostic native{};
        uint64_t sequence=0,wallMicros=0;
        std::array<uint8_t,MaxPayload> payload{};
    };
    bool record(const NativeDiagnostic& value,uint64_t wallMicros) noexcept {
        bool known=(value.event>=1&&value.event<=8)||(value.event>=100&&value.event<=106);
        if(value.version!=1||!known||value.length>MaxPayload||
           (value.length&&!value.payload)||value.aid>15||value.sourceAid>15||
           value.sourceSlot>65535||value.packetType>3||
           value.aidmask>65535||value.payloadmask>65535||value.answeredmask>65535){++rejected_;return false;}
        auto& entry=records_[count_%Capacity];
        entry.native=value;entry.native.payload=nullptr;
        entry.sequence=++count_;entry.wallMicros=wallMicros;
        if(value.length)std::memcpy(entry.payload.data(),value.payload,value.length);
        return true;
    }
    size_t size() const noexcept {return size_t(std::min(count_,uint64_t(Capacity)));}
    uint64_t count() const noexcept {return count_;}
    uint64_t overwritten() const noexcept {return count_>Capacity?count_-Capacity:0;}
    uint64_t rejected() const noexcept {return rejected_;}
    const Record& at(size_t chronologicalIndex) const noexcept {
        return records_[(count_-size()+chronologicalIndex)%Capacity];
    }
private:
    std::array<Record,Capacity> records_{};
    uint64_t count_=0,rejected_=0;
};
}
