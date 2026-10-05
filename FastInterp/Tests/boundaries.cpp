// Copyright 2026 Manic integration contributors
// Licensed under GPLv2 or any later version.
#include <cassert>
#include <iostream>
#include <memory>
#include "core/arm/fastinterp/fastinterp_cache.h"
#include "core/arm/fastinterp/fastinterp_flags.h"

int main() {
    using namespace Core::FastInterp;
    auto cache = std::make_unique<BlockCache>();
    bool hit = true;
    auto* first = cache->LookupOrAllocate(0x1000, hit);
    assert(!hit);
    first->start_pc = 0x1000;
    first->end_pc = 0x1020;
    first->inst_count = 3;
    assert(cache->Lookup(0x1000) == first);
    auto* next = cache->LookupOrAllocate(0x2000, hit);
    next->start_pc = 0x2000;
    next->end_pc = 0x2020;
    next->inst_count = 3;
    next->chain_target = first;
    cache->InvalidateRange(0x101c, 4);
    assert(cache->Lookup(0x1000) == nullptr);
    assert(first->inst_count == 0);
    assert(cache->Lookup(0x2000) == next);
    // An existing chain pointer must fizzle after its target is invalidated.
    assert(next->chain_target->inst_count == 0);
    cache->Clear();
    assert(cache->Lookup(0x2000) == nullptr);
    assert(next->chain_target == nullptr);
    std::cout << "FastInterp actual cache boundary tests passed; game scene not tested\n";
}
