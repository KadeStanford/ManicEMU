"""Source-derived FireRed terminal exit and fresh Colosseum discovery traces.

pret/pokefirered 037335f: CAFE/17 from both players precedes direct CloseLink.
Synthetic registers/commands over real gpSP and fragmented TCP, no game ROM.
"""
from pathlib import Path
import tempfile
from network_test import Peer, handshake, exchange, settle, close
from transition_test import command_pair, party_entry, internal_close, block


def complete(master, slave, flushes=1):
    # Known room termination finishes in a few frames, without a quiet timeout.
    for _ in range(4):
        settle(master, slave)
        for peer in (master, slave):peer.command('frame')
    for peer in (master, slave):
        assert peer.phase == 1 and peer.flushes == flushes and peer.sram == 0x99
        peer.command('stopped')
        peer.command('disconnected');assert peer.expected == 1
        peer.command('disconnected');assert peer.expected == 1
        peer.command('resume');assert peer.phase == 1


def room_exit(master, slave, order='both', flushes=1):
    command_pair(master, slave, 0xcafe, 0x17)
    for peer in (master, slave):peer.command('mutate')
    first, second = (slave, master) if order == 'slave' else (master, slave)
    first.command('sio 2000')
    if order != 'both':
        settle(master, slave)
        first.command('frames 240')
        assert first.terminal and first.phase == second.phase == 3
        assert first.flushes == second.flushes == flushes-1
    second.command('sio 2000')
    complete(master, slave, flushes)


def direct_room_exit():
    for order in ('both', 'master', 'slave'):
        master, slave = Peer(0), Peer(1)
        try:
            handshake(master, slave);command_pair(master, slave, 0x2222, 0x1111)
            room_exit(master, slave, order)
        finally:close(master);close(slave)
    print('PASS: simultaneous/asymmetric/delayed direct room exits have one save flush, '
          'stop both engines, ignore repeated disconnects, and finish without 5FFF or quiet timer')


def negative_guards():
    for kind, local_key, remote_key in ((0x1111,0x17,0x1a), (0x1111,0x1d,0x1d), (0x1122,0x17,0x17)):
        master, slave = Peer(0), Peer(1)
        try:
            handshake(master, slave);command_pair(master, slave, 0x2222, kind)
            exchange(master, slave, [0xcafe,local_key]+[0]*6, [0xcafe,remote_key]+[0]*6)
            for peer in (master, slave):peer.command('sio 2000')
            settle(master, slave)
            for peer in (master, slave):
                peer.command('frames 200');peer.command('disconnected')
                assert not peer.terminal and peer.phase == 3 and peer.flushes == 0 and peer.expected == 0
        finally:close(master);close(slave)
    # A later reopen invalidates exit keys; they cannot leak into another activity.
    master, slave = Peer(0), Peer(1)
    try:
        handshake(master, slave);command_pair(master, slave, 0x2222, 0x1111)
        command_pair(master, slave, 0xcafe, 0x17)
        for peer in (master, slave):peer.command('sio 2000')
        settle(master, slave)
        for peer in (master, slave):peer.command('sio 6003')
        settle(master, slave)
        for peer in (master, slave):
            peer.command('frame');assert not peer.terminal and peer.phase == 3 and peer.flushes == 0
        handshake(master, slave);command_pair(master, slave, 0x2222, 0x1122);block(master, slave, 200, 13)
    finally:close(master);close(slave)
    print('PASS: one exit key, EXIT_SEAT, non-room link type and reopened hardware do not claim completion')


def disconnect_guards():
    master, slave = Peer(0), Peer(1)
    try:
        handshake(master, slave);command_pair(master, slave, 0x2222, 0x1111)
        command_pair(master, slave, 0xcafe, 0x17)
        # A final DATA packet without its ACK must still suspend/recover.
        master.command('master 0')
        for word in [0xcafe,0x11]+[0]*6:master.command(f'master {word:x}')
        assert any(p[5] == 1 for p in master.pending)
        for peer in (master, slave):peer.command('mutate');peer.command('sio 2000')
        master.command('disconnected');assert master.expected == 0 and not master.terminal
        master.command('pause');assert master.phase == 4 and master.flushes == 0
        # Ordered replay restores the missing ACK. Disabled terminal games can
        # then finish; active-game bilateral reconnect remains separately tested.
        complete(master, slave)
    finally:close(master);close(slave)
    master, slave = Peer(0), Peer(1)
    try:
        handshake(master, slave);command_pair(master, slave, 0x2222, 0x1111)
        command_pair(master, slave, 0xcafe, 0x17)
        for peer in (master, slave):peer.command('mutate')
        # Peer vanishes after both exit keys were ACKed, before its OFF/CLOSE
        # controls. The local game has applied CloseLink already.
        master.command('sio 2000');master.command('disconnected')
        assert master.expected == 1
        master.command('frame');assert master.phase == 1 and master.flushes == 1
        slave.command('sio 2000');slave.command('disconnected')
        assert slave.expected == 1
        slave.command('frame');assert slave.phase == 1 and slave.flushes == 1
    finally:close(master);close(slave)
    print('PASS: missing serial DATA ACK remains recoverable; acknowledged bilateral '
          'game exit tolerates a missing final transport control without rollback')


def battle_reentry():
    with tempfile.TemporaryDirectory() as directory:
        paths = [Path(directory)/f'{role}.sav' for role in (0,1)]
        master, slave = Peer(0,paths[0]), Peer(1,paths[1])
        try:
            handshake(master, slave);command_pair(master, slave, 0x2222, 0x1111)
            master.command('sio 2000');old = master.pending[-1]
            master.command('sio 6003');settle(master, slave);handshake(master, slave)
            room_exit(master, slave)
            for cycle, kind in enumerate((0x2233,0x2244), 2):
                for peer in (master, slave):
                    epoch = peer.epoch;peer.command('begin')
                    assert peer.phase == 2 and peer.epoch > epoch and peer.sram == 0x99
                    peer.command('connect');assert peer.phase == 3
                master.command('reject '+old.hex())
                handshake(master, slave);command_pair(master, slave, 0x2222, kind)
                internal_close(master, slave)
                command_pair(master, slave, 0x2222, 0x2211)
                assert master.mode == slave.mode == (2 if kind == 0x2233 else 3)
                for turn in range(4):block(master, slave, 28, 61+turn)
                internal_close(master, slave, first_slave=True)
                command_pair(master, slave, 0x2222, kind)
                room_exit(master, slave, flushes=cycle)
            for path in paths:assert len(path.read_bytes()) == 131072 and path.read_bytes()[0] == 0x99
        finally:close(master);close(slave)
        for role,path in enumerate(paths):
            peer=Peer(role,path)
            try:assert peer.sram == 0x99
            finally:close(peer)
    print('PASS: trade exit -> fresh Single/Double Colosseum handshake/discovery request -> '
          'pair -> battle entry/turns/return -> direct exit; new sessions reject old packets, persisted SRAM survives restart')


if __name__ == '__main__':
    direct_room_exit()
    negative_guards()
    disconnect_guards()
    battle_reentry()
    party_entry(ending=room_exit)
