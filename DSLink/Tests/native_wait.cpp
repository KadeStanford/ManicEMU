// SPDX-License-Identifier: AGPL-3.0-or-later
// Compile unchanged functions extracted from actual patched MpState source.
// Only frontend callbacks and packet storage are stubbed; no private inputs.
#include "ReceiveDeadline.hpp"
#include "Diagnostics.hpp"
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <queue>
#include <thread>
#define retro_assert assert
// Exact public libretro ABI used by these two functions. Test-only declarations
// avoid requiring a libretro-common dependency for the protocol regression.
constexpr int RETRO_NETPACKET_FLUSH_HINT = 1 << 2;
constexpr uint16_t RETRO_NETPACKET_BROADCAST = 0xffff;
using retro_netpacket_send_t = void (*)(int, const void*, size_t, uint16_t);
using retro_netpacket_poll_receive_t = void (*)();
constexpr long RECV_TIMEOUT_MS = 25;
constexpr int SUCCESSIVE_TIMEOUTS_WARNING = 6;
struct Packet {
    unsigned value;
    uint64_t Timestamp() const {return 1000;}
    uint8_t Aid() const {return 1;}
    uint8_t SourceAid() const {return 1;}
    uint16_t SourceSlot() const {return 1;}
    unsigned PacketType() const {return 0;}
    uint64_t Length() const {return sizeof(bytes);}
    const void* Data() const {return bytes;}
    uint8_t bytes[40]{};
};
class MpState {
public:
    bool IsReady() const { return _sendFn && _pollFn; }
    uint32_t QueueDepth() const {return uint32_t(receivedPackets.size());}
    std::optional<Packet> NextPacket() noexcept;
    std::optional<Packet> NextPacketBlockBefore(uint32_t maximumWaitMicros) noexcept;
    std::optional<Packet> NextPacketBlockAfter(uint32_t maximumWaitMicros) noexcept;
    std::queue<Packet> receivedPackets;
    retro_netpacket_send_t _sendFn = nullptr;
    retro_netpacket_poll_receive_t _pollFn = nullptr;
    int _timeoutCount = 0;
    bool _warnedHighLatency = false;
};
enum class Mode { ArrivalDuringFinalWait, NormalWake, NoArrival };
static MpState* active = nullptr;
static Mode mode = Mode::NoArrival;
static bool frontendPending = false;
static unsigned polls = 0, waits = 0, timeouts = 0, checks = 0;
static void check(bool value) {
    ++checks;
    if (!value) { std::fprintf(stderr, "native wait check %u failed\n", checks); std::exit(1); }
}
static void send(int flags, const void*, size_t size, uint16_t target) {
    check(flags == RETRO_NETPACKET_FLUSH_HINT && size == 0 && target == RETRO_NETPACKET_BROADCAST);
}
static void poll() {
    ++polls;
    if (frontendPending) { active->receivedPackets.push(Packet{42}); frontendPending = false; }
}
namespace retro {
bool environment(unsigned cmd, void* data) noexcept {
    if (cmd == manicds::DiagnosticEnvironment) {
        const auto& value=*static_cast<manicds::NativeDiagnostic*>(data);
        check(value.version==1&&value.length<=2048&&(!value.length||value.payload));
        check(value.event==7||value.event==8);return true;
    }
    if (cmd == 0x4d445301) {
        struct Event { uint32_t event; uint32_t reserved; const void* packet; } value{};
        std::memcpy(&value,data,sizeof(value));
        check(value.event==4&&value.reserved==0&&!value.packet); ++timeouts; return true;
    }
    check(cmd == 0x4d445302);
    const auto micros = *static_cast<uint32_t*>(data);
    check(micros > 0 && micros <= 1000); ++waits;
    if (mode != Mode::NoArrival) frontendPending = true;
    if (mode == Mode::ArrivalDuringFinalWait)
        std::this_thread::sleep_for(std::chrono::milliseconds(3));
    return true;
}
bool set_warn_message(const char*) { return true; }
void debug(const char*) {}
}
#ifndef MANIC_DS_WAIT_FUNCTIONS
#error Generate the pinned native_wait_functions.inc from actual before/after source.
#endif
#include MANIC_DS_WAIT_FUNCTIONS
int main() {
    MpState state;
    auto reset = [&] (Mode next) {
        state = {}; state._sendFn = send; state._pollFn = poll; active = &state;
        mode = next; frontendPending = false; polls = waits = timeouts = 0;
    };
    reset(Mode::ArrivalDuringFinalWait);
    auto packet = state.NextPacketBlockBefore(1000);
    check(!packet && frontendPending && timeouts == 1 && waits == 1);
    reset(Mode::ArrivalDuringFinalWait);
    packet = state.NextPacketBlockAfter(1000);
    check(packet && packet->value == 42 && !frontendPending && timeouts == 0 && waits == 1);
    check(polls == 2 && state._timeoutCount == 0);

    reset(Mode::NoArrival); frontendPending = true;
    check(!state.NextPacketBlockBefore(0) && frontendPending && timeouts == 1 && waits == 0);
    reset(Mode::NoArrival); frontendPending = true;
    packet = state.NextPacketBlockAfter(0);
    check(packet && packet->value == 42 && !frontendPending && timeouts == 0 && waits == 0 && polls == 1);

    reset(Mode::NoArrival);
    check(!state.NextPacketBlockAfter(0) && timeouts == 1 && waits == 0 && polls == 1);
    reset(Mode::NoArrival); state.receivedPackets.push(Packet{43});
    packet = state.NextPacketBlockAfter(0);
    check(packet && packet->value == 43 && polls == 0 && waits == 0 && timeouts == 0);

    reset(Mode::NormalWake);
    packet = state.NextPacketBlockAfter(25000);
    check(packet && packet->value == 42 && timeouts == 0 && waits == 1);
    std::printf("{\"checks\":%u,\"compiled_actual_mpstate_functions\":true,\"old_bug_reproduced\":true,\"extra_waits_added\":false,\"private_inputs\":false,\"physical_phone_verified\":false}\n", checks);
}
