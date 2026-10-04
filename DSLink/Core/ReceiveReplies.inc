// Proposed replacement for Platform::MP_RecvReplies in src/libretro/libretro.cpp.
// Include net/manic_reply_collector.hpp above. This is also compiled unchanged
// by the focused stub regression test; the real Core supplies the packet queue.
#include "ReceiveDeadline.hpp"
#include "Diagnostics.hpp"
u16 Platform::MP_RecvReplies(u8* packets, u64 timestamp, u16 aidmask, void*) {
    if (!MelonDsDs::Core.MpActive()) return 0;
    auto signal = [](uint32_t number) {
        struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{number,0,nullptr};
        retro::environment(0x4d445301, &event);
    };
    signal(30);
    manicds::ReplyCollector replies(timestamp, aidmask);
    manicds::NativeDiagnostic request;
    request.event = uint32_t(manicds::DiagnosticEvent::ReplyRequest);
    request.timestamp = timestamp; request.aidmask = aidmask;
    request.depth = MelonDsDs::Core.MpQueueDepth();
    retro::environment(manicds::DiagnosticEnvironment,&request);
    auto accept = [&](const MelonDsDs::Packet& p) {
        replies.accept(p.Timestamp(),p.Aid(),p.SourceAid(),p.Data(),p.Length(),packets);
        signal(uint32_t(replies.lastResult()));
        auto trace = manicds::packetDiagnostic(manicds::DiagnosticEvent::ReplyCandidate,p,p.SourceSlot(),MelonDsDs::Core.MpQueueDepth());
        trace.referenceTimestamp = timestamp; trace.aidmask = aidmask;
        trace.payloadmask = replies.payloads(); trace.answeredmask = replies.answered();
        trace.reason = uint32_t(replies.lastResult());
        retro::environment(manicds::DiagnosticEnvironment,&trace);
    };
    manicds::ReceiveDeadline budget(25);
    while (!replies.complete()) {
        const auto remaining = budget.nextWaitMicros(25000);
        if (!remaining) break;
        auto packet = MelonDsDs::Core.MpNextPacketBlock(remaining);
        if (!packet.has_value()) break;
        const auto& p = *packet;
        if (p.PacketType() != MelonDsDs::Packet::Type::Reply) continue;
        accept(p);
    }
    // The last blocking call may return unrelated traffic while a valid reply
    // is already queued behind it. Drain only currently available packets with
    // a fixed bound and no more waits; preserve all native reply constraints.
    for (unsigned drained = 0; drained < 256 && !replies.complete(); ++drained) {
        auto packet = MelonDsDs::Core.MpNextPacket();
        if (!packet.has_value()) break;
        const auto& p = *packet;
        if (p.PacketType() != MelonDsDs::Packet::Type::Reply) continue;
        accept(p);
    }
    manicds::NativeDiagnostic result;
    result.event = uint32_t(manicds::DiagnosticEvent::ReplyResult);
    result.timestamp = timestamp; result.aidmask = aidmask;
    result.payloadmask = replies.payloads(); result.answeredmask = replies.answered();
    result.depth = MelonDsDs::Core.MpQueueDepth();
    result.reason = replies.complete() ? 32 : 33;
    retro::environment(manicds::DiagnosticEnvironment,&result);
    signal(replies.complete() ? 32 : 33);
    signal(31);
    return replies.payloads();
}
