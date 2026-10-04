// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <vector>

namespace manicds {
constexpr size_t MaxPacket = 2058; // melonDS's 2048-byte packet + its 10-byte envelope
constexpr size_t MaxQueue = 256;
constexpr size_t WireHeader = 56;
using Nonce = std::array<uint8_t,16>;
using Bytes = std::vector<uint8_t>;
using MAC = std::array<uint8_t,6>;
// Local wireless addresses can collide when both cores generate the same
// firmware. Translate only the 802.11 header on the peer transport. The core's
// firmware, WiFi registers, WFC identity and game/save payload stay untouched.
class FrameAddressMap {
public:
    bool configure(MAC native,MAC peer,uint16_t id);
    void outgoing(Bytes &packet) const;
    void incoming(Bytes &packet) const;
    bool enabled() const {return enabled_;}
private:
    void replace(Bytes &packet,const MAC &from,const MAC &to) const;
    MAC native_{},alias_{};
    bool enabled_=false;
};
enum class Phase { Ready, Pairing, Active, Parked, Interrupted, Failed, Ended };
enum class Kind : uint8_t { Ready=1, Data=2, Ack=3, Radio=4, Hold=5, Close=6 };
struct Received { Bytes data; uint16_t source; };
int title(const char code[4]);
bool compatible(const char a[4],const char b[4]);
bool validPacket(const void *data,size_t size);
bool localFrame(const void *data,size_t size,unsigned type);

// Callers serialize access. Core callbacks are invoked by the core thread only.
// MCSession's reliable channel provides ordered delivery; ACKs fence radio-off
// controls and detect an interrupted transfer. There is no rollback or save sync.
class Protocol {
public:
    Protocol(Nonce identity,const char code[4],uint8_t revision);
    bool bind(Nonce peer,const char code[4],uint8_t revision);
    bool receive(const void *wire,size_t size);
    bool send(const void *data,size_t size,uint16_t target=65535);
    bool pop(Received &packet);
    void radio(bool on);
    void hold(bool on);
    void close();
    void disconnect();
    bool abandonAfterRadioOff();
    // Recovery is an explicit same-peer continuation. It never imports a state.
    bool reconnect(Nonce peer);
    Phase phase() const;
    bool paired() const {return bound_&&localReady_&&peerReady_&&readyAcked_&&!failed_&&!ended_;}
    bool bothOff() const {return paired()&&!radio_&&!peerRadio_;}
    bool settled() const {return pending_.empty()&&incoming_.empty();}
    bool paused() const {return held_||peerHeld_||interrupted_||failed_||(releaseSeq_&&acked_<releaseSeq_);}
    uint16_t id() const {return id_;}
    uint64_t receivedCount() const {return rx_;}
    uint64_t acknowledged() const {return acked_;}
    uint64_t sentCount() const {return tx_;}
    uint64_t duplicateCount() const {return duplicates_;}
    uint64_t rejectedCount() const {return rejected_;}
    std::vector<Bytes> takeWire();
    std::vector<Bytes> retransmit() const;
private:
    struct Pending {uint64_t sequence;Kind kind;Bytes wire;};
    bool enqueue(Kind kind,const void *data,size_t size,uint16_t target=65535);
    Bytes encode(Kind kind,uint64_t sequence,const void *data,size_t size,uint16_t target) const;
    void fail();
    Nonce identity_,peer_{};
    std::array<uint8_t,32> room_{};
    std::array<char,4> code_{};
    uint8_t revision_;
    uint16_t id_=0;
    uint64_t tx_=0,rx_=0,acked_=0,duplicates_=0,rejected_=0,readySeq_=0,releaseSeq_=0;
    bool bound_=false,localReady_=false,peerReady_=false,readyAcked_=false;
    bool radio_=false,peerRadio_=false,held_=false,peerHeld_=false;
    bool interrupted_=false,failed_=false,ended_=false,closeSent_=false,peerClose_=false;
    std::deque<Pending> pending_;
    std::deque<Received> incoming_;
    std::vector<Bytes> wire_;
};
}
