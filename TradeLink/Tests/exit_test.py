"""FireRed's terminal room exit uses CAFE/17 then direct CloseLink, not 5FFF.

Trace from pret/pokefirered overworld.c/overworld.h at 037335f. Synthetic
register/command data only; actual FireRed game code is not executed here.
"""
from network_test import Peer, handshake, settle, close
from transition_test import command_pair


def direct_room_exit():
    master, slave = Peer(0), Peer(1)
    try:
        handshake(master, slave)
        command_pair(master, slave, 0x2222, 0x1111)
        command_pair(master, slave, 0xcafe, 0x17) # LINK_KEY_CODE_EXIT_ROOM, both players.
        for peer in (master, slave):peer.command('sio 2000')
        for _ in range(4):
            settle(master, slave)
            for peer in (master, slave):peer.command('frames 200')
        assert master.phase == slave.phase == 1, (
            'FireRed direct room exit left a stale paired session instead of '
            'returning to IDLE for later Colosseum discovery', master.phase, slave.phase)
        for peer in (master, slave):assert peer.flushes == 1
        print('PASS: bilateral room-exit key + direct hardware CloseLink completes without 5FFF')
    finally:
        close(master);close(slave)


if __name__ == '__main__':
    direct_room_exit()
