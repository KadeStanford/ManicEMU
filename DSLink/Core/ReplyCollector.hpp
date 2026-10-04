// SPDX-License-Identifier: AGPL-3.0-or-later
// Proposed production helper. No game-specific data is interpreted.
#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <map>
#include <chrono>

namespace manicds {
// A native empty reply has AID 0 and no radio frame. Associate it only with
// a source which previously sent a valid addressed payload reply to this host.
// Unknown sources and prior-session sources cannot satisfy the current mask.
class ReplySources {
public:
    void reset() noexcept { learned_.clear(); }
    uint8_t associate(uint16_t source, uint8_t aid, uint64_t timestamp,
                      size_t length) {
        if (source == 65535) return 0;
        if (aid > 0 && aid < 16 && length >= 36 && length <= 2048) {
            auto found = learned_.find(source);
            if (found == learned_.end() || timestamp >= found->second.timestamp)
                learned_[source] = Entry{aid, timestamp};
            return aid;
        }
        if (aid || length) return 0;
        auto found = learned_.find(source);
        return found != learned_.end() && timestamp >= found->second.timestamp
            ? found->second.aid : 0;
    }
private:
    struct Entry { uint8_t aid; uint64_t timestamp; };
    std::map<uint16_t, Entry> learned_;
};

class ReplyCollector {
public:
    ReplyCollector(uint64_t timestamp, uint16_t expected) noexcept
        : earliest_(timestamp >= 32 ? timestamp - 32 : 0),
          expected_(uint16_t(expected & 0xfffe)) {}
    bool complete() const noexcept { return (answered_ & expected_) == expected_; }
    bool expired() const noexcept { return std::chrono::steady_clock::now() >= deadline_; }
    uint16_t payloads() const noexcept { return payloads_; }
    uint16_t answered() const noexcept { return answered_; }
    bool accept(uint64_t timestamp, uint8_t aid, uint8_t sourceAid,
                const void* data, size_t length, uint8_t* packets) noexcept {
        if (timestamp < earliest_) return false;
        const bool empty = aid == 0 && length == 0;
        if (!empty && (!data || !packets || aid == 0 || aid >= 16 ||
                       length < 36 || length > 2048 || sourceAid != aid))
            return false;
        const uint8_t associated = empty ? sourceAid : aid;
        if (!associated || associated >= 16) return false;
        const uint16_t bit = uint16_t(1u << associated);
        if (!(expected_ & bit) || (answered_ & bit)) return false;
        if (!empty) {
            std::memcpy(packets + size_t(associated - 1) * 1024,
                        data, std::min(length, size_t(1024)));
            payloads_ |= bit;
        }
        answered_ |= bit;
        return true;
    }
private:
    uint64_t earliest_;
    uint16_t expected_, answered_ = 0, payloads_ = 0;
    std::chrono::steady_clock::time_point deadline_ =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(25);
};
}
