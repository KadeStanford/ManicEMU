"""Compile the actual async helper with only its wall clock substituted."""
import argparse,hashlib,json,pathlib
p=argparse.ArgumentParser();p.add_argument('--output',type=pathlib.Path,required=True);a=p.parse_args()
here=pathlib.Path(__file__).resolve().parent
stub=(here/'native_replies.cpp').read_text().split('#include "../Core/ReceiveReplies.inc"',1)[0]
helper=(here.parent/'Core/AsyncRadio.inc').read_text()
assert helper.count('std::chrono::steady_clock')==6
clock='''namespace manicds {
inline uint64_t asyncTestMicros=0;
struct AsyncTestClock { using time_point=std::chrono::steady_clock::time_point;
 static time_point now(){return time_point(std::chrono::microseconds(asyncTestMicros));}};
}
'''
a.output.write_text(stub+clock+helper.replace('std::chrono::steady_clock','manicds::AsyncTestClock')+(here/'native_async_cases.inc').read_text(),encoding='utf-8',newline='\n')
a.output.with_suffix('.json').write_text(json.dumps({'actual_helper_sha256':hashlib.sha256(helper.encode()).hexdigest(),'only_helper_clock_substituted':True,'private_data':False},indent=2))
