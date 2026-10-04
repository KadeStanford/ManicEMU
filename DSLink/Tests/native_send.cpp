// SPDX-License-Identifier: AGPL-3.0-or-later
// Compile actual MpState::SendPacket unchanged against synthetic callbacks.
#include "Diagnostics.hpp"
#include "ReplyCollector.hpp"
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <vector>

#define retro_assert assert
constexpr int RETRO_NETPACKET_UNSEQUENCED = 2;
constexpr int RETRO_NETPACKET_UNRELIABLE = 0;
constexpr int RETRO_NETPACKET_FLUSH_HINT = 4;
constexpr uint16_t RETRO_NETPACKET_BROADCAST = 65535;
constexpr size_t HeaderSize = 10;

struct Packet {
    enum Type { Reply, Cmd, Other };
    Type type = Reply;
    uint8_t aid = 0;
    size_t length = 0;
    std::array<uint8_t, 40> bytes{};

    Type PacketType() const { return type; }
    uint64_t Timestamp() const { return 1000; }
    uint8_t Aid() const { return aid; }
    uint8_t SourceAid() const { return 0; }
    size_t Length() const { return length; }
    const void* Data() const { return length ? bytes.data() : nullptr; }
    std::vector<uint8_t> ToBuf() const {
        std::vector<uint8_t> result(10 + length);
        result[8] = aid;
        result[9] = type == Reply ? 1 : type == Cmd ? 2 : 0;
        std::copy_n(bytes.begin(), length, result.begin() + 10);
        return result;
    }
};

static unsigned checks = 0;
static void check(bool value) {
    ++checks;
    if (!value) {
        std::fprintf(stderr, "send trace check %u failed\n", checks);
        std::exit(1);
    }
}
static manicds::NativeDiagnostic captured;
static std::vector<uint8_t> wire;
static uint16_t target = 65535;

namespace retro {
bool environment(unsigned command, void* data) {
    check(command == manicds::DiagnosticEnvironment && data);
    captured = *static_cast<manicds::NativeDiagnostic*>(data);
    check(captured.version == 1 && captured.event == 1 && captured.length <= 2048);
    check(!captured.length || captured.payload);
    return true;
}
}

static void send(int flags, const void* data, size_t size, uint16_t slot) {
    check(flags == (RETRO_NETPACKET_UNSEQUENCED | RETRO_NETPACKET_UNRELIABLE | RETRO_NETPACKET_FLUSH_HINT));
    const auto* p = static_cast<const uint8_t*>(data);
    wire.assign(p, p + size);
    target = slot;
}

struct MpState {
    bool IsReady() const { return true; }
    uint32_t QueueDepth() const { return 7; }
    void SendPacket(const Packet& p, uint16_t diagnosticNativeAid) noexcept;
    manicds::ReplySources _replySources;
    std::optional<uint16_t> _hostId = uint16_t(1);
    void (*_sendFn)(int, const void*, size_t, uint16_t) = send;
};

#ifndef MANIC_DS_SEND_FUNCTION
#define MANIC_DS_SEND_FUNCTION "native_send_function.inc"
#endif
#include MANIC_DS_SEND_FUNCTION

int main() {
    MpState state;
    Packet blank;
    state.SendPacket(blank, 2);
    check(captured.aid == 0 && captured.sourceAid == 2 && captured.sourceSlot == 1 &&
          captured.length == 0 && !captured.payload && captured.depth == 7);
    check(wire == blank.ToBuf() && wire[8] == 0 && target == 1);
    state.SendPacket(blank, 0);
    check(captured.aid == 0 && captured.sourceAid == 0 && wire == blank.ToBuf() && target == 1);
    Packet reply;
    reply.aid = 1;
    reply.length = 40;
    reply.bytes.fill(0x51);
    state.SendPacket(reply, 1);
    check(captured.aid == 1 && captured.sourceAid == 1 && captured.length == 40 &&
          wire == reply.ToBuf() && target == 1);
    Packet command;
    command.type = Packet::Cmd;
    command.length = 40;
    state.SendPacket(command, 2);
    check(captured.packetType == 2 && captured.aid == 0 && captured.sourceAid == 2 &&
          captured.sourceSlot == 65535 && wire == command.ToBuf() && target == 65535);
    std::printf("{\"checks\":%u,\"actual_send_function\":true,\"wire_bytes_unchanged\":true,"
                "\"native_aid_unchanged\":true,\"private_inputs\":false}\n", checks);
}
