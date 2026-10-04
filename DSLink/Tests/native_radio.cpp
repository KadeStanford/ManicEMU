// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic native RF bytes only; no cartridges, firmware or saves.
#include "../Core/RadioFragments.hpp"
#include <cstdio>
#include <cstdlib>
using namespace manicds;
static unsigned checks = 0;
static void check(bool value) {
    ++checks;
    if (!value) { std::fprintf(stderr, "native radio check %u failed\n", checks); std::exit(1); }
}
static Bytes payload(size_t size) {
    Bytes p(size);
    for (size_t i = 0; i < size; ++i) p[i] = uint8_t(i * 17 + 31);
    p[8] = 0; p[9] = size == 10 ? 1 : 0;
    return p;
}
struct Pair {
    Nonce left{}, right{};
    NativeRadioEdge a, b;
    RadioFragments fragments;
    Pair() : a(left, nonce()), b(nonce(), left) {
        check(a.localRadio(1, true) && a.peerRadio(1, true));
        check(b.localRadio(1, true) && b.peerRadio(1, true));
    }
    static Nonce nonce() { Nonce n{}; n[0] = 1; return n; }
    void roundtrip(size_t size, bool reverse) {
        const auto original = payload(size);
        const auto wire = a.encode(original.data(), original.size());
        auto pieces = RadioFragments::split(wire);
        check(!pieces.empty());
        if (reverse) std::reverse(pieces.begin(), pieces.end());
        for (const auto& piece : pieces) {
            check(piece.size() <= RadioFragments::MaxMessage);
            check(!std::memcmp(piece.data(), wire.data(), NativeRadioEdge::Header));
            check(fragments.receive(piece.data(), piece.size(), b));
        }
        Bytes envelope, received;
        check(fragments.pop(envelope, b) && envelope == wire);
        check(b.receive(envelope.data(), envelope.size()));
        check(b.pop(received) && received == original);
        check(!fragments.pop(envelope, b));
    }
};
int main() {
    Pair pair;
    pair.roundtrip(10, false); pair.roundtrip(100, false);
    pair.roundtrip(MaxPacket, false); pair.roundtrip(MaxPacket, true);
    Bytes envelope, received;
    auto maximum = payload(MaxPacket), small = payload(10);
    auto incompleteWire = pair.a.encode(maximum.data(), maximum.size());
    auto pieces = RadioFragments::split(incompleteWire);
    check(pieces.size() == 3);
    const auto now = RadioFragments::Clock::now();
    check(pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b, now));
    check(pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b, now));
    check(pair.fragments.duplicateCount() == 1);
    check(pair.fragments.incompleteCount() == 1 && !pair.fragments.pop(envelope, pair.b));
    pair.roundtrip(10, false); // The missing middle/end fragment cannot block later RF.
    check(pair.fragments.incompleteCount() == 1);
    pair.fragments.expire(now + std::chrono::milliseconds(101));
    check(pair.fragments.incompleteCount() == 0);

    auto wire = pair.a.encode(maximum.data(), maximum.size());
    pieces = RadioFragments::split(wire);
    check(pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b));
    auto modified = pieces[1]; modified[8] ^= 1; // wrong pair
    check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    modified = pieces[1]; modified[5] ^= 1; // wrong source
    check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    modified = pieces[1]; modified[47] ^= 1; // wrong sender epoch
    check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    modified = pieces[1]; modified[63] ^= 1; // wrong receiver epoch
    check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    modified = pieces[1]; modified[7] -= 1; // Valid chunk bounds, inconsistent full length.
    check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    modified = pieces[1]; modified[55] += 1; // another sequence cannot complete original
    check(pair.fragments.receive(modified.data(), modified.size(), pair.b));
    check(!pair.fragments.pop(envelope, pair.b));
    modified = pieces[0]; modified.back() ^= 1; // conflicting duplicate cannot overwrite
    check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    check(pair.fragments.receive(pieces[1].data(), pieces[1].size(), pair.b));
    check(pair.fragments.receive(pieces[2].data(), pieces[2].size(), pair.b));
    check(pair.fragments.pop(envelope, pair.b) && envelope == wire);
    check(pair.b.receive(envelope.data(), envelope.size()) && pair.b.pop(received) && received == maximum);
    for (const auto& piece : pieces) check(!pair.fragments.receive(piece.data(), piece.size(), pair.b));

    for (unsigned field : {64u, 65u, 66u, 67u, 68u, 69u, 70u, 71u}) {
        modified = pieces[0]; modified[field] ^= 0xff;
        check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    }
    check(!pair.fragments.receive(pieces[0].data(), pieces[0].size() - 1, pair.b));
    modified = pieces[0]; modified.push_back(0);
    check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    modified = pieces[0]; modified[6] = 0; modified[7] = 9;
    check(!pair.fragments.receive(modified.data(), modified.size(), pair.b));
    check(!pair.fragments.receive(nullptr, 100, pair.b));
    pair.fragments.reset();
    check(pair.fragments.incompleteCount() == 0 && pair.fragments.queued() == 0);

    // Valid fragment headers cannot make an invalid assembled RF payload valid.
    wire = pair.a.encode(maximum.data(), maximum.size()); pieces = RadioFragments::split(wire);
    pieces[0][RadioFragments::Header + 8] = 16;
    check(pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b));
    check(pair.fragments.receive(pieces[1].data(), pieces[1].size(), pair.b));
    check(!pair.fragments.receive(pieces[2].data(), pieces[2].size(), pair.b));
    check(!pair.fragments.pop(envelope, pair.b) && pair.fragments.incompleteCount() == 0);

    // Bound incomplete packets while still making room for later complete RF.
    for (size_t i = 0; i < RadioFragments::MaxIncomplete + 3; ++i) {
        wire = pair.a.encode(maximum.data(), maximum.size());
        pieces = RadioFragments::split(wire);
        check(pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b, now));
        check(pair.fragments.incompleteCount() <= RadioFragments::MaxIncomplete);
    }
    check(pair.fragments.incompleteCount() == RadioFragments::MaxIncomplete);
    pair.roundtrip(MaxPacket, true);
    pair.fragments.expire(now + std::chrono::milliseconds(101));
    check(pair.fragments.incompleteCount() == 0);

    // Completed reassembly queue and native payload queue are both finite.
    for (size_t i = 0; i < MaxQueue; ++i) {
        wire = pair.a.encode(small.data(), small.size()); pieces = RadioFragments::split(wire);
        check(pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b));
    }
    wire = pair.a.encode(small.data(), small.size()); pieces = RadioFragments::split(wire);
    check(!pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b));
    check(pair.fragments.queued() == MaxQueue);
    pair.fragments.reset();
    for (size_t i = 0; i < MaxQueue; ++i) {
        wire = pair.a.encode(small.data(), small.size());
        check(pair.b.receive(wire.data(), wire.size()));
    }
    wire = pair.a.encode(small.data(), small.size());
    check(!pair.b.receive(wire.data(), wire.size()) && pair.b.queued() == MaxQueue);
    pair.b.discardIncoming();

    // Radio transitions clear incomplete and queued full RF and reject old epochs.
    auto oldWire = pair.a.encode(maximum.data(), maximum.size()); pieces = RadioFragments::split(oldWire);
    check(pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b));
    auto oldSmall = pair.a.encode(small.data(), small.size()); auto oldSmallPieces = RadioFragments::split(oldSmall);
    check(pair.fragments.receive(oldSmallPieces[0].data(), oldSmallPieces[0].size(), pair.b));
    check(pair.b.localRadio(1, false));
    check(!pair.fragments.pop(envelope, pair.b));
    check(pair.fragments.incompleteCount() == 0 && pair.fragments.queued() == 0);
    check(!pair.b.localRadio(1, true)); check(pair.b.localRadio(2, true));
    check(!pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b));
    check(pair.a.peerRadio(2, true)); pair.roundtrip(MaxPacket, true);
    auto oldSource = pair.a.encode(small.data(), small.size());
    check(pair.a.localRadio(1, false)); check(!pair.a.localRadio(1, true));
    check(pair.a.localRadio(2, true)); check(pair.b.peerRadio(2, true));
    pieces = RadioFragments::split(oldSource);
    check(!pair.fragments.receive(pieces[0].data(), pieces[0].size(), pair.b));
    pair.roundtrip(10, false);

    // Unsequenced loss/reorder and replay bounds operate on complete native RF.
    auto first = pair.a.encode(small.data(), small.size());
    auto second = pair.a.encode(small.data(), small.size());
    auto third = pair.a.encode(small.data(), small.size());
    check(pair.b.receive(third.data(), third.size()));
    check(pair.b.receive(first.data(), first.size()));
    check(!pair.b.receive(third.data(), third.size()));
    check(pair.b.receive(second.data(), second.size()));
    while (pair.b.pop(received)) check(received == small);
    for (unsigned i = 0; i < 70; ++i) {
        wire = pair.a.encode(small.data(), small.size());
        check(pair.b.receive(wire.data(), wire.size()) && pair.b.pop(received));
    }
    check(!pair.b.receive(first.data(), first.size()));

    // Actual production reliable controls do not depend on RF delivery/order.
    Protocol controlA(pair.left, "IPKE", 0), controlB(Pair::nonce(), "IPGE", 0);
    controlA.radio(true); controlB.radio(true);
    check(controlA.bind(Pair::nonce(), "IPGE", 0) && controlB.bind(pair.left, "IPKE", 0));
    auto pump = [&] {
        for (unsigned i = 0; i < 8; ++i) {
            for (const auto& frame : controlA.takeWire()) check(controlB.receive(frame.data(), frame.size()));
            for (const auto& frame : controlB.takeWire()) check(controlA.receive(frame.data(), frame.size()));
        }
    };
    pump(); check(controlA.paired() && controlB.paired());
    controlA.hold(true); pump(); check(controlB.paused());
    controlA.hold(false); pump(); check(!controlB.paused());
    controlA.radio(false); controlB.radio(false); pump(); check(controlA.bothOff() && controlB.bothOff());
    controlA.close(); controlB.close(); pump();
    check(controlA.phase() == Phase::Ended && controlB.phase() == Phase::Ended);
    std::printf("{\"checks\":%u,\"max_carrier_message_bytes\":%zu,\"physical_phone_verified\":false}\n",
        checks, RadioFragments::MaxMessage);
}
