// Experimental, disabled by default. Included only in libretro.cpp.
// The same ReplyCollector enforces genuine source/AID/timestamp/payload rules.
// Bit0 (never a native client AID) means the transaction is still pending.
#include <optional>
#include <chrono>
namespace manicds {
inline bool AsyncRadioEnabled = false;
struct AsyncExchange {
    u8* buffer; u64 timestamp; u16 mask;
    ReplyCollector replies;
    std::chrono::steady_clock::time_point deadline, nextPoll;
    AsyncExchange(u8* data,u64 time,u16 aidmask)
        : buffer(data),timestamp(time),mask(aidmask),replies(time,aidmask),
          // Isolated experiment: tolerate frame-paced polls and the captured
          // 110.8ms tail while CPU/audio continue. Never a blocking wait.
          deadline(std::chrono::steady_clock::now()+std::chrono::milliseconds(125)),nextPoll{} {}
};
inline std::optional<AsyncExchange> AsyncReply;
inline std::chrono::steady_clock::time_point AsyncHostPoll{};
inline void CancelAsync() { AsyncReply.reset(); AsyncHostPoll={}; }
inline void AsyncSignal(uint32_t number) {
    struct Event { uint32_t event; uint32_t reserved; const void* packet; } event{number,0,nullptr};
    retro::environment(0x4d445301,&event);
}
u16 AsyncReceiveReplies(u8* packets,u64 timestamp,u16 aidmask) {
    if(!MelonDsDs::Core.MpActive()){CancelAsync();return 0;}
    if(!AsyncReply || AsyncReply->buffer!=packets || AsyncReply->timestamp!=timestamp || AsyncReply->mask!=aidmask){
        CancelAsync();AsyncReply.emplace(packets,timestamp,aidmask);AsyncSignal(30);
        NativeDiagnostic trace;trace.event=uint32_t(DiagnosticEvent::ReplyRequest);
        trace.timestamp=timestamp;trace.aidmask=aidmask;trace.depth=MelonDsDs::Core.MpQueueDepth();
        retro::environment(DiagnosticEnvironment,&trace);
    }
    auto& state=*AsyncReply;const auto now=std::chrono::steady_clock::now();
    // A conservative hard deadline: no newly polled reply is accepted after
    // expiry. This 125ms prototype window is not enabled in a production build.
    if(!state.replies.complete() && now<state.deadline && now>=state.nextPoll){
        state.nextPoll=now+std::chrono::microseconds(500);
        auto packet=MelonDsDs::Core.MpNextPacketBlock(0); // flush/poll, zero wait
        for(unsigned count=0;packet&&count<256&&!state.replies.complete();++count){
            const auto& p=*packet;
            if(p.PacketType()==MelonDsDs::Packet::Type::Reply){
                state.replies.accept(p.Timestamp(),p.Aid(),p.SourceAid(),p.Data(),p.Length(),packets);
                AsyncSignal(uint32_t(state.replies.lastResult()));
                auto trace=packetDiagnostic(DiagnosticEvent::ReplyCandidate,p,p.SourceSlot(),MelonDsDs::Core.MpQueueDepth());
                trace.referenceTimestamp=timestamp;trace.aidmask=aidmask;
                trace.payloadmask=state.replies.payloads();trace.answeredmask=state.replies.answered();
                trace.reason=uint32_t(state.replies.lastResult());retro::environment(DiagnosticEnvironment,&trace);
            }
            if(state.replies.complete())break;
            packet=MelonDsDs::Core.MpNextPacket();
        }
    }
    if(!state.replies.complete() && std::chrono::steady_clock::now()<state.deadline)return 1;
    NativeDiagnostic trace;trace.event=uint32_t(DiagnosticEvent::ReplyResult);
    trace.timestamp=timestamp;trace.aidmask=aidmask;trace.payloadmask=state.replies.payloads();
    trace.answeredmask=state.replies.answered();trace.depth=MelonDsDs::Core.MpQueueDepth();
    trace.reason=state.replies.complete()?32:33;retro::environment(DiagnosticEnvironment,&trace);
    AsyncSignal(trace.reason);AsyncSignal(31);const u16 result=state.replies.payloads();
    AsyncReply.reset();return result;
}
std::optional<MelonDsDs::Packet> AsyncReceiveHost() {
    const auto now=std::chrono::steady_clock::now();
    if(now<AsyncHostPoll)return std::nullopt;
    AsyncHostPoll=now+std::chrono::microseconds(500);
    return MelonDsDs::Core.MpNextPacketBlock(0);
}
}
