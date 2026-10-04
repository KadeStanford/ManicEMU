// Proposed replacement for Platform::MP_RecvReplies in src/libretro/libretro.cpp.
// Include net/manic_reply_collector.hpp above. This is also compiled unchanged
// by the focused stub regression test; the real Core supplies the packet queue.
#include "ReceiveDeadline.hpp"
u16 Platform::MP_RecvReplies(u8* packets, u64 timestamp, u16 aidmask, void*) {
    if (!MelonDsDs::Core.MpActive()) return 0;
    manicds::ReplyCollector replies(timestamp, aidmask);
    manicds::ReceiveDeadline budget(25);
    while (!replies.complete()) {
        const auto remaining = budget.nextWaitMicros(25000);
        if (!remaining) break;
        auto packet = MelonDsDs::Core.MpNextPacketBlock(remaining);
        if (!packet.has_value()) break;
        const auto& p = *packet;
        if (p.PacketType() != MelonDsDs::Packet::Type::Reply) continue;
        replies.accept(p.Timestamp(), p.Aid(), p.SourceAid(), p.Data(),
                       p.Length(), packets);
    }
    return replies.payloads();
}
