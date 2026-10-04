// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <chrono>
#include <cstdint>
namespace manicds {
class ReceiveDeadline {
public:
    explicit ReceiveDeadline(unsigned milliseconds):end_(Clock::now()+std::chrono::milliseconds(milliseconds)){}
    explicit ReceiveDeadline(std::chrono::microseconds duration):end_(Clock::now()+duration){}
    uint32_t nextWaitMicros(uint32_t limit=1000)const{
        const auto left=std::chrono::duration_cast<std::chrono::microseconds>(end_-Clock::now()).count();
        return left<=0?0:(left<int64_t(limit)?uint32_t(left):limit);
    }
private:
    using Clock=std::chrono::steady_clock;
    Clock::time_point end_;
};
}
