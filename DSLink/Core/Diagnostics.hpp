// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#include <cstddef>
#include <cstdint>
namespace manicds {
constexpr unsigned DiagnosticEnvironment = 0x4d445304;
enum class DiagnosticEvent : uint32_t {
    Send = 1, Receive = 2, ReplyRequest = 3, ReplyCandidate = 4,
    ReplyResult = 5, HostReceive = 6, Timeout = 7, Dequeued = 8
};
// ARM64/x64 ABI. The frontend copies any bounded payload immediately, never
// retains this pointer, and keeps captured user data local to the device/PC.
struct NativeDiagnostic {
    uint32_t version = 1, event = 0;
    uint64_t timestamp = 0, referenceTimestamp = 0;
    uint32_t aidmask = 0, payloadmask = 0, answeredmask = 0;
    // Send sourceAid is the native sender's read-only W_AIDLow register;
    // Receive/candidate sourceAid is the source association learned by MpState.
    uint32_t aid = 0, sourceAid = 0, sourceSlot = 65535;
    uint32_t length = 0, depth = 0, packetType = 3, reason = 0;
    const void* payload = nullptr;
};
static_assert(offsetof(NativeDiagnostic, timestamp) == 8, "Trace timestamp ABI");
static_assert(offsetof(NativeDiagnostic, aidmask) == 24, "Trace mask ABI");
static_assert(offsetof(NativeDiagnostic, sourceSlot) == 44, "Trace source ABI");
static_assert(offsetof(NativeDiagnostic, payload) == 64, "Trace payload ABI");
static_assert(sizeof(void*) != 8 || sizeof(NativeDiagnostic) == 72, "Trace size ABI");
template<class Packet>
NativeDiagnostic packetDiagnostic(DiagnosticEvent event, const Packet& packet,
                                  uint32_t source, uint32_t depth) {
    NativeDiagnostic value;
    value.event = uint32_t(event); value.timestamp = packet.Timestamp();
    value.aid = packet.Aid(); value.sourceAid = packet.SourceAid();
    value.sourceSlot = source; value.depth = depth;
    const auto type = unsigned(packet.PacketType());
    value.packetType = type == 0 ? 1 : type == 1 ? 2 : 0;
    if (packet.Length() <= 2048) {
        value.length = uint32_t(packet.Length());
        value.payload = value.length ? packet.Data() : nullptr;
    }
    return value;
}
}
