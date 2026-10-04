// SPDX-License-Identifier: AGPL-3.0-or-later
#include "Protocol.hpp"
#include <algorithm>
#include <cstring>
#include <limits>

namespace manicds {
static uint16_t get16(const uint8_t *p){return uint16_t((unsigned(p[0])<<8)|p[1]);}
static uint64_t get64(const uint8_t *p){uint64_t v=0;for(unsigned i=0;i<8;i++)v=(v<<8)|p[i];return v;}
static void put16(uint8_t *p,uint16_t v){p[0]=uint8_t(v>>8);p[1]=uint8_t(v);}
static void put64(uint8_t *p,uint64_t v){for(unsigned i=0;i<8;i++)p[7-i]=uint8_t(v>>(8*i));}
bool FrameAddressMap::configure(MAC native,MAC peer,uint16_t id){
    enabled_=false;
    auto valid=[](const MAC &m){return !(m[0]&1)&&std::any_of(m.begin(),m.end(),[](uint8_t b){return b!=0;});};
    if(id>1||!valid(native)||!valid(peer))return false;
    native_=native;if(native!=peer)return true;
    MAC a{0,9,191,250,0,1},b{0,9,191,250,0,2};
    if(native==a||native==b){a[5]=3;b[5]=4;}
    alias_=id?b:a;enabled_=true;return true;
}
void FrameAddressMap::replace(Bytes &p,const MAC &from,const MAC &to)const{
    if(!enabled_||p.size()<46||p.size()>MaxPacket)return;
    // Ten-byte melonDS envelope, twelve-byte hardware header, IEEE header.
    // Management/data frames have three addresses. Control frames can be
    // shorter and must never have their payload mistaken for address three.
    unsigned fc=p[22]|(unsigned(p[23])<<8),type=(fc>>2)&3;
    if(type!=0&&type!=2)return;
    for(size_t offset:{size_t(26),size_t(32),size_t(38)})
        if(std::equal(from.begin(),from.end(),p.begin()+offset))std::copy(to.begin(),to.end(),p.begin()+offset);
}
void FrameAddressMap::outgoing(Bytes &p)const{replace(p,native_,alias_);}
void FrameAddressMap::incoming(Bytes &p)const{replace(p,alias_,native_);}
int title(const char c[4]){
    static const char codes[][4]={"ADA","APA","CPU","IPK","IPG","IRB","IRA","IRE","IRD"};
    if(!c||c[3]<'A'||c[3]>'Z')return 0;
    for(int i=0;i<9;i++)if(!std::memcmp(c,codes[i],3))return i+1;
    return 0;
}
bool compatible(const char a[4],const char b[4]){
    int x=title(a),y=title(b);return x&&y&&((x<=5)==(y<=5));
}
bool validPacket(const void *data,size_t size){
    if(!data||size<10||size>MaxPacket)return false;
    auto p=static_cast<const uint8_t*>(data);
    return p[9]<=2&&p[8]<16&&(p[9]!=1||p[8]>0);
}
bool localFrame(const void *data,size_t size,unsigned type){
    if(!data||size<36||size>2048||type>2)return false;
    auto p=static_cast<const uint8_t*>(data);
    // Raw melonDS frames have a 12-byte hardware header, then IEEE 802.11.
    unsigned fc=p[12]|(unsigned(p[13])<<8);
    // Nintendo multiplayer CMD/reply uses ToDS/FromDS too (native default
    // reply 0x0158, ACK 0x0218). Its dedicated engine transport identifies it;
    // those bits alone cannot distinguish Nintendo WFC from local wireless.
    if(type==1||type==2)return true;
    const uint8_t nintendo[]{3,9,191,0,0,0};
    if(!std::memcmp(p+16,nintendo,5)&&(p[21]==0||p[21]==3||p[21]==16))return true;
    if(fc&0x300)return false; // Ordinary infrastructure data, no local marker
    // A Nintendo vendor IE in a beacon/probe response identifies a local host.
    unsigned subtype=fc&0xfc;
    if(subtype!=0x80&&subtype!=0x50)return false;
    size_t pos=12+24+12;
    while(pos+2<=size){
        size_t len=p[pos+1];if(len>size-pos-2)return false;
        if(p[pos]==221&&len>=3&&p[pos+2]==0&&p[pos+3]==9&&p[pos+4]==191)return true;
        pos+=2+len;
    }
    return false;
}
Protocol::Protocol(Nonce identity,const char code[4],uint8_t revision):identity_(identity),revision_(revision){
    if(code)std::memcpy(code_.data(),code,4);
}
bool Protocol::bind(Nonce peer,const char code[4],uint8_t revision){
    (void)revision; // Revision is advertised; Nintendo's game negotiates its rules.
    if(bound_||failed_||ended_||peer==identity_||!compatible(code_.data(),code))return false;
    peer_=peer;id_=identity_<peer?0:1;
    const Nonce &a=id_?peer:identity_,&b=id_?identity_:peer;
    std::copy(a.begin(),a.end(),room_.begin());std::copy(b.begin(),b.end(),room_.begin()+16);
    bound_=true;uint8_t ready[6];std::memcpy(ready,code_.data(),4);ready[4]=revision_;ready[5]=radio_;
    if(!enqueue(Kind::Ready,ready,6))return false;
    localReady_=true;readySeq_=tx_;return true;
}
Bytes Protocol::encode(Kind kind,uint64_t seq,const void *data,size_t size,uint16_t target)const{
    Bytes b(WireHeader+size,0);std::memcpy(b.data(),"MDS1",4);b[4]=1;b[5]=uint8_t(kind);
    put16(b.data()+6,uint16_t(size));put16(b.data()+8,id_);put16(b.data()+10,target);
    std::copy(room_.begin(),room_.end(),b.begin()+12);put64(b.data()+44,seq);
    // 52..55 reserved. Reject nonzero values on receipt for future wire versions.
    if(size)std::memcpy(b.data()+WireHeader,data,size);return b;
}
void Protocol::fail(){failed_=true;incoming_.clear();wire_.clear();}
bool Protocol::enqueue(Kind kind,const void *data,size_t size,uint16_t target){
    if(!bound_||failed_||ended_||pending_.size()>=MaxQueue||wire_.size()>=MaxQueue||tx_==std::numeric_limits<uint64_t>::max()){
        fail();return false;
    }
    auto b=encode(kind,++tx_,data,size,target);pending_.push_back({tx_,kind,b});wire_.push_back(std::move(b));return true;
}
bool Protocol::send(const void *data,size_t size,uint16_t target){
    if(!paired()||paused()||!radio_||closeSent_||!validPacket(data,size)||(target!=65535&&target!=uint16_t(1-id_)))return false;
    return enqueue(Kind::Data,data,size,target);
}
void Protocol::radio(bool on){
    if(radio_==on)return;radio_=on;
    if(bound_&&!ended_&&!failed_){uint8_t v=on;enqueue(Kind::Radio,&v,1);}
}
void Protocol::hold(bool on){
    if(held_==on)return;held_=on;
    if(bound_&&!ended_&&!failed_){uint8_t v=on;if(enqueue(Kind::Hold,&v,1)&&!on)releaseSeq_=tx_;}
}
void Protocol::close(){
    if(!bound_||failed_||ended_||closeSent_)return;
    if(enqueue(Kind::Close,nullptr,0))closeSent_=true;
}
bool Protocol::receive(const void *data,size_t size){
    if(!data||size<WireHeader||size>WireHeader+MaxPacket||!bound_||failed_)return false;
    const auto p=static_cast<const uint8_t*>(data);
    if(std::memcmp(p,"MDS1",4)||p[4]!=1||std::memcmp(p+12,room_.data(),32)||
       get16(p+8)!=uint16_t(1-id_)||(get16(p+10)!=65535&&get16(p+10)!=id_)||
       get16(p+6)!=size-WireHeader||p[52]||p[53]||p[54]||p[55]){++rejected_;return false;}
    auto k=Kind(p[5]);auto seq=get64(p+44);const auto payload=p+WireHeader;size_t len=size-WireHeader;
    if(!seq){++rejected_;return false;}
    if(k==Kind::Ack){
        if(len||seq>tx_){++rejected_;return false;}
        if(seq<=acked_)return true;
        acked_=seq;readyAcked_=acked_>=readySeq_;
        while(!pending_.empty()&&pending_.front().sequence<=seq)pending_.pop_front();
        if(closeSent_&&peerClose_&&pending_.empty())ended_=true;
        return true;
    }
    bool valid=false;
    switch(k){
    case Kind::Ready:valid=len==6&&compatible(code_.data(),reinterpret_cast<const char*>(payload))&&payload[5]<=1;break;
    case Kind::Data:valid=peerReady_&&validPacket(payload,len);break;
    case Kind::Radio:case Kind::Hold:valid=len==1&&payload[0]<=1&&peerReady_;break;
    case Kind::Close:valid=len==0&&peerReady_;break;
    default:break;
    }
    if(!valid){++rejected_;return false;}
    if(seq<=rx_){
        ++duplicates_;if(wire_.size()>=MaxQueue){fail();return false;}
        wire_.push_back(encode(Kind::Ack,rx_,nullptr,0,uint16_t(1-id_)));return true;
    }
    if(seq!=rx_+1){fail();return false;} // Ordered channel broke: never skip game data.
    if(ended_||(k==Kind::Ready&&peerReady_)||(k==Kind::Data&&(peerClose_||incoming_.size()>=MaxQueue))||wire_.size()>=MaxQueue){fail();return false;}
    switch(k){
    case Kind::Ready:peerReady_=true;peerRadio_=payload[5]!=0;break;
    case Kind::Data:incoming_.push_back({Bytes(payload,payload+len),uint16_t(1-id_)});break;
    case Kind::Radio:peerRadio_=payload[0]!=0;break;
    case Kind::Hold:peerHeld_=payload[0]!=0;break;
    case Kind::Close:peerClose_=true;break;
    default:break;
    }
    rx_=seq;wire_.push_back(encode(Kind::Ack,seq,nullptr,0,uint16_t(1-id_)));
    if(closeSent_&&peerClose_&&pending_.empty())ended_=true;
    return true;
}
bool Protocol::pop(Received &packet){
    if(incoming_.empty()||!paired()||paused())return false;
    packet=std::move(incoming_.front());incoming_.pop_front();return true;
}
void Protocol::disconnect(){
    if(!bound_||ended_||failed_)return;
    // A parked, fully acknowledged departure has no interrupted game payload.
    if(bothOff()&&settled()){ended_=true;return;}
    interrupted_=true;
}
bool Protocol::abandonAfterRadioOff(){
    if(radio_||(!interrupted_&&!failed_))return false;
    // Explicit game radio shutdown after failure ends this transport only.
    // This does not claim that a trade completed or restore any game memory.
    ended_=true;failed_=interrupted_=false;pending_.clear();incoming_.clear();wire_.clear();return true;
}
bool Protocol::reconnect(Nonce peer){
    if(peer!=peer_||!interrupted_||failed_||ended_)return false;
    interrupted_=false;auto frames=retransmit();
    if(frames.size()+wire_.size()>MaxQueue){fail();return false;}
    for(auto &p:frames)wire_.push_back(std::move(p));return true;
}
Phase Protocol::phase()const{
    if(failed_)return Phase::Failed;if(ended_)return Phase::Ended;
    if(interrupted_)return Phase::Interrupted;if(!bound_)return Phase::Ready;
    if(!paired())return Phase::Pairing;return bothOff()?Phase::Parked:Phase::Active;
}
std::vector<Bytes> Protocol::takeWire(){auto v=std::move(wire_);wire_.clear();return v;}
std::vector<Bytes> Protocol::retransmit()const{std::vector<Bytes> v;for(const auto &p:pending_)v.push_back(p.wire);return v;}
}
