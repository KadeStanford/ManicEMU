// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>

// Presence only: no packet, PSK or save is published and no socket is opened.
// Discovery uses the infrastructure LAN, never peer-to-peer Wi-Fi. Port9 is
// the conventional discard endpoint; it is not used to connect to this record.
static NSString *const MDSLANService=@"_manic-ds-lan._tcp.";
@interface MDSLANPresence:NSObject<NSNetServiceDelegate,NSNetServiceBrowserDelegate>
-(instancetype)initWithMetadata:(NSDictionary*)metadata changed:(void(^)(void))changed;
-(void)start;
-(void)stop;
-(BOOL)available;
-(NSArray<NSDictionary*>*)peers;
@end
@implementation MDSLANPresence {
    NSDictionary *_metadata;
    NSNetService *_announcement;
    NSNetServiceBrowser *_browser;
    NSMutableDictionary<NSString*,NSNetService*> *_services;
    NSMutableDictionary<NSString*,NSDictionary*> *_peers;
    void(^_changed)(void);
    BOOL _started,_published,_browsing;
}
-(instancetype)initWithMetadata:(NSDictionary*)metadata changed:(void(^)(void))changed{
    if((self=[super init])){_metadata=[metadata copy];_changed=[changed copy];
        _services=[NSMutableDictionary new];_peers=[NSMutableDictionary new];}return self;
}
-(void)start{
    if(_started)return;
    if(_metadata.count!=10||![_metadata[@"runtime"] isKindOfClass:NSString.class]||
        ![_metadata[@"lan"] isEqual:@"1"]||![_metadata[@"ready"] isEqual:@"1"]||![_metadata[@"local"] isEqual:@"1"])return;
    _started=YES;
    NSMutableDictionary *txt=[NSMutableDictionary new];
    for(NSString *key in _metadata){NSString *value=_metadata[key];
        if(![value isKindOfClass:NSString.class]||value.length>80){_started=NO;return;}
        txt[key]=[value dataUsingEncoding:NSUTF8StringEncoding];}
    NSData *record=[NSNetService dataFromTXTRecordDictionary:txt];
    if(!record||record.length>1024){_started=NO;return;}
    _announcement=[[NSNetService alloc]initWithDomain:@"local." type:MDSLANService
        name:[@"mds-" stringByAppendingString:_metadata[@"runtime"]] port:9];
    _announcement.includesPeerToPeer=NO;_announcement.delegate=self;
    [_announcement setTXTRecordData:record];[_announcement publish];
    _browser=[NSNetServiceBrowser new];_browser.includesPeerToPeer=NO;_browser.delegate=self;
    [_browser searchForServicesOfType:MDSLANService inDomain:@"local."];
}
-(void)stop{
    _started=_published=_browsing=NO;_announcement.delegate=nil;[_announcement stop];_announcement=nil;
    _browser.delegate=nil;[_browser stop];_browser=nil;
    for(NSNetService *service in _services.allValues){service.delegate=nil;[service stopMonitoring];[service stop];}
    [_services removeAllObjects];[_peers removeAllObjects];_changed=nil;
}
-(BOOL)available{return _started&&_published&&_browsing;}
-(NSArray<NSDictionary*>*)peers{return [_peers.allValues copy];}
-(void)netServiceDidPublish:(NSNetService*)service{
    if(service!=_announcement||!_started)return;_published=YES;if(_changed)_changed();
}
-(void)netService:(NSNetService*)service didNotPublish:(NSDictionary*)error{
    (void)error;if(service!=_announcement)return;_published=NO;if(_changed)_changed();
}
-(void)netServiceBrowserWillSearch:(NSNetServiceBrowser*)browser{
    if(browser!=_browser||!_started)return;_browsing=YES;if(_changed)_changed();
}
-(void)netServiceBrowser:(NSNetServiceBrowser*)browser didNotSearch:(NSDictionary*)error{
    (void)error;if(browser!=_browser)return;_browsing=NO;if(_changed)_changed();
}
-(void)netServiceBrowser:(NSNetServiceBrowser*)browser didFindService:(NSNetService*)service moreComing:(BOOL)more{
    (void)more;if(browser!=_browser||!_started||_services.count>=32||service.name.length>80||
        ![service.name hasPrefix:@"mds-"]||[service.name isEqual:_announcement.name]||_services[service.name])return;
    _services[service.name]=service;service.includesPeerToPeer=NO;service.delegate=self;
    [service startMonitoring];[service resolveWithTimeout:3];
}
-(void)netServiceBrowser:(NSNetServiceBrowser*)browser didRemoveService:(NSNetService*)service moreComing:(BOOL)more{
    (void)more;if(browser!=_browser||_services[service.name]!=service)return;
    service.delegate=nil;[service stopMonitoring];[service stop];
    [_services removeObjectForKey:service.name];[_peers removeObjectForKey:service.name];if(_changed)_changed();
}
-(void)update:(NSNetService*)service record:(NSData*)record{
    if(!_started||_services[service.name]!=service||!record||record.length>1024)return;
    NSDictionary *txt=[NSNetService dictionaryFromTXTRecordData:record];
    NSArray *keys=@[@"v",@"code",@"rev",@"nonce",@"runtime",@"ready",@"local",@"mac",@"alias",@"lan"];
    if(txt.count!=keys.count)return;
    NSMutableDictionary *info=[NSMutableDictionary new];
    for(NSString *key in keys){NSData *value=txt[key];if(![value isKindOfClass:NSData.class]||!value.length||value.length>80)return;
        NSString *text=[[NSString alloc]initWithData:value encoding:NSUTF8StringEncoding];if(!text)return;info[key]=text;}
    if(![info[@"lan"] isEqual:@"1"]||![service.name isEqual:[@"mds-" stringByAppendingString:info[@"runtime"]]])return;
    _peers[service.name]=info;if(_changed)_changed();
}
-(void)netServiceDidResolveAddress:(NSNetService*)service{[self update:service record:service.TXTRecordData];}
-(void)netService:(NSNetService*)service didUpdateTXTRecordData:(NSData*)record{[self update:service record:record];}
@end
