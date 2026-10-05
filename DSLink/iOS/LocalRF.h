// SPDX-License-Identifier: AGPL-3.0-or-later
#pragma once
#import <Network/Network.h>
#import <Security/Security.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <mutex>
#include <vector>

// RF only. Discovery, admission and lifecycle fences still use the encrypted
// MCSession. Each admitted peer gets a fresh DTLS PSK/listener. Keys travel only
// over that session, never in Bonjour, traces, preferences or save files.
// A failed/unavailable LAN path retains the existing MCSession RF carrier.
@interface MDSRFPeer : NSObject
@property(strong) nw_listener_t listener;
@property(strong) nw_connection_t outgoing;
@property(strong) NSMutableArray *candidates;
@property(strong) NSMutableArray *incoming;
@property(strong) NSData *key;
@property(copy) NSString *nonce;
@property(copy) NSDictionary *remote;
@property BOOL ready,stopped;
@property unsigned pending;
@end
@implementation MDSRFPeer
@end

static NSArray<NSDictionary*> *rfInterfaces(){
#ifdef MDS_RF_TESTING
    return @[@{@"ip":@"127.0.0.1",@"mask":@(0xffffff00u)}];
#else
    NSMutableArray *out=[NSMutableArray new];struct ifaddrs *list=nullptr;
    if(getifaddrs(&list))return out;
    for(auto *p=list;p&&out.count<4;p=p->ifa_next){
        if(!p->ifa_addr||!p->ifa_netmask||p->ifa_addr->sa_family!=AF_INET||
           !(p->ifa_flags&IFF_UP)||!(p->ifa_flags&IFF_RUNNING)||(p->ifa_flags&IFF_LOOPBACK)||
           (strncmp(p->ifa_name,"en",2)&&strncmp(p->ifa_name,"bridge",6)))continue;
        auto address=reinterpret_cast<sockaddr_in*>(p->ifa_addr)->sin_addr;
        auto mask=reinterpret_cast<sockaddr_in*>(p->ifa_netmask)->sin_addr;
        char text[INET_ADDRSTRLEN]{};if(!inet_ntop(AF_INET,&address,text,sizeof(text)))continue;
        [out addObject:@{@"ip":[NSString stringWithUTF8String:text],@"mask":@(ntohl(mask.s_addr))}];
    }
    freeifaddrs(list);return out;
#endif
}
static bool rfLocalAddress(NSString *text,NSArray *interfaces){
    if(![text isKindOfClass:NSString.class]||text.length>15)return false;
    in_addr raw{};if(inet_pton(AF_INET,text.UTF8String,&raw)!=1)return false;
    uint32_t ip=ntohl(raw.s_addr);
#ifdef MDS_RF_TESTING
    if(ip==0x7f000001)return true;
#endif
    if(!ip||ip==0xffffffff||(ip>>24)==127||(ip>>28)>=14)return false;
    for(NSDictionary *entry in interfaces){in_addr local{};
        if(inet_pton(AF_INET,[entry[@"ip"] UTF8String],&local)!=1)continue;
        uint32_t mask=[entry[@"mask"] unsignedIntValue],host=ip&~mask;
        if(mask&&host&&host!=~mask&&(ip&mask)==(ntohl(local.s_addr)&mask))return true;
    }return false;
}
static dispatch_data_t rfData(NSData *bytes){
    // Destructor retains the NSData for asynchronous Network.framework use.
    return dispatch_data_create(bytes.bytes,bytes.length,nullptr,^{(void)bytes;});
}
static nw_parameters_t rfParameters(NSData *key){
    nw_parameters_t parameters=nw_parameters_create_secure_udp(^(nw_protocol_options_t options){
        sec_protocol_options_t security=nw_tls_copy_sec_protocol_options(options);
        sec_protocol_options_add_pre_shared_key(security,rfData(key),rfData([@"ManicDS-RF-1" dataUsingEncoding:NSASCIIStringEncoding]));
        // RFC 5487 cipher 0x00a8. Apple's modern enum omits this DTLS PSK
        // name although its public cipher configuration accepts the wire ID.
        sec_protocol_options_append_tls_ciphersuite(security,static_cast<tls_ciphersuite_t>(0x00a8));
        sec_protocol_options_set_min_tls_protocol_version(security,tls_protocol_version_DTLSv12);
        sec_protocol_options_set_max_tls_protocol_version(security,tls_protocol_version_DTLSv12);
    },NW_PARAMETERS_DEFAULT_CONFIGURATION);
    // Each RF exchange gates the emulated CPU, with a genuine 25ms reply
    // deadline. Best-effort delivery can retain small commands beyond that
    // deadline even when the dispatch queue is interactive and has no backlog.
    // Apply the public latency-sensitive data policy to both listener and
    // outgoing DTLS paths; retain authentic bytes, deadlines and encryption.
    if(parameters)nw_parameters_set_service_class(parameters,nw_service_class_responsive_data);
    return parameters;
}

@interface MDSLocalRF : NSObject
-(instancetype)initWithSetup:(void(^)(NSString*,NSDictionary*))setup receive:(void(^)(NSString*,NSData*))receive;
-(void)add:(NSString*)nonce;
-(void)connect:(NSString*)nonce metadata:(NSDictionary*)metadata;
// YES = admitted to DTLS or deliberately dropped under bounded backpressure;
// NO = path unavailable, caller may use the existing encrypted MPC carrier.
-(BOOL)send:(NSData*)data peer:(NSString*)nonce;
-(void)remove:(NSString*)nonce;
-(void)stop;
-(NSDictionary*)metrics;
@end
@implementation MDSLocalRF {
    dispatch_queue_t _queue;
    NSMutableDictionary<NSString*,MDSRFPeer*> *_peers;
    NSArray *_interfaces;
    void(^_setup)(NSString*,NSDictionary*);void(^_receive)(NSString*,NSData*);
    std::mutex _mutex;
    BOOL _stopped;
    uint64_t _sent,_received,_dropped,_failures;
}
-(instancetype)initWithSetup:(void(^)(NSString*,NSDictionary*))setup receive:(void(^)(NSString*,NSData*))receive{
    if((self=[super init])){_queue=dispatch_queue_create("org.manicemu.ds.local-rf",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
        _peers=[NSMutableDictionary new];_interfaces=rfInterfaces();_setup=[setup copy];_receive=[receive copy];}return self;
}
-(void)read:(nw_connection_t)connection peer:(MDSRFPeer*)peer{
    __weak MDSLocalRF *weak=self;
    nw_connection_receive_message(connection,^(dispatch_data_t content,nw_content_context_t context,bool complete,nw_error_t error){
        (void)context;MDSLocalRF *strong=weak;if(!strong)return;
        void(^receiver)(NSString*,NSData*)=nil;NSData *bytes=nil;
        {std::lock_guard<std::mutex> guard(strong->_mutex);if(strong->_stopped||peer.stopped)return;
            if(content&&complete){const void *data=nullptr;size_t size=0;dispatch_data_t mapped=dispatch_data_create_map(content,&data,&size);
                if(mapped&&size>=73&&size<=1000&&!memcmp(data,"MDR1",4)){bytes=[NSData dataWithBytes:data length:size];strong->_received++;receiver=strong->_receive;}
                else strong->_dropped++;
            }if(error)strong->_failures++;
        }
        if(receiver)receiver(peer.nonce,bytes);
        if(!error)[strong read:connection peer:peer];
        else{nw_connection_cancel(connection);std::lock_guard<std::mutex> guard(strong->_mutex);[peer.incoming removeObject:connection];}
    });
}
-(void)add:(NSString*)nonce{
    MDSRFPeer *peer;{std::lock_guard<std::mutex> guard(_mutex);if(_stopped||_peers[nonce]||_peers.count>=15||!_interfaces.count)return;
        uint8_t secret[32]{};if(SecRandomCopyBytes(kSecRandomDefault,sizeof(secret),secret)!=errSecSuccess)return;
        peer=[MDSRFPeer new];peer.nonce=nonce;peer.key=[NSData dataWithBytes:secret length:sizeof(secret)];
        peer.candidates=[NSMutableArray new];peer.incoming=[NSMutableArray new];_peers[nonce]=peer;
    }
    nw_parameters_t parameters=rfParameters(peer.key);if(!parameters){[self remove:nonce];return;}
    nw_parameters_prohibit_interface_type(parameters,nw_interface_type_cellular);
    nw_parameters_set_include_peer_to_peer(parameters,false);
    nw_listener_t listener=nw_listener_create(parameters);if(!listener){[self remove:nonce];return;}
    {std::lock_guard<std::mutex> guard(_mutex);if(_stopped||peer.stopped){nw_listener_cancel(listener);return;}peer.listener=listener;}
    __weak MDSLocalRF *weak=self;
    nw_listener_set_queue(listener,_queue);
    nw_listener_set_state_changed_handler(listener,^(nw_listener_state_t state,nw_error_t error){
        (void)error;MDSLocalRF *strong=weak;if(!strong)return;
        void(^setup)(NSString*,NSDictionary*)=nil;NSDictionary *metadata=nil;
        {std::lock_guard<std::mutex> guard(strong->_mutex);if(strong->_stopped||peer.stopped)return;
            if(state==nw_listener_state_ready){NSMutableArray *addresses=[NSMutableArray new];for(NSDictionary *entry in strong->_interfaces)[addresses addObject:entry[@"ip"]];
                metadata=@{@"v":@1,@"port":@(nw_listener_get_port(listener)),@"ip":addresses,@"key":[peer.key base64EncodedStringWithOptions:0]};setup=strong->_setup;
            }else if(state==nw_listener_state_failed)strong->_failures++;
        }if(setup)setup(nonce,metadata);
    });
    nw_listener_set_new_connection_handler(listener,^(nw_connection_t connection){
        MDSLocalRF *strong=weak;if(!strong){nw_connection_cancel(connection);return;}
        {std::lock_guard<std::mutex> guard(strong->_mutex);if(strong->_stopped||peer.stopped||peer.incoming.count>=4){nw_connection_cancel(connection);return;}[peer.incoming addObject:connection];}
        __block BOOL established=NO;nw_connection_set_queue(connection,strong->_queue);
        nw_connection_set_state_changed_handler(connection,^(nw_connection_state_t state,nw_error_t error){
            (void)error;MDSLocalRF *owner=weak;if(!owner)return;
            if(state==nw_connection_state_ready){established=YES;[owner read:connection peer:peer];}
            else if(state==nw_connection_state_failed||state==nw_connection_state_cancelled){std::lock_guard<std::mutex> guard(owner->_mutex);[peer.incoming removeObject:connection];if(state==nw_connection_state_failed)owner->_failures++;nw_connection_cancel(connection);}
        });nw_connection_start(connection);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),strong->_queue,^{
            MDSLocalRF *owner=weak;if(!owner)return;std::lock_guard<std::mutex> guard(owner->_mutex);
            if(!established&&!peer.stopped){nw_connection_cancel(connection);[peer.incoming removeObject:connection];}
        });
    });nw_listener_start(listener);
}
-(void)connect:(NSString*)nonce metadata:(NSDictionary*)metadata{
    if(![metadata isKindOfClass:NSDictionary.class]||![metadata[@"v"] isEqual:@1]||![metadata[@"port"] isKindOfClass:NSNumber.class]||
       ![metadata[@"ip"] isKindOfClass:NSArray.class]||[metadata[@"ip"] count]>4||![metadata[@"key"] isKindOfClass:NSString.class]||[metadata[@"key"] length]!=44)return;
    unsigned port=[metadata[@"port"] unsignedIntValue];NSData *key=[[NSData alloc]initWithBase64EncodedString:metadata[@"key"] options:0];if(!port||port>65535||key.length!=32)return;
    [self add:nonce];MDSRFPeer *peer;
    {std::lock_guard<std::mutex> guard(_mutex);peer=_peers[nonce];if(_stopped||!peer||peer.stopped||peer.remote)return;peer.remote=[metadata copy];}
    for(NSString *address in metadata[@"ip"]){if(!rfLocalAddress(address,_interfaces))continue;
        NSString *portText=[NSString stringWithFormat:@"%u",port];nw_endpoint_t endpoint=nw_endpoint_create_host(address.UTF8String,portText.UTF8String);
        nw_parameters_t parameters=rfParameters(key);nw_parameters_prohibit_interface_type(parameters,nw_interface_type_cellular);nw_parameters_set_include_peer_to_peer(parameters,false);
        nw_connection_t connection=nw_connection_create(endpoint,parameters);if(!connection)continue;
        {std::lock_guard<std::mutex> guard(_mutex);if(_stopped||peer.stopped){nw_connection_cancel(connection);return;}[peer.candidates addObject:connection];}
        __weak MDSLocalRF *weak=self;nw_connection_set_queue(connection,_queue);
        nw_connection_set_state_changed_handler(connection,^(nw_connection_state_t state,nw_error_t error){
            (void)error;MDSLocalRF *strong=weak;if(!strong)return;std::lock_guard<std::mutex> guard(strong->_mutex);
            if(strong->_stopped||peer.stopped){nw_connection_cancel(connection);return;}
            if(state==nw_connection_state_ready){if(!peer.outgoing){peer.outgoing=connection;peer.ready=YES;
                    for(nw_connection_t other in [peer.candidates copy])if(other!=connection)nw_connection_cancel(other);
                }else if(peer.outgoing!=connection)nw_connection_cancel(connection);
            }else if(state==nw_connection_state_waiting||state==nw_connection_state_failed||state==nw_connection_state_cancelled){
                if(peer.outgoing==connection){peer.ready=NO;peer.outgoing=nil;}[peer.candidates removeObject:connection];
                if(state!=nw_connection_state_cancelled){strong->_failures++;nw_connection_cancel(connection);}
            }
        });nw_connection_start(connection);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),_queue,^{
            MDSLocalRF *strong=weak;if(!strong)return;std::lock_guard<std::mutex> guard(strong->_mutex);
            if(!peer.stopped&&peer.outgoing!=connection)nw_connection_cancel(connection);
        });
    }
}
-(BOOL)send:(NSData*)data peer:(NSString*)nonce{
    if(data.length<73||data.length>1000||memcmp(data.bytes,"MDR1",4))return NO;
    nw_connection_t connection;MDSRFPeer *peer;
    {std::lock_guard<std::mutex> guard(_mutex);peer=_peers[nonce];if(_stopped||!peer.ready||peer.stopped||!peer.outgoing)return NO;
        if(peer.pending>=32){_dropped++;return YES;}peer.pending++;connection=peer.outgoing;_sent++;
    }
    __weak MDSLocalRF *weak=self;nw_connection_send(connection,rfData(data),NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,true,^(nw_error_t error){
        MDSLocalRF *strong=weak;if(!strong)return;std::lock_guard<std::mutex> guard(strong->_mutex);if(peer.pending)peer.pending--;
        if(error){strong->_failures++;strong->_dropped++;peer.ready=NO;nw_connection_cancel(connection);}
    });return YES;
}
-(void)remove:(NSString*)nonce{
    std::lock_guard<std::mutex> guard(_mutex);MDSRFPeer *peer=_peers[nonce];if(!peer)return;peer.stopped=YES;peer.ready=NO;
    if(peer.listener){nw_listener_set_state_changed_handler(peer.listener,nullptr);nw_listener_set_new_connection_handler(peer.listener,nullptr);nw_listener_cancel(peer.listener);peer.listener=nil;}
    for(nw_connection_t c in peer.candidates){nw_connection_set_state_changed_handler(c,nullptr);nw_connection_cancel(c);}
    for(nw_connection_t c in peer.incoming){nw_connection_set_state_changed_handler(c,nullptr);nw_connection_cancel(c);}
    [peer.candidates removeAllObjects];[peer.incoming removeAllObjects];peer.outgoing=nil;peer.remote=nil;peer.key=nil;
    [_peers removeObjectForKey:nonce];
}
-(void)stop{
    NSArray *names;{std::lock_guard<std::mutex> guard(_mutex);_stopped=YES;names=[_peers.allKeys copy];_setup=nil;_receive=nil;}
    for(NSString *name in names)[self remove:name];
}
-(NSDictionary*)metrics{
    std::lock_guard<std::mutex> guard(_mutex);unsigned ready=0;for(MDSRFPeer *peer in _peers.allValues)ready+=peer.ready&&!peer.stopped;
    return @{@"ready_peers":@(ready),@"sent":@(_sent),@"received":@(_received),@"dropped":@(_dropped),@"failures":@(_failures)};
}
@end
