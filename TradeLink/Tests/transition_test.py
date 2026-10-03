"""Synthetic register/command trace of FireRed's cable-club -> party-list path.

Derived from pret/pokefirered's Task_StartWiredTrade, CB2_CreateTradeMenu,
OpenLink, ResetSerial and EnableSerial/DisableSerial. No ROM or game assets.
This exercises the real gpSP core, rather than executing FireRed game logic.
"""
from network_test import Peer, handshake, exchange, settle, close


def party_entry():
    master, slave = Peer(0), Peer(1)
    try:
        handshake(master, slave)
        exchange(master, slave, [0x2222, 0x1111] + [0]*6, [0x2222, 0x1111] + [0]*6)
        # Task_StartWiredTrade closes the OVERWORLD link before entering the
        # party menu; 5FFF is used for this transition as well as final exits.
        exchange(master, slave, [0x5fff] + [0]*7, [0x5fff] + [0]*7)
        for peer in (master, slave):
            peer.command('sio 2000')
            peer.command('frame')
            assert peer.phase == 3 and peer.flushes == 0, (
                'FireRed party-list transition incorrectly ended the network '
                'session or flushed the save', peer.phase, peer.flushes)
        settle(master, slave)
        # CB2_CreateTradeMenu -> OpenLink: ResetSerial Enable/Disable, followed
        # by InitLink Enable. LinkMain1 disables once more, then waits 5 frames.
        for peer in (master, slave):
            for value in (0x2000, 0x6003, 0x2000, 0x2000, 0x6003, 0x2000):
                peer.command(f'sio {value:x}')
            peer.command('frames 5')
            peer.command('sio 6003')
            assert peer.phase == 3 and peer.flushes == 0
        handshake(master, slave)
        exchange(master, slave, [0x2222, 0x1122] + [0]*6, [0x2222, 0x1122] + [0]*6)
        assert master.phase == slave.phase == 3
        print('PASS: FireRed room -> party-list close/reopen preserves the same paired session')
    finally:
        close(master)
        close(slave)


if __name__ == '__main__':
    party_entry()
