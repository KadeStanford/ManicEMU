// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include <cstdint>
#include <cstring>
struct MDSGeneratedConsole {uint32_t version;uint8_t mac[6];uint8_t reserved[2];};
static bool generatedConsole(MDSGeneratedConsole *request){
    if(!request||request->version!=1||request->reserved[0]||request->reserved[1])return false;
    NSString *key=@"ManicDSLocalConsoleMAC_v1";
    id value=[NSUserDefaults.standardUserDefaults objectForKey:key];
    NSData *stored=[value isKindOfClass:NSData.class]?value:nil;
    uint8_t mac[6]{};
    if(stored.length==6)std::memcpy(mac,stored.bytes,6);
    bool valid=mac[0]==0&&mac[1]==9&&mac[2]==191&&(mac[3]||mac[4]||mac[5])&&
        !(mac[3]==17&&mac[4]==34&&mac[5]==51);
    if(!valid){
        uint8_t random[16];[NSUUID.UUID getUUIDBytes:random];
        mac[0]=0;mac[1]=9;mac[2]=191;std::memcpy(mac+3,random+13,3);
        if(!(mac[3]||mac[4]||mac[5])||(mac[3]==17&&mac[4]==34&&mac[5]==51))mac[5]^=1;
        [NSUserDefaults.standardUserDefaults setObject:[NSData dataWithBytes:mac length:6] forKey:key];
    }
    std::memcpy(request->mac,mac,6);return true;
}
