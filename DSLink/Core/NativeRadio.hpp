// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include "Protocol.hpp"
#include <algorithm>
#include <cstring>
#include <limits>

namespace manicds {
// Native RF is independent of the reliable room-control sequence. Callers
// serialize access and obtain epochs only from validated reliable controls.
class NativeRadioEdge {
public:
    static constexpr size_t Header = 64;
    NativeRadioEdge(Nonce local, Nonce peer) : id_(local < peer ? 0 : 1) {
        const auto& a = id_ ? peer : local;
        const auto& b = id_ ? local : peer;
        std::copy(a.begin(), a.end(), room_.begin());
        std::copy(b.begin(), b.end(), room_.begin() + 16);
    }
    bool peerRadio(uint64_t epoch, bool on) {
        if (!epoch || epoch < peerEpoch_) return false;
        if (epoch == peerEpoch_ && !peerOn_ && on) return false;
        const bool changed = epoch != peerEpoch_ || on != peerOn_;
        if (epoch > peerEpoch_) {
            peerEpoch_ = epoch; highest_ = seen_ = 0;
        }
        peerOn_ = on;
        if (changed) discardIncoming();
        return true;
    }
    bool localRadio(uint64_t epoch, bool on) {
        if (!epoch || epoch < localEpoch_) return false;
        if (epoch == localEpoch_ && !localOn_ && on) return false;
        const bool changed = epoch != localEpoch_ || on != localOn_;
        if (epoch > localEpoch_) { localEpoch_ = epoch; tx_ = 0; }
        localOn_ = on;
        if (changed) discardIncoming();
        return true;
    }
    bool active() const { return localOn_ && peerOn_; }
    uint64_t generation() const { return generation_; }
    void discardIncoming() { incoming_.clear(); ++generation_; }
    Bytes encode(const void* data, size_t size) {
        if (!active() || !validPacket(data, size) ||
            tx_ == std::numeric_limits<uint64_t>::max()) return {};
        Bytes wire(Header + size, 0);
        std::memcpy(wire.data(), "MDR1", 4); wire[4] = 1; wire[5] = id_;
        put16(wire.data() + 6, uint16_t(size));
        std::copy(room_.begin(), room_.end(), wire.begin() + 8);
        put64(wire.data() + 40, localEpoch_); put64(wire.data() + 48, ++tx_);
        put64(wire.data() + 56, peerEpoch_);
        std::memcpy(wire.data() + Header, data, size); ++sent_;
        return wire;
    }
    // Checks the repeated full envelope on each fragment before allocating
    // reassembly storage. Its size is the header size, not native payload size.
    bool acceptsHeader(const void* data, size_t size) const {
        if (!active() || !data || size < Header) return false;
        const auto* p = static_cast<const uint8_t*>(data);
        const size_t length = get16(p + 6);
        return !std::memcmp(p, "MDR1", 4) && p[4] == 1 &&
            p[5] == uint8_t(1 - id_) && length >= 10 && length <= MaxPacket &&
            !std::memcmp(p + 8, room_.data(), room_.size()) &&
            get64(p + 40) == peerEpoch_ && get64(p + 56) == localEpoch_ &&
            get64(p + 48) != 0;
    }
    bool receive(const void* data, size_t size) {
        if (!acceptsHeader(data, size) || size < Header + 10 ||
            size > Header + MaxPacket) { ++dropped_; return false; }
        const auto* p = static_cast<const uint8_t*>(data);
        if (get16(p + 6) != size - Header ||
            !validPacket(p + Header, size - Header)) { ++dropped_; return false; }
        const uint64_t sequence = get64(p + 48);
        uint64_t nextHighest = highest_, nextSeen = seen_;
        if (sequence > highest_) {
            const auto distance = sequence - highest_;
            nextSeen = distance >= 64 ? 1 : (seen_ << distance) | 1;
            nextHighest = sequence;
        } else {
            const auto distance = highest_ - sequence;
            if (distance >= 64 || (seen_ & (uint64_t(1) << distance))) {
                ++dropped_; return false;
            }
            nextSeen |= uint64_t(1) << distance;
        }
        if (incoming_.size() >= MaxQueue) { ++dropped_; return false; }
        incoming_.emplace_back(p + Header, p + size);
        highest_ = nextHighest; seen_ = nextSeen; ++received_; return true;
    }
    bool pop(Bytes& packet) {
        if (!active() || incoming_.empty()) return false;
        packet = std::move(incoming_.front()); incoming_.pop_front(); return true;
    }
    size_t queued() const { return incoming_.size(); }
    // Counts successful encoding/accepted RF, never delivery acknowledgement.
    uint64_t sent() const { return sent_; }
    uint64_t received() const { return received_; }
    uint64_t dropped() const { return dropped_; }
private:
    static uint16_t get16(const uint8_t* p) { return uint16_t((unsigned(p[0]) << 8) | p[1]); }
    static void put16(uint8_t* p, uint16_t v) { p[0] = uint8_t(v >> 8); p[1] = uint8_t(v); }
    static uint64_t get64(const uint8_t* p) {
        uint64_t v = 0; for (unsigned i = 0; i < 8; ++i) v = (v << 8) | p[i]; return v;
    }
    static void put64(uint8_t* p, uint64_t v) {
        for (unsigned i = 0; i < 8; ++i) p[7 - i] = uint8_t(v >> (8 * i));
    }
    std::array<uint8_t, 32> room_{};
    uint8_t id_;
    uint64_t localEpoch_ = 0, peerEpoch_ = 0, tx_ = 0, highest_ = 0, seen_ = 0;
    uint64_t dropped_ = 0, generation_ = 0, sent_ = 0, received_ = 0;
    bool localOn_ = false, peerOn_ = false;
    std::deque<Bytes> incoming_;
};
}
