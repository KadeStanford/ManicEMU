"""Five header profiles, both peer roles and three cable-club activities.

Source-derived protocol fixtures on real gpSP; no Pokemon ROM/game simulation.
Matrix TCP packets are fragmented without artificial sleeps. The separate
network/transition/lifecycle suites exercise delays, loss and replay timing.
"""
import tempfile
from pathlib import Path
import network_test
from network_test import Peer, handshake, settle, close
from transition_test import command_pair, block, internal_close, reopen
from exit_test import room_exit
from lifecycle_test import hold_roundtrip

CODES = ('AXVE', 'AXPE', 'BPEE', 'BPRE', 'BPGE')
ACTIVITIES = ((0x1111, 1), (0x2233, 2), (0x2244, 3))


def fragmented(message):
    a, b = network_test.tcp_pair()
    try:
        for offset in range(0, len(message), 7):
            a.sendall(message[offset:offset+7])
        result = b''
        while len(result) < len(message):
            part = b.recv(len(message)-len(result))
            assert part, 'truncated matrix packet'
            result += part
        return result
    finally:
        a.close(); b.close()


def delayed_return(master, slave, activity):
    command_pair(master, slave, 0x5fff)
    for peer in (master, slave): peer.command('sio 2000')
    for _ in range(3):
        settle(master, slave)
        for peer in (master, slave): peer.command('frames 300')
    # Known menu/animation/battle handoffs must outlive the old quiet window.
    assert master.phase == slave.phase == 3
    reopen(master, slave)
    command_pair(master, slave, 0x2222, activity)


def pair(a, b):
    with tempfile.TemporaryDirectory() as directory:
        paths = [Path(directory)/f'{role}.sav' for role in range(2)]
        master, slave = Peer(0, paths[0], a), Peer(1, paths[1], b)
        try:
            for cycle, (kind, mode) in enumerate(ACTIVITIES, 1):
                if cycle > 1:
                    for peer in (master, slave):
                        epoch = peer.epoch
                        peer.command('begin')  # Proves zero-word bootstrap IRQ after completion.
                        assert peer.phase == 2 and peer.epoch > epoch and peer.sram == 0x99
                        peer.command('connect')
                handshake(master, slave)
                command_pair(master, slave, 0x2222, kind)
                assert master.mode == slave.mode == mode
                internal_close(master, slave)
                command_pair(master, slave, 0x2222, 0x1122 if mode == 1 else 0x2211)
                if mode == 1:
                    for seed in (17, 37, 71): block(master, slave, 200, seed)
                else:
                    for seed in (43, 83, 103): block(master, slave, 28, seed)
                hold_roundtrip(master, slave, ('master', 'slave', 'both')[cycle-1])
                if mode == 3:
                    master.command('pause'); settle(master, slave)
                    assert master.phase == slave.phase == 4
                    master.command('resume'); settle(master, slave)
                    assert master.phase == slave.phase == 4
                    slave.command('resume'); settle(master, slave)
                    assert master.phase == slave.phase == 3
                    block(master, slave, 28, 127)
                delayed_return(master, slave, kind)
                assert master.flushes == slave.flushes == cycle-1
                room_exit(master, slave, ('both', 'master', 'slave')[cycle-1], cycle)
                for path in paths:
                    saved = path.read_bytes()
                    assert len(saved) == 131072 and saved[0] == 0x99
            print(f'PASS matrix {a}/{b}: Trade -> Single -> Double, blocks, holds, '
                  'slow return, bilateral recovery, asymmetric exits and current saves', flush=True)
        finally:
            close(master); close(slave)


def negative_keys():
    # Shared room-exit recognition must not expand to one player's request or
    # an EXIT_SEAT/non-room key. Existing FireRed tests also cover stale/reopen.
    from network_test import exchange
    for code in CODES:
        master, slave = Peer(0, code=code), Peer(1, code=code)
        try:
            handshake(master, slave); command_pair(master, slave, 0x2222, 0x1111)
            exchange(master, slave, [0xcafe, 0x17]+[0]*6, [0xcafe, 0x1d]+[0]*6)
            for peer in (master, slave): peer.command('sio 2000')
            settle(master, slave)
            for peer in (master, slave):
                peer.command('frames 200'); peer.command('disconnected')
                assert not peer.terminal and peer.expected == 0 and peer.flushes == 0
            reopen(master, slave); command_pair(master, slave, 0x2222, 0x1122)
            command_pair(master, slave, 0xcafe, 0x17)
            for peer in (master, slave): peer.command('sio 2000')
            settle(master, slave)
            for peer in (master, slave):
                peer.command('frames 300')
                assert not peer.terminal and peer.phase == 3 and peer.flushes == 0
        finally:
            close(master); close(slave)


if __name__ == '__main__':
    network_test.wire = fragmented
    for a in CODES:
        for b in CODES: pair(a, b)
    negative_keys()
    print('PASS: 25 ordered English header pairs x 3 activities = 75 protocol traces; '
          'five title negative-exit guards. Actual game/device combinations remain untested.')
