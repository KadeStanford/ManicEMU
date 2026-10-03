"""Measure actual gpSP frames, input/video and audio under battle-only pacing.

The legal ARM loop has no Pokemon/serial IRQ handler. After clock measurement,
natural SIO OFF/ON + handshake realigns the manually driven word fixture.
This tests engine scheduling and transport, not real battle/game logic.
"""
from network_test import Peer, handshake, settle, close
from transition_test import command_pair, reopen, block
from exit_test import room_exit


def measure(master, slave, calls, expected):
    clocks=[p.clocks for p in (master,slave)]
    polls=[p.polls for p in (master,slave)]
    audio=[p.audio for p in (master,slave)]
    videos=[p.videos for p in (master,slave)]
    for _ in range(calls):
        master.command('frame');settle(master,slave)
        slave.command('frame');settle(master,slave)
        assert abs(master.bclock-slave.bclock)<=4
    for i,p in enumerate((master,slave)):
        assert p.clocks-clocks[i]==expected and p.polls-polls[i]==expected
        assert p.videos-videos[i]==calls
    return [p.audio-audio[i] for i,p in enumerate((master,slave))]


def main():
    master,slave=Peer(0),Peer(1)
    try:
        handshake(master,slave);command_pair(master,slave,0x2222,0x1111)
        normal=measure(master,slave,120,120)
        for p in (master,slave):assert not p.accel;p.command('sio 2000')
        settle(master,slave);reopen(master,slave);command_pair(master,slave,0x2222,0x2233)
        for p in (master,slave):p.command('speed');assert p.budget==1 and not p.accel
        command_pair(master,slave,0x2222,0x2211)
        # Negotiate explicitly without advancing the ARM-loop fixture's clocks.
        for p in (master,slave):p.command('speed')
        settle(master,slave)
        for p in (master,slave):p.command('speed');assert p.budget==2 and p.accel
        # Forward unchanged turn/block halfwords while the negotiated mode is live.
        for seed in (17,61,127):block(master,slave,28,seed)
        accelerated=measure(master,slave,120,240)
        for a,b in zip(normal,accelerated):assert abs(a-b)<250, (a,b)
        print(f'MEASURE: 120 frontend calls: trade=120 actual frames; linked battle=240 '
              f'actual frames; audio samples normal={normal}, battle={accelerated}; '
              'one displayed frame/call and input polled for every emulated frame',flush=True)
        before=master.clocks;master.command('frames 30')
        assert master.clocks-before==4 and master.phase==3
        master.command('speed');assert master.budget==0
        settle(master,slave);slave.command('frames 2');settle(master,slave)
        assert master.bclock==slave.bclock
        before=[p.clocks for p in (master,slave)]
        master.command('hold');settle(master,slave)
        for p in (master,slave):p.command('frames 30');assert p.phase==9
        assert [p.clocks for p in (master,slave)]==before
        master.command('pause');settle(master,slave);master.command('release');settle(master,slave)
        for p in (master,slave):p.command('frames 30');assert p.phase==4 and not p.accel
        assert [p.clocks for p in (master,slave)]==before
        master.command('resume');settle(master,slave);assert master.phase==slave.phase==4
        slave.command('resume');settle(master,slave);assert master.phase==slave.phase==3
        measure(master,slave,20,40)
        # Battle result/return hardware closes drop the pace gate immediately.
        for p in (master,slave):p.command('sio 2000');assert not p.accel
        settle(master,slave);measure(master,slave,20,20)
        reopen(master,slave);command_pair(master,slave,0x2222,0x2233)
        room_exit(master,slave)
        for p in (master,slave):p.command('begin');p.command('connect');assert not p.accel
        handshake(master,slave);command_pair(master,slave,0x2222,0x1122)
        for seed in (19,43,89):block(master,slave,200,seed)
        assert not master.accel and not slave.accel
        for p in (master,slave):p.command('sio 2000')
        settle(master,slave);reopen(master,slave);command_pair(master,slave,0x2222,0x1111)
        room_exit(master,slave,flushes=2)
        print('PASS: trade -> accelerated battle -> trade; four-frame run-ahead stall/release; '
              'result/hold/real-drop gates, bilateral recovery, normal return/exit, saves and fresh bootstrap')
    finally:close(master);close(slave)


if __name__=='__main__':main()
