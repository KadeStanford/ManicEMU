// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include "NativeRadio.hpp"
#include <chrono>

namespace manicds {
// One instance per NativeRadioEdge. Every message repeats its full 64-byte RF
// envelope; no fragment may establish a radio epoch or deliver partial RF.
// 1000 bytes is a conservative chosen carrier bound, not an Apple API promise.
class RadioFragments {
public:
    using Clock = std::chrono::steady_clock;
    using TimePoint = Clock::time_point;
    static constexpr size_t MaxMessage = 1000;
    static constexpr size_t Header = NativeRadioEdge::Header + 8;
    static constexpr size_t Chunk = MaxMessage - Header;
    static constexpr size_t MaxIncomplete = 8;
    static constexpr unsigned LifetimeMs = 100;
    static std::vector<Bytes> split(const Bytes& envelope) {
        std::vector<Bytes> result;
        if (envelope.size() < NativeRadioEdge::Header + 10 ||
            envelope.size() > NativeRadioEdge::Header + MaxPacket) return result;
        const auto* p = envelope.data();
        const size_t total = get16(p + 6);
        if (std::memcmp(p, "MDR1", 4) || p[4] != 1 || p[5] > 1 ||
            total != envelope.size() - NativeRadioEdge::Header ||
            !validPacket(p + NativeRadioEdge::Header, total)) return result;
        const auto count = uint8_t((total + Chunk - 1) / Chunk);
        for (uint8_t index = 0; index < count; ++index) {
            const size_t offset = size_t(index) * Chunk;
            const size_t length = std::min(Chunk, total - offset);
            Bytes message(Header + length, 0);
            std::copy_n(p, NativeRadioEdge::Header, message.begin());
            message[64] = index; message[65] = count;
            put16(message.data() + 66, uint16_t(offset));
            put16(message.data() + 68, uint16_t(length));
            std::copy_n(p + NativeRadioEdge::Header + offset, length,
                        message.begin() + Header);
            result.push_back(std::move(message));
        }
        return result;
    }
    // False means an RF fragment was dropped; it is never a reliable-control
    // failure. Duplicate, overflow, stale and malformed RF remain nonfatal.
    bool receive(const void* data, size_t size, const NativeRadioEdge& radio,
                 TimePoint now = Clock::now()) {
        synchronize(radio);
        expire(now);
        if (!data || size < Header + 1 || size > MaxMessage ||
            !radio.acceptsHeader(data, size)) { ++dropped_; return false; }
        const auto* p = static_cast<const uint8_t*>(data);
        const size_t total = get16(p + 6), index = p[64], count = p[65];
        const size_t offset = get16(p + 66), length = get16(p + 68);
        const size_t expectedCount = (total + Chunk - 1) / Chunk;
        if (count != expectedCount || index >= count ||
            offset != index * Chunk || offset >= total ||
            length != std::min(Chunk, total - offset) ||
            size != Header + length || p[70] || p[71]) {
            ++dropped_; return false;
        }
        std::array<uint8_t, NativeRadioEdge::Header> key{};
        std::copy_n(p, key.size(), key.begin());
        if (std::find(recent_.begin(), recent_.end(), key) != recent_.end()) {
            ++duplicates_; return false;
        }
        auto found = std::find_if(partials_.begin(), partials_.end(),
            [&](const Partial& value) { return sameSequence(value.header, key); });
        if (found != partials_.end() && found->header != key) {
            ++dropped_; return false; // Same sequence may not change its length.
        }
        if (found == partials_.end()) {
            if (partials_.size() == MaxIncomplete) {
                partials_.pop_front(); ++dropped_; // A lost packet cannot park new RF.
            }
            Partial partial;
            partial.header = key; partial.expires = now + std::chrono::milliseconds(LifetimeMs);
            partial.envelope.resize(NativeRadioEdge::Header + total);
            std::copy(key.begin(), key.end(), partial.envelope.begin());
            partials_.push_back(std::move(partial)); found = partials_.end() - 1;
        }
        const auto bit = uint8_t(1u << index);
        auto* destination = found->envelope.data() + NativeRadioEdge::Header + offset;
        if (found->received & bit) {
            ++duplicates_;
            if (std::memcmp(destination, p + Header, length)) { ++dropped_; return false; }
            return true;
        }
        std::memcpy(destination, p + Header, length); found->received |= bit;
        if (found->received != uint8_t((1u << count) - 1)) return true;
        if (!validPacket(found->envelope.data() + NativeRadioEdge::Header, total)) {
            partials_.erase(found); ++dropped_; return false;
        }
        recent_.push_back(key); if (recent_.size() > 64) recent_.pop_front();
        if (complete_.size() == MaxQueue) {
            partials_.erase(found); ++dropped_; return false;
        }
        complete_.push_back(std::move(found->envelope)); partials_.erase(found);
        return true;
    }
    bool pop(Bytes& envelope, const NativeRadioEdge& radio) {
        synchronize(radio);
        return radio.active() && pop(envelope);
    }
    // This overload is for immediate draining after receive/synchronize.
    // Call the radio overload when a control transition may have occurred.
    bool pop(Bytes& envelope) {
        if (complete_.empty()) return false;
        envelope = std::move(complete_.front()); complete_.pop_front(); return true;
    }
    void expire(TimePoint now = Clock::now()) {
        for (auto it = partials_.begin(); it != partials_.end();) {
            if (now >= it->expires) { it = partials_.erase(it); ++dropped_; }
            else ++it;
        }
    }
    void reset() { clear(); haveGeneration_ = false; }
    void synchronize(const NativeRadioEdge& radio) {
        if (!haveGeneration_ || generation_ != radio.generation() || !radio.active()) clear();
        generation_ = radio.generation(); haveGeneration_ = true;
    }
    size_t incompleteCount() const { return partials_.size(); }
    size_t queuedIncomplete() const { return partials_.size(); }
    size_t queued() const { return complete_.size(); }
    uint64_t dropped() const { return dropped_; }
    uint64_t duplicateCount() const { return duplicates_; }
private:
    struct Partial {
        std::array<uint8_t, NativeRadioEdge::Header> header{};
        Bytes envelope;
        TimePoint expires{};
        uint8_t received = 0;
    };
    static bool sameSequence(const std::array<uint8_t, NativeRadioEdge::Header>& a,
                             const std::array<uint8_t, NativeRadioEdge::Header>& b) {
        // All identity/epoch/sequence fields match; length is intentionally
        // excluded here so inconsistent length is rejected, not a second set.
        return !std::memcmp(a.data(), b.data(), 6) &&
            !std::memcmp(a.data() + 8, b.data() + 8, NativeRadioEdge::Header - 8);
    }
    static uint16_t get16(const uint8_t* p) { return uint16_t((unsigned(p[0]) << 8) | p[1]); }
    static void put16(uint8_t* p, uint16_t v) { p[0] = uint8_t(v >> 8); p[1] = uint8_t(v); }
    void clear() { partials_.clear(); complete_.clear(); recent_.clear(); }
    std::deque<Partial> partials_;
    std::deque<Bytes> complete_;
    std::deque<std::array<uint8_t, NativeRadioEdge::Header>> recent_;
    uint64_t generation_ = 0, dropped_ = 0, duplicates_ = 0;
    bool haveGeneration_ = false;
};
}
