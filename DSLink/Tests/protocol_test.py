"""Two independent processes exercise packet/lifecycle plumbing, not Pokemon."""
import argparse,json,pathlib,subprocess,time
p=argparse.ArgumentParser();p.add_argument('peer');p.add_argument('report',type=pathlib.Path);args=p.parse_args()
checks=[]
class Peer:
 def __init__(self,n,code):
  self.p=subprocess.Popen([args.peer,str(n),code,'0'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
 def cmd(self,line):
  self.p.stdin.write(line+'\n');self.p.stdin.flush();s=self.p.stdout.readline()
  if not s:raise AssertionError('peer process failed')
  return json.loads(s)
 def stop(self):
  self.p.stdin.close();assert self.p.wait(timeout=5)==0
def check(name,condition):
 assert condition,name
 checks.append(name)
def pump(a,b):
 for _ in range(16):
  count=0
  for x,y in ((a,b),(b,a)):
   frames=x.cmd('DRAIN')['wire'];count+=len(frames)
   for f in frames:check('ordered wire accepted',y.cmd('IN '+f)['ok'])
  if not count:return
 raise AssertionError('unbounded control exchange')
def packet(tag,type=0):return (123456789).to_bytes(8,'big')+bytes([1 if type==1 else 0,type])+tag
codes=['ADAE','APAE','CPUE','IPKE','IPGE','IRBO','IRAO','IREO','IRDO']
start=time.monotonic()
for i,x in enumerate(codes):
 for j,y in enumerate(codes):
  a,b=Peer(1,x),Peer(2,y)
  try:
   a.cmd('RADIO 1');b.cmd('RADIO 1')
   allowed=(i<5)==(j<5)
   check(f'{x}/{y} pairing admission',a.cmd(f'BIND 2 {y}')['ok']==allowed)
   check(f'{y}/{x} pairing admission',b.cmd(f'BIND 1 {x}')['ok']==allowed)
   if not allowed:continue
   pump(a,b);check('both independent engines active',a.cmd('STATUS')['phase']==2 and b.cmd('STATUS')['phase']==2)
   for session in range(3):
    for sender,receiver,label in ((a,b,b'left'),(b,a,b'right')):
     data=packet(label+bytes([session]),session%3)
     check('raw game packet queued',sender.cmd('SEND '+data.hex())['ok'])
     wire=sender.cmd('DRAIN')['wire'];assert len(wire)==1
     check('raw game packet accepted',receiver.cmd('IN '+wire[0])['ok'])
     check('duplicate acknowledged',receiver.cmd('IN '+wire[0])['ok'])
     pump(a,b)
     check('independent packet payload unchanged',receiver.cmd('POP')['payload']==data.hex())
     check('duplicate never executed twice',not receiver.cmd('POP')['ok'])
    a.cmd('RADIO 0');pump(a,b)
    check('one radio-off retains session',a.cmd('STATUS')['phase']==2)
    b.cmd('RADIO 0');pump(a,b)
    check('bilateral exit parks without teardown',a.cmd('STATUS')['phase']==3 and b.cmd('STATUS')['phase']==3)
    check('parked queues drained',a.cmd('STATUS')['settled'] and b.cmd('STATUS')['settled'])
    a.cmd('RADIO 1');b.cmd('RADIO 1');pump(a,b)
    check('trade-to-battle/repeated session keeps pairing',a.cmd('STATUS')['phase']==2 and b.cmd('STATUS')['phase']==2)
   a.cmd('HOLD 1');pump(a,b);check('bilateral hold',a.cmd('STATUS')['paused'] and b.cmd('STATUS')['paused'])
   a.cmd('HOLD 0');check('resume blocked before acknowledgment',a.cmd('STATUS')['paused']);pump(a,b);check('hold release',not a.cmd('STATUS')['paused'] and not b.cmd('STATUS')['paused'])
   pending=packet(b'in-flight');a.cmd('SEND '+pending.hex());wire=a.cmd('DRAIN')['wire'][0]
   a.cmd('DISC');b.cmd('DISC');check('in-flight loss suspends',a.cmd('STATUS')['phase']==4)
   check('other identity cannot reconnect',not a.cmd('RECONNECT 3')['ok'])
   check('same-peer explicit recovery',a.cmd('RECONNECT 2')['ok'] and b.cmd('RECONNECT 1')['ok'])
   pump(a,b);check('in-flight packet survives explicit continuation',b.cmd('POP')['payload']==pending.hex())
   a.cmd('RADIO 0');b.cmd('RADIO 0');pump(a,b);a.cmd('DISC');b.cmd('DISC')
   check('clean parked disconnect needs no recovery',a.cmd('STATUS')['phase']==6 and b.cmd('STATUS')['phase']==6)
   check('late ended data duplicate is acknowledged',b.cmd('IN '+wire)['ok'])
  finally:a.stop();b.stop()

# Malformed input, cross-session traffic and bounded queues are separate cases.
a,b=Peer(1,'ADAE'),Peer(2,'CPUE')
try:
 a.cmd('RADIO 1');b.cmd('RADIO 1');a.cmd('BIND 2 CPUE');b.cmd('BIND 1 ADAE');pump(a,b)
 check('short packet rejected',not a.cmd('SEND 00')['ok'])
 check('oversize packet rejected',not a.cmd('SEND '+packet(b'x'*2049).hex())['ok'])
 a.cmd('SEND '+packet(b'a').hex());wire=bytes.fromhex(a.cmd('DRAIN')['wire'][0])
 for pos,value in ((0,0),(4,2),(8,8),(12,8),(52,1)):
  bad=bytearray(wire);bad[pos]=value
  check('malformed or foreign envelope rejected',not b.cmd('IN '+bad.hex())['ok'])
 check('valid packet after rejected traffic',b.cmd('IN '+wire.hex())['ok']);pump(a,b);b.cmd('POP')
 for _ in range(256):check('bounded queue slot accepted',a.cmd('SEND '+packet(b'x').hex())['ok'])
 check('queue overflow fails closed',not a.cmd('SEND '+packet(b'x').hex())['ok'] and a.cmd('STATUS')['phase']==5)
finally:a.stop();b.stop()

for mode in ('bilateral_close','interrupted_radio_exit'):
 a,b=Peer(3,'IRBO'),Peer(4,'IRDO')
 try:
  a.cmd('RADIO 1');b.cmd('RADIO 1');a.cmd('BIND 4 IRDO');b.cmd('BIND 3 IRBO');pump(a,b)
  if mode=='bilateral_close':
   a.cmd('RADIO 0');b.cmd('RADIO 0');pump(a,b);a.cmd('CLOSE');b.cmd('CLOSE');pump(a,b)
   check('bilateral close acknowledgments end room',a.cmd('STATUS')['phase']==6 and b.cmd('STATUS')['phase']==6)
  else:
   a.cmd('DISC');check('active radio cannot abandon interrupted session',not a.cmd('ABANDON')['ok'])
   a.cmd('RADIO 0');check('explicit radio exit abandons interrupted transport',a.cmd('ABANDON')['ok'] and a.cmd('STATUS')['phase']==6)
 finally:a.stop();b.stop()

a=Peer(5,'ADAE')
try:
 local=bytearray(48);local[16:22]=bytes([3,9,191,0,0,16])
 check('Nintendo local destination starts detector',a.cmd('LOCAL 0 '+local.hex())['ok'])
 infra=bytearray(local);infra[13]=1
 for kind in range(3):check('infrastructure WFC excluded from local discovery',not a.cmd(f'LOCAL {kind} '+infra.hex())['ok'])
 beacon=bytearray(53);beacon[12]=0x80;beacon[48:]=bytes([221,3,0,9,191])
 check('local Nintendo host beacon detected',a.cmd('LOCAL 0 '+beacon.hex())['ok'])
 beacon[49]=8;check('truncated vendor beacon rejected',not a.cmd('LOCAL 0 '+beacon.hex())['ok'])
finally:a.stop()
report={'checks_passed':len(checks),'pairing_admission_cases':81,'compatible_code_pairs':41,
 'repeated_synthetic_sessions_per_compatible_pair':3,'elapsed_seconds':time.monotonic()-start,
 'test_type':'Synthetic raw packet protocol, two independent desktop processes',
 'pokemon_titles_executed':[],'actual_game_trade_persistence_verified':False,'physical_iPhone_verified':False,
 'checks':checks}
args.report.write_text(json.dumps(report,indent=2));print(json.dumps({k:v for k,v in report.items() if k!='checks'}))
