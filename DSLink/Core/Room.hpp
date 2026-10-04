// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include "Protocol.hpp"
#include <map>
#include <memory>

namespace manicds {
// A radio neighbourhood, not a game lobby. Nintendo's native association,
// player limits and invitations remain authoritative. Each reliable edge has
// independent sequence/ACK fences; a third console cannot change existing IDs.
class Room {
public:
    static constexpr size_t MaxPeers=7; // MCSession: eight independent consoles
    Room(Nonce identity,const char code[4],uint8_t revision,MAC native);
    bool add(Nonce peer,const char code[4],uint8_t revision,MAC alias);
    void remove(Nonce peer);
    bool receive(Nonce peer,const void *data,size_t size);
    bool send(const void *data,size_t size,uint16_t target=65535);
    bool pop(Received &packet);
    std::vector<Bytes> takeWire(Nonce peer);
    void radio(bool on);
    void hold(bool on);
    bool hasIncoming() const;
    bool active() const;
    bool paused() const { return held_; }
    size_t size() const {return peers_.size();}
    bool contains(Nonce peer) const {return peers_.count(peer)!=0;}
    uint16_t slot(Nonce peer) const;
    MAC alias() const {return alias_;}
    uint64_t sentCount() const;
    uint64_t receivedCount() const;
    uint64_t acknowledged() const;
    uint64_t rejectedCount() const;
    uint64_t duplicateCount() const;
    size_t pendingCount() const;
    static MAC address(Nonce identity);
private:
    struct Edge { std::unique_ptr<Protocol> protocol; MAC alias; uint16_t slot; };
    void translate(Bytes &packet,bool outgoing) const;
    Nonce identity_; std::array<char,4> code_{};uint8_t revision_;
    MAC native_,alias_;bool radio_=false,held_=false;
    uint16_t nextSlot_=1,cursor_=0;
    std::map<Nonce,Edge> peers_;
};
}
