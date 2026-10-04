// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include "../Core/DiagnosticRing.hpp"
// Called only on the emulator thread at a bounded snapshot cadence. Disk work
// is dispatched later. This never reads guest RAM, battery files or ROMs.
static NSArray *diagnosticRecords(const manicds::DiagnosticRing& ring){
    NSMutableArray *records=[NSMutableArray arrayWithCapacity:ring.size()];
    for(size_t i=0;i<ring.size();++i){const auto& r=ring.at(i);const auto& t=r.native;
        NSData *payload=[NSData dataWithBytes:r.payload.data() length:t.length];
        [records addObject:@{@"sequence":@(r.sequence),@"wall_us":@(r.wallMicros),@"event":@(t.event),
            @"timestamp":@(t.timestamp),@"reference_timestamp":@(t.referenceTimestamp),@"aidmask":@(t.aidmask),
            @"payloadmask":@(t.payloadmask),@"answeredmask":@(t.answeredmask),@"aid":@(t.aid),
            @"source_aid":@(t.sourceAid),@"source_slot":@(t.sourceSlot),@"length":@(t.length),
            @"queue_depth":@(t.depth),@"packet_type":@(t.packetType),@"reason":@(t.reason),
            @"payload_base64":[payload base64EncodedStringWithOptions:0]}];
    }return records;
}
