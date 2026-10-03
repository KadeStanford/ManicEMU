"""Sequential FireRed lifecycle + frontend result/save holds, no Pokemon ROM.

The real gpSP bootstrap IRQ produces the opportunity for DoHandshake's B9A0.
Tests do not substitute B9A0 before proving that IRQ works after completion.
"""
from network_test import Peer, handshake, settle, close, wire
from transition_test import command_pair, block, internal_close, reopen
from exit_test import room_exit


def hold_roundtrip(master, slave, owner='master'):
    active = (master,slave) if owner=='both' else ((slave,) if owner=='slave' else (master,))
    for peer in active:peer.command('hold')
    settle(master,slave)
    for peer in (master,slave):
        peer.command('frames 300');assert peer.phase==9
    for index,peer in enumerate(active):
        peer.command('release');assert peer.phase==9, 'local release ran before its ACK'
        if len(active)==2 and index==0:
            settle(master,slave);assert master.phase==slave.phase==9, 'other frontend is still paused'
    settle(master,slave)
    for peer in (master,slave):peer.command('frame');assert peer.phase==3


def sequential():
    master,slave=Peer(0),Peer(1)
    try:
        handshake(master,slave);command_pair(master,slave,0x2222,0x1111)
        block(master,slave,200,17);room_exit(master,slave)
        for cycle,kind in enumerate((0x2233,0x2244,0x1111,0x2233),2):
            for peer in (master,slave):
                epoch=peer.epoch;peer.command('begin');assert peer.phase==2 and peer.epoch>epoch and peer.sram==0x99
                peer.command('connect')
            handshake(master,slave);command_pair(master,slave,0x2222,kind)
            if kind!=0x1111:
                internal_close(master,slave);command_pair(master,slave,0x2222,0x2211)
                for turn in range(3):block(master,slave,28,61+turn)
                # Winner/loser result and save pauses resume cooperatively. The
                # other frontend remains frozen while either player is held.
                for owner in ('master','slave','both'):hold_roundtrip(master,slave,owner)
                # Source-derived battle result UI waits 255 frames before return.
                # A slow results/save handoff can exceed the old quiet heuristic.
                command_pair(master,slave,0x5fff)
                for peer in (master,slave):peer.command('sio 2000')
                for _ in range(3):
                    settle(master,slave)
                    for peer in (master,slave):peer.command('frames 300')
                assert master.phase==slave.phase==3 and master.flushes==slave.flushes==cycle-1
                reopen(master,slave);command_pair(master,slave,0x2222,kind)
            else:
                internal_close(master,slave);command_pair(master,slave,0x2222,0x1122)
                block(master,slave,200,23);hold_roundtrip(master,slave)
                internal_close(master,slave);command_pair(master,slave,0x2222,0x1111)
            room_exit(master,slave,flushes=cycle)
        print('PASS: same loaded cores trade -> Single/Double win/loss results/holds/save/arena/exit -> '
              'trade -> battle again; real bootstrap IRQ, fresh epochs, no intermediate save flush')
    finally:close(master);close(slave)


def true_drop_and_release_ack():
    master,slave=Peer(0),Peer(1)
    try:
        handshake(master,slave);command_pair(master,slave,0x2222,0x2233)
        master.command('hold');settle(master,slave);master.command('release')
        packets,master.pending=master.pending,[]
        assert len(packets)==1 and packets[0][5]==9
        slave.command('packet '+wire(packets[0]).hex());assert slave.phase==3 and master.phase==9
        acks,slave.acks=slave.acks,[]
        assert acks
        master.command('frames 120');assert master.phase==9
        for ack in acks:master.command('packet '+wire(ack).hex())
        assert master.phase==3
        master.command('hold');settle(master,slave)
        master.command('disconnected');assert master.expected==0
        master.command('pause');settle(master,slave);assert master.phase==slave.phase==4
        master.command('release');settle(master,slave)
        assert master.phase==slave.phase==4, 'frontend resume incorrectly cleared a genuine disconnect'
        master.command('resume');settle(master,slave);assert master.phase==slave.phase==4
        slave.command('resume');settle(master,slave);assert master.phase==slave.phase==3
        block(master,slave,28,97)
        print('PASS: RELEASE ACK gates local clocks, and a real drop during a frontend hold '
              'still requires bilateral explicit recovery; serial exchange resumes')
    finally:close(master);close(slave)


if __name__=='__main__':
    sequential()
    true_drop_and_release_ack()
