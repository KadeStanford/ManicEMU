// Bounded synthetic API reproduction; no game, firmware, save or phone input.
#define MDS_RF_TESTING 1
#import <Foundation/Foundation.h>
#include <cstring>
#include "../iOS/LocalRF.h"
#include <thread>
#include <chrono>
#include <functional>
#include <stdexcept>
static void waitUntil(std::function<bool()> condition){
    for(unsigned i=0;i<400;i++){if(condition())return;std::this_thread::sleep_for(std::chrono::milliseconds(5));}
    throw std::runtime_error("bounded synthetic networking timeout");
}
static NSDictionary *trial(bool plain){
    rfProbePlain=plain;std::mutex mutex;__block NSDictionary *setupA=nil,*setupB=nil;unsigned arrivals=0,validClocks=0;
    auto received=[&](uint64_t ip,uint64_t callback){std::lock_guard<std::mutex> guard(mutex);arrivals++;validClocks+=ip&&callback>=ip;};
    MDSLocalRF *a=[[MDSLocalRF alloc]initWithSetup:^(NSString *nonce,NSDictionary *metadata){(void)nonce;std::lock_guard<std::mutex> guard(mutex);setupA=metadata;}
        receive:^(NSString *nonce,NSData *data,uint64_t ip,uint64_t callback){(void)nonce;(void)data;received(ip,callback);}];
    MDSLocalRF *b=[[MDSLocalRF alloc]initWithSetup:^(NSString *nonce,NSDictionary *metadata){(void)nonce;std::lock_guard<std::mutex> guard(mutex);setupB=metadata;}
        receive:^(NSString *nonce,NSData *data,uint64_t ip,uint64_t callback){(void)nonce;(void)data;received(ip,callback);}];
    [a add:@"B"];[b add:@"A"];waitUntil([&]{std::lock_guard<std::mutex> guard(mutex);return setupA&&setupB;});
    [a connect:@"B" metadata:setupB];[b connect:@"A" metadata:setupA];
    waitUntil([&]{return [[a metrics][@"ready_peers"] unsignedIntValue]==1&&[[b metrics][@"ready_peers"] unsignedIntValue]==1;});
    uint8_t bytes[73]{};memcpy(bytes,"MDR1",4);NSData *packet=[NSData dataWithBytes:bytes length:sizeof(bytes)];
    if(![a send:packet peer:@"B"]||![b send:packet peer:@"A"])throw std::runtime_error("synthetic datagram not admitted");
    waitUntil([&]{std::lock_guard<std::mutex> guard(mutex);return arrivals==2;});
    waitUntil([&]{return [[a metrics][@"send_completion_samples"] unsignedIntValue]==1&&[[b metrics][@"send_completion_samples"] unsignedIntValue]==1;});
    NSDictionary *result=@{@"plain":@(plain),@"arrivals":@(arrivals),@"ordered_ip_clocks":@(validClocks),@"A":[a metrics],@"B":[b metrics]};
    [a stop];[b stop];return result;
}
int main(int argc,const char *argv[]){@autoreleasepool{
    if(argc!=2)return 2;NSMutableDictionary *report=[NSMutableDictionary new];
    try{report[@"dtls"]=trial(false);report[@"plain"]=trial(true);}
    catch(const std::exception &error){report[@"error"]=[NSString stringWithUTF8String:error.what()];}
    {std::lock_guard<std::mutex> guard(rfProbeMutex);report[@"receive_contexts"]=[rfProbeReceives copy]?:@[];report[@"parameters"]=[rfProbeParameters copy]?:@[];}
    report[@"platform"]=@"macOS public Network.framework";report[@"private_inputs"]=@NO;
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    return json&&[json writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES]&&!report[@"error"]?0:1;
}}
