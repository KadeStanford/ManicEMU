// SPDX-License-Identifier: AGPL-3.0-or-later
// Synthetic independent process peer; never opens an emulator/game/save file.
#include "Protocol.hpp"
#include <iostream>
#include <memory>
#include <sstream>
#include <string>
using namespace manicds;
static std::string hex(const Bytes &v){std::string s;for(auto b:v){s.push_back("0123456789abcdef"[b>>4]);s.push_back("0123456789abcdef"[b&15]);}return s;}
static Bytes unhex(const std::string &s){
    if(s.size()%2)return {};Bytes v;
    for(size_t i=0;i<s.size();i+=2){
        auto a=std::string("0123456789abcdef").find(s[i]),b=std::string("0123456789abcdef").find(s[i+1]);
        if(a==std::string::npos||b==std::string::npos)return {};v.push_back(uint8_t(a*16+b));
    }return v;
}
static Nonce nonce(unsigned n){Nonce v{};v[0]=uint8_t(n);v[15]=uint8_t(n*7);return v;}
int main(int argc,char **argv){
    if(argc!=4||std::string(argv[2]).size()!=4)return 2;
    unsigned n=unsigned(std::stoul(argv[1]));Protocol p(nonce(n),argv[2],uint8_t(std::stoul(argv[3])));
    std::string line;
    while(std::getline(std::cin,line)){
        std::istringstream in(line);std::string command,arg,code;in>>command;bool ok=true;Bytes payload;unsigned value=0;
        if(command=="BIND"){in>>value>>code;ok=code.size()==4&&p.bind(nonce(value),code.data(),0);}
        else if(command=="RADIO"){in>>value;p.radio(value!=0);}
        else if(command=="HOLD"){in>>value;p.hold(value!=0);}
        else if(command=="SEND"){in>>arg;auto b=unhex(arg);ok=p.send(b.data(),b.size());}
        else if(command=="IN"){in>>arg;auto b=unhex(arg);ok=p.receive(b.data(),b.size());}
        else if(command=="POP"){Received r;ok=p.pop(r);if(ok)payload=std::move(r.data);}
        else if(command=="DISC")p.disconnect();
        else if(command=="RECONNECT"){in>>value;ok=p.reconnect(nonce(value));}
        else if(command=="CLOSE")p.close();
        else if(command!="STATUS"&&command!="DRAIN"&&command!="RETRANSMIT")return 3;
        std::vector<Bytes> frames;if(command=="DRAIN")frames=p.takeWire();else if(command=="RETRANSMIT")frames=p.retransmit();
        std::cout<<"{\"ok\":"<<(ok?"true":"false")<<",\"phase\":"<<int(p.phase())<<",\"id\":"<<p.id()
                 <<",\"tx\":"<<p.sentCount()<<",\"rx\":"<<p.receivedCount()<<",\"acked\":"<<p.acknowledged()
                 <<",\"duplicates\":"<<p.duplicateCount()<<",\"rejected\":"<<p.rejectedCount()
                 <<",\"settled\":"<<(p.settled()?"true":"false")<<",\"paused\":"<<(p.paused()?"true":"false")
                 <<",\"payload\":\""<<hex(payload)<<"\",\"wire\":[";
        for(size_t i=0;i<frames.size();i++){if(i)std::cout<<',';std::cout<<'"'<<hex(frames[i])<<'"';}
        std::cout<<"]}"<<std::endl;
    }return 0;
}
