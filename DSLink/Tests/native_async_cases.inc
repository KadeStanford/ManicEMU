static unsigned checks=0;
static void check(bool value){++checks;if(!value){std::fprintf(stderr,"async check %u failed\n",checks);std::exit(1);}}
int main(){
 using MelonDsDs::Core;using MelonDsDs::Packet;
 std::array<u8,15*1024+32> storage;
 auto reset=[&]{Core={};manicds::CancelAsync();manicds::asyncTestMicros=0;
  retro::events.fill(0);retro::traces.clear();storage.fill(0xa5);};
 auto run=[&](u64 stamp=1024,u16 mask=2){const auto before=manicds::asyncTestMicros;
  const u16 result=manicds::AsyncReceiveReplies(storage.data()+16,stamp,mask);
  check(manicds::asyncTestMicros==before);for(auto budget:Core.budgets)check(budget==0);return result;};
 auto guard=[&]{for(size_t i=0;i<16;++i)check(storage[i]==0xa5);
  for(size_t i=storage.size()-16;i<storage.size();++i)check(storage[i]==0xa5);};
 check(!manicds::AsyncRadioEnabled); // production requires explicit activation
 reset();check(run()==1&&manicds::AsyncReply&&Core.calls==1);
 const auto calls=Core.calls;manicds::asyncTestMicros=499;
 check(run()==1&&Core.calls==calls); // poll gate does not wait or reenter Core
 Core.queue.emplace_back(992,1,1,40);manicds::asyncTestMicros=500;
 check(run()==2&&!manicds::AsyncReply&&retro::events[40]==1&&retro::events[32]==1);
 for(size_t i=16;i<56;++i)check(storage[i]==0x51);guard();

 reset();Core.queue.emplace_back(991,1,1,40);Core.queue.emplace_back(1024,1,2,40);
 Core.queue.emplace_back(1024,2,2,40);Core.queue.emplace_back(1024,0,0,0);
 check(run()==1&&retro::events[42]==1&&retro::events[46]==1&&retro::events[44]==1&&retro::events[43]==1);
 for(auto byte:storage)check(byte==0xa5);
 Core.queue.emplace_back(1024,0,1,0);manicds::asyncTestMicros=500;
 check(run()==0&&retro::events[41]==1&&retro::events[32]==1); // genuine empty reply
 for(auto byte:storage)check(byte==0xa5);

 reset();Core.queue.emplace_back(1024,1,1,40);Core.queue.emplace_back(1024,1,1,40);
 Core.queue.emplace_back(1024,2,2,40,Packet::Reply,0x72);
 check(run(1024,6)==6&&retro::events[45]==1);guard();
 check(storage[16]==0x51&&storage[16+1024]==0x72);
 reset();Core.queue.emplace_back(1024,15,15,2048);
 check(run(1024,0x8000)==0x8000);guard();
 check(storage[16+14*1024]==0x51&&storage[16+15*1024-1]==0x51);

 reset();check(run(1024,0)==0&&Core.calls==0&&!manicds::AsyncReply);
 reset();check(run()==1);manicds::asyncTestMicros=124999;check(run()==1);
 manicds::asyncTestMicros=125000;check(run()==0&&!manicds::AsyncReply&&retro::events[33]==1);
 reset();check(run()==1);manicds::asyncTestMicros=133728;Core.queue.emplace_back(1024,1,1,40);
 check(run()==0&&Core.queue.size()==1&&retro::events[40]==0); // bounded deadline, no late acceptance

 reset();check(run()==1);manicds::asyncTestMicros=117012;Core.queue.emplace_back(1024,1,1,40);
 check(run()==2); // genuine110.8ms tail available at a frame-paced poll
 reset();check(run()==1);Core.active=false;check(run()==0&&!manicds::AsyncReply);
 reset();check(run()==1);manicds::CancelAsync();check(!manicds::AsyncReply);
 Core.queue.emplace_back(1024,1,1,40);check(run(2048)==1&&retro::events[42]==1);

 reset();for(unsigned n=0;n<256;++n)Core.queue.emplace_back(1024,0,0,40,Packet::Other);
 Core.queue.emplace_back(1024,1,1,40);check(run()==1&&Core.queue.size()==1);
 manicds::asyncTestMicros=500;check(run()==2&&Core.queue.empty());
 reset();Core.queue.emplace_back(1024,1,1,40);Core.queue.emplace_back(1024,0,0,40,Packet::Other);
 check(run()==2&&Core.queue.size()==1); // completion preserves following packet too

 reset();check(!manicds::AsyncReceiveHost());const auto hostCalls=Core.calls;
 manicds::asyncTestMicros=499;Core.queue.emplace_back(1024,0,0,40,Packet::Cmd);
 check(!manicds::AsyncReceiveHost()&&Core.calls==hostCalls);
 manicds::asyncTestMicros=500;check(manicds::AsyncReceiveHost().has_value());
 for(auto budget:Core.budgets)check(budget==0);
 manicds::CancelAsync();check(!manicds::AsyncReply&&manicds::AsyncHostPoll==manicds::AsyncTestClock::time_point{});
 std::printf("{\"checks\":%u,\"actual_async_helper\":true,\"clock_only_substituted\":true,\"zero_blocking_budgets\":true,\"private_data\":false,\"game_or_phone_proven\":false}\n",checks);
}
