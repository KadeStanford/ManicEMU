"""Freeze only the radio cursor while genuine data is pending; CPU may run."""
import pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]);pin='ee7505609fcfa48946d3e0235acecf315fa322ae'
assert subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'],text=True).strip()==pin
p=root/'src/Wifi.cpp';s=p.read_text()
if '// MANIC_ASYNC_RADIO_EXPERIMENT' in s:raise SystemExit(0)
def replace(before,after):
 global s
 if s.count(before)!=1:raise ValueError('Pinned Wifi source guard')
 s=s.replace(before,after)
replace('namespace melonDS\n{','namespace melonDS\n{\n// MANIC_ASYNC_RADIO_EXPERIMENT; runtime feature defaults OFF.\nnamespace Platform { bool MP_IsAsync(); }')
replace('''                    res = Platform::MP_RecvReplies(MPClientReplies, USTimestamp, MPClientMask, NDS.UserData);
                MPClientFail &= ~res;''','''                    res = Platform::MP_RecvReplies(MPClientReplies, USTimestamp, MPClientMask, NDS.UserData);
                if(res & 1){slot->CurPhase=14;slot->CurPhaseTime=0;return false;}
                MPClientFail &= ~res;''')
replace('''    case 11: // MP default reply transfer finished''','''    case 14: // genuine reply pending; no CPU-blocking receive
        {
            u16 res=Platform::MP_RecvReplies(MPClientReplies,USTimestamp,MPClientMask,NDS.UserData);
            if(res & 1)return false;
            MPClientFail &= ~res;
            slot->CurPhase=2;
            slot->CurPhaseTime=112+((10+IOPORT(W_CmdReplyTime))*NumClients(MPClientMask));
        }
        return false;
    case 11: // MP default reply transfer finished''')
replace('''void Wifi::USTimer(u32 param)
{
    USTimestamp += kTimerInterval;''','''void Wifi::USTimer(u32 param)
{
    if(Platform::MP_IsAsync()){
        if((ComStatus & 2) && TXCurSlot==1 && TXSlots[1].CurPhase==14){
            ProcessTX(&TXSlots[1],1);ScheduleTimer(false);return;
        }
        if(IsMPClient && !ComStatus && !RXTimestamp && USTimestamp>=NextSync){
            if(!CheckRX(2)){ScheduleTimer(false);return;}
        }
    }
    USTimestamp += kTimerInterval;''')
p.write_text(s,encoding='utf-8',newline='\n')
