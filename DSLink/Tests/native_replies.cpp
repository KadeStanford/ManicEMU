// Compile the proposed native MP_RecvReplies function unchanged against a
// small queue stub. No ROM, firmware, save, network or simulator is used.
#include "ReplyCollector.hpp"
#include "Protocol.hpp"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <optional>
#include <vector>
#include <thread>
using u8 = uint8_t; using u16 = uint16_t; using u64 = uint64_t;
namespace MelonDsDs {
class Packet {
public:
    enum Type { Reply, Cmd, Other };
    Packet(uint64_t timestamp, int aid, int sourceAid, size_t size,
           Type type = Reply, int fill = 0x51)
        : timestamp_(timestamp), aid_(uint8_t(aid)), sourceAid_(uint8_t(sourceAid)), type_(type),
          data_(size, uint8_t(fill)) {}
    uint64_t Timestamp() const { return timestamp_; }
    uint8_t Aid() const { return aid_; }
    uint8_t SourceAid() const { return sourceAid_; }
    Type PacketType() const { return type_; }
    const void* Data() const { return data_.empty() ? nullptr : data_.data(); }
    size_t Length() const { return data_.size(); }
private:
    uint64_t timestamp_; uint8_t aid_, sourceAid_; Type type_;
    std::vector<uint8_t> data_;
};
struct CoreStub {
    bool active = true; unsigned calls = 0, timeouts = 0;
    bool unrelatedTraffic = false;
    std::vector<uint32_t> budgets;
    std::deque<Packet> queue;
    bool MpActive() const { return active; }
    std::optional<Packet> MpNextPacketBlock(uint32_t maximumWaitMicros) {
        ++calls;budgets.push_back(maximumWaitMicros);
        if(unrelatedTraffic) {std::this_thread::sleep_for(std::chrono::milliseconds(5));return Packet(1000,0,0,40,Packet::Cmd);}
        if (queue.empty()) { ++timeouts; return std::nullopt; }
        auto p = std::move(queue.front()); queue.pop_front(); return p;
    }
} Core;
}
namespace Platform { u16 MP_RecvReplies(u8*, u64, u16, void*); }
#include "../Core/ReceiveReplies.inc"
static unsigned checks = 0;
static void check(bool value) {
    ++checks; if (!value) { std::fprintf(stderr, "check %u failed\n", checks); std::exit(1); }
}
int main() {
    using MelonDsDs::Packet; using MelonDsDs::Core;
    std::array<u8, 15 * 1024 + 32> storage;
    auto reset = [&] { Core = {}; storage.fill(0xa5); };
    auto run = [&](u64 timestamp, u16 mask) {
        return Platform::MP_RecvReplies(storage.data() + 16, timestamp, mask, nullptr);
    };
    auto guard = [&] {
        for (size_t i = 0; i < 16; ++i) check(storage[i] == 0xa5);
        for (size_t i = storage.size() - 16; i < storage.size(); ++i) check(storage[i] == 0xa5);
    };
    reset(); Core.queue.emplace_back(1000, 0, 1, 0);
    check(run(1000, 2) == 0); check(Core.calls == 1 && Core.timeouts == 0);
    for (auto b : storage) check(b == 0xa5); // No fabricated payload or negative index.

    reset(); Core.queue.emplace_back(1000, 0, 0, 0); // Unknown source cannot count.
    Core.queue.emplace_back(1000, 1, 1, 40);
    check(run(1000, 2) == 2); check(Core.calls == 2 && Core.timeouts == 0); guard();

    reset(); Core.queue.emplace_back(1000, 0, 3, 0); // Known bystander, wrong expected AID.
    Core.queue.emplace_back(1000, 0, 1, 0);
    Core.queue.emplace_back(1000, 0, 1, 0); // Duplicate cannot answer twice.
    Core.queue.emplace_back(1000, 2, 2, 40, Packet::Reply, uint8_t(0x72));
    check(run(1000, 6) == 4); check(Core.calls == 4 && Core.timeouts == 0);
    check(storage[16] == 0xa5 && storage[16 + 1024] == 0x72); guard();

    reset(); Core.queue.emplace_back(967, 1, 1, 40); // timestamp - 32 boundary.
    Core.queue.emplace_back(967, 0, 1, 0);
    Core.queue.emplace_back(968, 1, 1, 40);
    check(run(1000, 2) == 2); check(Core.calls == 3); guard();

    reset(); Core.queue.emplace_back(5, 1, 1, 40);
    check(run(10, 2) == 2); check(Core.timeouts == 0); // No unsigned underflow.
    guard();

    reset(); Core.queue.emplace_back(1000, 0, 1, 40);
    Core.queue.emplace_back(1000, 16, 16, 40);
    Core.queue.emplace_back(1000, 1, 1, 35);
    Core.queue.emplace_back(1000, 1, 2, 40);
    Core.queue.emplace_back(1000, 1, 1, 2049);
    check(run(1000, 2) == 0); check(Core.calls == 6 && Core.timeouts == 1);
    for (auto b : storage) check(b == 0xa5);

    reset(); Core.queue.emplace_back(1000, 1, 1, 40, Packet::Cmd);
    Core.queue.emplace_back(1000, 15, 15, 2048);
    check(run(1000, u16(1u << 15)) == u16(1u << 15));
    check(Core.calls == 2); guard();
    for (size_t i = 0; i < 1024; ++i) check(storage[16 + 14 * 1024 + i] == 0x51);

    reset(); Core.active = false; check(run(1000, 2) == 0 && Core.calls == 0);
    reset(); check(run(1000, 0) == 0 && Core.calls == 0);
    reset(); Core.queue.emplace_back(1000, 0, 0, 0);
    check(run(1000, 2) == 0 && Core.timeouts == 1); // Unknown first blank stays conservative.

    manicds::ReplySources sources;
    check(sources.associate(1, 0, 1000, 0) == 0);
    check(sources.associate(1, 1, 1000, 40) == 1);
    check(sources.associate(1, 0, 1000, 0) == 1);
    check(sources.associate(1, 0, 999, 0) == 0);
    check(sources.associate(2, 0, 1000, 0) == 0);
    check(sources.associate(1, 2, 1010, 40) == 2);
    check(sources.associate(1, 1, 1001, 40) == 1);
    check(sources.associate(1, 0, 1011, 0) == 2); // Stale payload cannot revert a learned AID.
    check(sources.associate(1, 0, 1011, 1) == 0);
    check(sources.associate(1, 16, 1011, 40) == 0);
    check(sources.associate(65535, 1, 1011, 40) == 0);
    sources.reset(); check(sources.associate(1, 0, 1012, 0) == 0);
    std::array<uint8_t,46> wire{};wire[9]=1;
    check(manicds::validPacket(wire.data(),10));
    check(!manicds::validPacket(wire.data(),11));
    wire[8]=1;check(!manicds::validPacket(wire.data(),10));
    check(!manicds::validPacket(wire.data(),45));check(manicds::validPacket(wire.data(),46));
    wire[8]=16;check(!manicds::validPacket(wire.data(),46));
    reset();Core.unrelatedTraffic=true;
    const auto start=std::chrono::steady_clock::now();check(run(1000,2)==0);
    const double elapsed=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
    check(elapsed>=20&&elapsed<200&&Core.calls<30&&Core.timeouts==0);
    check(Core.budgets.size()>1&&Core.budgets.front()<=25000);
    for(size_t i=1;i<Core.budgets.size();++i)check(Core.budgets[i]<Core.budgets[i-1]&&Core.budgets[i]>0);
    std::printf("{\"checks\":%u,\"native_receive_function\":true,\"private_inputs\":false,\"physical_phone_verified\":false}\n", checks);
}
